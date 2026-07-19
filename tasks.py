import os
import re
import signal
import shlex
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

from invoke import task


ROOT = Path(__file__).resolve().parent
STABLE_TAG_PATTERN = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def _bin(name: str) -> str:
    local = ROOT / ".venv" / "bin" / name
    return shlex.quote(str(local if local.exists() else name))


def _clean_install_env() -> dict[str, str]:
    environment = os.environ.copy()
    for name in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        if environment.get(name) and not Path(environment[name]).exists():
            environment.pop(name)
    return environment


def _git_lines(*args: str) -> list[str]:
    return subprocess.run(
        ["git", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.splitlines()


def _latest_stable_version_from_tags(tags: list[str]) -> str:
    versions = [
        tuple(map(int, match.groups()))
        for tag in tags
        if (match := STABLE_TAG_PATTERN.fullmatch(tag))
    ]
    if not versions:
        return "0.1.0"
    major, minor, patch = max(versions)
    return f"{major}.{minor}.{patch}"


def _next_stable_version(version: str, tags: list[str]) -> str:
    major, minor, patch = map(int, version.split("."))
    existing_tags = set(tags)
    while True:
        patch += 1
        candidate = f"{major}.{minor}.{patch}"
        if f"v{candidate}" not in existing_tags:
            return candidate


def _next_rc_version(version: str, run_number: int, tags: list[str]) -> str:
    rc_number = run_number
    existing_tags = set(tags)
    while True:
        candidate = f"{version}-rc.{rc_number}"
        if f"v{candidate}" not in existing_tags:
            return candidate
        rc_number += 1


def _compute_version_values(ref_name: str, run_number: int, tags: list[str]) -> dict[str, str]:
    base_version = _next_stable_version(_latest_stable_version_from_tags(tags), tags)
    release_version = (
        base_version if ref_name == "main" else _next_rc_version(base_version, run_number, tags)
    )
    return {
        "base_version": base_version,
        "release_version": release_version,
        "git_tag": f"v{release_version}",
    }


def _write_github_output(values: dict[str, str]) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with Path(output_path).open("a", encoding="utf-8") as output:
            for key, value in values.items():
                output.write(f"{key}={value}\n")
        return
    for key, value in values.items():
        print(f"{key}={value}")


@task
def install_python(c):
    c.run(f"{_bin('pip')} install -e '.[dev]'", env=_clean_install_env())


@task
def install_js(c):
    command = "npm ci" if (ROOT / "package-lock.json").exists() else "npm install"
    c.run(command)


@task(install_python, install_js)
def install_deps(_):
    """Install all development dependencies."""


@task
def bootstrap_ci(c):
    """Install Python tooling used by the shared CI tasks."""
    python = shlex.quote(sys.executable)
    c.run(f"{python} -m pip install -e '.[dev]'", env=_clean_install_env())


@task
def format(c):
    c.run(f"{_bin('black')} app tests tasks.py")


@task
def black_check(c):
    c.run(f"{_bin('black')} --check app tests tasks.py")


@task
def flake8_check(c):
    c.run(f"{_bin('flake8')} app tests tasks.py")


@task
def test_python(c):
    c.run(f"{_bin('pytest')}")


@task
def check_python(c):
    black_check.body(c)
    flake8_check.body(c)
    test_python.body(c)


@task
def check_js(c):
    c.run("npm run test:js")


@task(help={"with_deps": "Install Chromium and its system dependencies."})
def install_browser(c, with_deps=False):
    flag = " --with-deps" if with_deps else ""
    c.run(f"npx playwright install{flag} chromium")


@task(
    help={
        "port": "Local port used by the temporary Tracy server.",
        "database_path": "Temporary SQLite database path, relative to the repo.",
        "artifact_dir": "Directory for e2e screenshots, summary, and server log.",
    }
)
def browser_e2e(
    c,
    port=8011,
    database_path="tmp-passkey-e2e.db",
    artifact_dir="e2e-artifacts/passkey",
):
    database_file = ROOT / database_path
    for candidate in (
        database_file,
        Path(f"{database_file}-shm"),
        Path(f"{database_file}-wal"),
    ):
        candidate.unlink(missing_ok=True)

    artifacts = ROOT / artifact_dir
    shutil.rmtree(artifacts, ignore_errors=True)
    artifacts.mkdir(parents=True, exist_ok=True)
    log_path = artifacts / "server.log"
    environment = os.environ.copy()
    environment.update(
        {
            "APP_BASE_URL": f"http://localhost:{port}",
            "DATABASE_URL": f"sqlite+aiosqlite:///{database_file}",
            "PREVIEW_ARTIFACT_DIR": str(artifacts),
            "PREVIEW_BASE_URL": f"http://localhost:{port}",
            "SECRET_KEY": "tracy-passkey-e2e-secret-32-bytes",
            "SECURE_COOKIES": "false",
            "WEBAUTHN_RP_ID": "localhost",
        }
    )
    with log_path.open("w", encoding="utf-8") as log_file:
        process = subprocess.Popen(
            [
                str(ROOT / ".venv" / "bin" / "uvicorn"),
                "app.main:app",
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
            ],
            cwd=ROOT,
            env=environment,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    try:
        health_url = f"http://127.0.0.1:{port}/health"
        for _ in range(60):
            if process.poll() is not None:
                raise RuntimeError(f"Tracy e2e server exited; see {log_path}")
            try:
                with urllib.request.urlopen(health_url, timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.25)
        else:
            raise RuntimeError(f"Tracy e2e server did not become healthy; see {log_path}")
        c.run("npm run test:e2e", env=environment, pty=False)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)


@task(check_python, check_js, install_browser, browser_e2e)
def verify(_):
    """Run all automated checks."""


@task
def migrate(c):
    c.run(f"{_bin('alembic')} upgrade head")


@task(
    help={
        "ref_name": "Git ref name used to decide stable vs rc versioning.",
        "run_number": "GitHub Actions run number used for rc suffixes.",
    }
)
def compute_version(_, ref_name="", run_number=""):
    resolved_ref_name = ref_name or os.environ.get("REF_NAME") or os.environ.get("GITHUB_REF_NAME")
    resolved_run_number = (
        str(run_number)
        if run_number
        else (os.environ.get("RUN_NUMBER") or os.environ.get("GITHUB_RUN_NUMBER"))
    )
    if not resolved_ref_name:
        raise ValueError("compute-version requires REF_NAME or GITHUB_REF_NAME")
    if not resolved_run_number:
        raise ValueError("compute-version requires RUN_NUMBER or GITHUB_RUN_NUMBER")
    values = _compute_version_values(
        resolved_ref_name,
        int(resolved_run_number),
        _git_lines("tag", "--list", "v*"),
    )
    _write_github_output(values)


@task
def start(c, host="127.0.0.1", port=8000, reload=False):
    reload_flag = " --reload" if reload else ""
    c.run(f"{_bin('uvicorn')} app.main:app --host {host} --port {port}{reload_flag}")
