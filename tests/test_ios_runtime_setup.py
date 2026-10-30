import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

spec = importlib.util.spec_from_file_location(
    "ios_runtimes", Path(__file__).resolve().parents[1] / "scripts/ensure_ios_runtimes.py"
)
runtimes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtimes)


def test_available_runtime_does_not_download(monkeypatch):
    monkeypatch.setattr(runtimes, "available", lambda version: True)
    monkeypatch.setattr(
        runtimes.subprocess, "run", lambda *a, **k: pytest.fail("Unexpected download")
    )
    runtimes.ensure("27.0")


@pytest.mark.parametrize("installed, succeeds", [(True, True), (False, False)])
def test_download_exit_70_requires_verified_runtime(monkeypatch, installed, succeeds):
    checks = iter([False, installed])
    monkeypatch.setattr(runtimes, "available", lambda version: next(checks))
    monkeypatch.setattr(runtimes.subprocess, "run", lambda *a, **k: SimpleNamespace(returncode=70))
    if succeeds:
        runtimes.ensure("27.1")
    else:
        with pytest.raises(RuntimeError, match="unavailable after download"):
            runtimes.ensure("27.1")
