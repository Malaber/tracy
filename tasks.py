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
                sys.executable,
                "-m",
                "uvicorn",
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


IOS_ROOT = ROOT / "ios" / "TracyIOS"


def _ios_release_version(tags: list[str], head_tags: list[str]) -> str:
    stable = [tag for tag in head_tags if STABLE_TAG_PATTERN.fullmatch(tag)]
    if stable:
        return _latest_stable_version_from_tags(stable)
    return _compute_version_values("main", 1, tags)["base_version"]


def _current_ios_version() -> str:
    return _ios_release_version(
        _git_lines("tag", "--list", "v*"), _git_lines("tag", "--points-at", "HEAD")
    )


@task
def generate_ios_project(c):
    """Generate the native Xcode project (requires XcodeGen)."""
    version = _current_ios_version()
    (IOS_ROOT / "Version.xcconfig").write_text(f"MARKETING_VERSION = {version}\n", encoding="utf-8")
    c.run(f"xcodegen generate --spec {shlex.quote(str(IOS_ROOT / 'project.yml'))}")


@task
def check_ios_package(c):
    """Test time entry, offline storage, and sync policies."""
    c.run(f"swift test --package-path {shlex.quote(str(IOS_ROOT))}")


@task(generate_ios_project)
def build_ios_simulator(c):
    """Build the universal iOS app without signing."""
    c.run(
        f"xcodebuild -project {shlex.quote(str(IOS_ROOT / 'TracyApp.xcodeproj'))} "
        "-scheme Tracy -destination 'generic/platform=iOS Simulator' "
        f"-derivedDataPath {shlex.quote(str(IOS_ROOT / 'DerivedData'))} "
        "CODE_SIGNING_ALLOWED=NO build"
    )


@task(generate_ios_project)
def check_ios_ui(c, destination="platform=iOS Simulator,name=iPhone 17 Pro"):
    """Run native time-entry and accessibility smoke tests on an installed simulator."""
    c.run(
        f"xcodebuild -project {shlex.quote(str(IOS_ROOT / 'TracyApp.xcodeproj'))} "
        f"-scheme Tracy -destination {shlex.quote(destination)} "
        f"-derivedDataPath {shlex.quote(str(IOS_ROOT / 'DerivedData'))} "
        "-parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test"
    )


@task(generate_ios_project)
def upload_ios_testflight(c, build_number="1"):
    """Archive, sign, and upload a validated iOS build to App Store Connect."""
    version = _current_ios_version()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("version must be major.minor.patch")
    if not re.fullmatch(r"[1-9]\d*", str(build_number)):
        raise ValueError("build_number must be a positive integer")
    c.run(
        f"{shlex.quote(str(IOS_ROOT / 'Scripts' / 'upload_testflight.sh'))} "
        f"{shlex.quote(version)} {shlex.quote(str(build_number))}"
    )
