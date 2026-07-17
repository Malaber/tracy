import os
import shlex
from pathlib import Path

from invoke import task


ROOT = Path(__file__).resolve().parent


def _bin(name: str) -> str:
    local = ROOT / ".venv" / "bin" / name
    return shlex.quote(str(local if local.exists() else name))


def _clean_install_env() -> dict[str, str]:
    environment = os.environ.copy()
    for name in ("SSL_CERT_FILE", "REQUESTS_CA_BUNDLE"):
        if environment.get(name) and not Path(environment[name]).exists():
            environment.pop(name)
    return environment


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
def format(c):
    c.run(f"{_bin('black')} app tests tasks.py")


@task
def check_python(c):
    c.run(f"{_bin('black')} --check app tests tasks.py")
    c.run(f"{_bin('flake8')} app tests tasks.py")
    c.run(f"{_bin('pytest')}")


@task
def check_js(c):
    c.run("npm run test:js")


@task(check_python, check_js)
def verify(_):
    """Run all automated checks."""


@task
def migrate(c):
    c.run(f"{_bin('alembic')} upgrade head")


@task
def start(c, host="127.0.0.1", port=8000, reload=False):
    reload_flag = " --reload" if reload else ""
    c.run(f"{_bin('uvicorn')} app.main:app --host {host} --port {port}{reload_flag}")
