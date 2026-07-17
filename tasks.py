import os
import re
import shlex
import subprocess
import sys
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


@task(check_python, check_js)
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
