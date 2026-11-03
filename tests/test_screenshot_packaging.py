import importlib.util
import json
from pathlib import Path

import pytest
from PIL import Image

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/capture_ios_screenshots.py"
SPEC = importlib.util.spec_from_file_location("screenshots", SCRIPT)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)
SCENES = module.SCENES
package_device = module.package_device


def captures(tmp_path, size=(8, 16)):
    export = tmp_path / "export"
    export.mkdir()
    attachments = []
    for scene in SCENES:
        filename = f"{scene}.png"
        Image.new("RGBA", size, (20, 40, 60, 255)).save(export / filename)
        attachments.append(
            {
                "exportedFileName": filename,
                "suggestedHumanReadableName": f"marketing-{scene}.png",
                "isAssociatedWithFailure": False,
            }
        )
    (export / "manifest.json").write_text(json.dumps([{"attachments": attachments}]))
    return export


def test_package_requires_full_set_and_removes_alpha(tmp_path):
    export = captures(tmp_path)
    target = tmp_path / "ready"
    manifest = package_device(export, target, (8, 16))
    assert len(manifest) == len(SCENES)
    for entry in manifest:
        with Image.open(target / entry["file"]) as image:
            assert image.mode == "RGB"
            assert image.size == (8, 16)
        assert len(entry["sha256"]) == 64


@pytest.mark.parametrize("expected", [(16, 32), (16, 8)])
def test_package_rejects_wrong_dimensions(tmp_path, expected):
    with pytest.raises(ValueError, match="expected"):
        package_device(captures(tmp_path), tmp_path / "ready", expected)


@pytest.mark.parametrize("problem", ["missing", "duplicate", "failed"])
def test_package_rejects_incomplete_or_failed_capture(tmp_path, problem):
    export = captures(tmp_path)
    path = export / "manifest.json"
    data = json.loads(path.read_text())
    items = data[0]["attachments"]
    if problem == "missing":
        items.pop()
    elif problem == "duplicate":
        items.append(items[0])
    else:
        items[0]["isAssociatedWithFailure"] = True
    path.write_text(json.dumps(data))
    with pytest.raises(ValueError):
        package_device(export, tmp_path / "ready", (8, 16))


def test_package_rejects_inactive_black_display(tmp_path):
    export = captures(tmp_path)
    Image.new("RGB", (8, 16), (0, 0, 0)).save(export / f"{SCENES[0]}.png")
    with pytest.raises(ValueError, match="inactive display"):
        package_device(export, tmp_path / "ready", (8, 16))


@pytest.mark.parametrize("failure", [None, "exit", "timeout"])
def test_scene_termination_bridge_is_scoped_and_reports_failure(tmp_path, monkeypatch, failure):
    import subprocess
    from urllib.error import HTTPError
    from urllib.request import Request, urlopen

    monkeypatch.setattr(module, "DERIVED_DATA", tmp_path)
    bundle = (
        tmp_path
        / "Build/Products/Debug-iphonesimulator"
        / "TracyMarketingTests-Runner.app/PlugIns/TracyMarketingTests.xctest"
    )
    bundle.mkdir(parents=True)
    calls = []

    def terminate(identifier):
        calls.append(identifier)
        if failure == "exit":
            raise subprocess.CalledProcessError(1, ["simctl"], stderr="service failed")
        if failure == "timeout":
            raise subprocess.TimeoutExpired(["simctl"], 20)

    monkeypatch.setattr(module, "terminate_capture_app", terminate)
    server = module.start_native_capture("dedicated-simulator", tmp_path)
    try:
        base = f"http://127.0.0.1:{server.server_port}"
        assert (bundle / "capture-port.txt").read_text() == str(server.server_port)
        with pytest.raises(HTTPError) as rejected:
            urlopen(Request(base + "/terminate/another-app", method="POST"), timeout=5)
        assert rejected.value.code == 404
        assert not calls
        request = Request(base + "/terminate", method="POST")
        if failure:
            with pytest.raises(HTTPError) as response:
                urlopen(request, timeout=5)
            assert response.value.code == 500
        else:
            with urlopen(request, timeout=5) as response:
                assert response.status == 204
                assert response.read() == b""
        assert calls == ["dedicated-simulator"]
    finally:
        server.shutdown()
        server.server_close()


def test_resource_diagnostic_timeout_does_not_prevent_cleanup(tmp_path, monkeypatch):
    import subprocess

    def timeout(command, **kwargs):
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(module.subprocess, "run", timeout)
    path = tmp_path / "resources.log"
    module.record_host_resources(path)
    assert path.read_text().count("Resource diagnostic failed") == 4


@pytest.mark.parametrize("failure", ["exit", "timeout"])
@pytest.mark.parametrize("remaining", [False, True])
def test_termination_recovers_only_exact_tracy_service(monkeypatch, failure, remaining):
    import subprocess

    label = "UIKitApplication:de.malaber.tracy[430a][rb-legacy]"
    other = "345 0 UIKitApplication:de.malaber.tracy.uitests[abcd]\n"
    listings = iter(
        [
            "PID Status Label\n" + other + (f"123 0 {label}\n" if remaining else ""),
            "PID Status Label\n" + other,
        ]
    )
    calls = []

    def run(command, **kwargs):
        calls.append(command)
        if command[2] == "terminate":
            if failure == "exit":
                raise subprocess.CalledProcessError(3, command, stderr="not running")
            raise subprocess.TimeoutExpired(command, 20)
        if command[-1] == "list":
            return subprocess.CompletedProcess(command, 0, stdout=next(listings))
        return subprocess.CompletedProcess(command, 0)

    monkeypatch.setattr(module.subprocess, "run", run)
    module.terminate_capture_app("dedicated")
    removals = [command for command in calls if "remove" in command]
    assert removals == (
        [["xcrun", "simctl", "spawn", "dedicated", "launchctl", "remove", label]]
        if remaining
        else []
    )


@pytest.mark.parametrize(
    "listing",
    [
        "unexpected output",
        "PID Status Label\n123 0 UIKitApplication:de.malaber.tracy[abcd]\n",
    ],
)
def test_termination_does_not_report_success_without_verified_stop(monkeypatch, listing):
    import subprocess

    def run(command, **kwargs):
        if command[2] == "terminate":
            raise subprocess.TimeoutExpired(command, 20)
        return subprocess.CompletedProcess(command, 0, stdout=listing)

    monkeypatch.setattr(module.subprocess, "run", run)
    with pytest.raises(RuntimeError):
        module.terminate_capture_app("dedicated")
