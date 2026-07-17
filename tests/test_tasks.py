import importlib.util
from pathlib import Path

import pytest


TASKS_PATH = Path(__file__).resolve().parents[1] / "tasks.py"
TASKS_SPEC = importlib.util.spec_from_file_location("tasks", TASKS_PATH)
assert TASKS_SPEC is not None
assert TASKS_SPEC.loader is not None
tasks = importlib.util.module_from_spec(TASKS_SPEC)
TASKS_SPEC.loader.exec_module(tasks)


def test_latest_stable_version_defaults_before_first_release():
    assert tasks._latest_stable_version_from_tags(["v0.1.1-rc.4", "notes"]) == "0.1.0"


def test_main_version_uses_next_available_patch():
    assert tasks._compute_version_values(
        "main",
        42,
        ["v0.1.1", "v0.1.2", "v0.1.3-rc.2"],
    ) == {
        "base_version": "0.1.3",
        "release_version": "0.1.3",
        "git_tag": "v0.1.3",
    }


def test_branch_version_skips_existing_release_candidates():
    assert tasks._compute_version_values(
        "codex/ci",
        7,
        ["v0.1.2", "v0.1.3-rc.7", "v0.1.3-rc.8"],
    ) == {
        "base_version": "0.1.3",
        "release_version": "0.1.3-rc.9",
        "git_tag": "v0.1.3-rc.9",
    }


def test_github_output_is_written_when_configured(tmp_path: Path, monkeypatch):
    output = tmp_path / "github-output"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))

    tasks._write_github_output({"release_version": "1.2.3", "git_tag": "v1.2.3"})

    assert output.read_text(encoding="utf-8") == ("release_version=1.2.3\ngit_tag=v1.2.3\n")


def test_compute_version_requires_ci_context(monkeypatch):
    for name in ("REF_NAME", "GITHUB_REF_NAME", "RUN_NUMBER", "GITHUB_RUN_NUMBER"):
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(ValueError, match="REF_NAME"):
        tasks.compute_version.body(None)


def test_deployment_defaults_to_latest_ghcr_image():
    compose = Path("docker-compose.yml").read_text(encoding="utf-8")
    dockerfile = Path("Dockerfile").read_text(encoding="utf-8")

    assert "ghcr.io/malaber/tracy:latest" in compose
    assert "pull_policy: always" in compose
    assert "ARG TRACY_VERSION" in dockerfile
    assert "SETUPTOOLS_SCM_PRETEND_VERSION=${TRACY_VERSION}" in dockerfile
