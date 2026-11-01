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

    def terminate(command, **kwargs):
        calls.append((command, kwargs))
        if failure == "exit":
            raise subprocess.CalledProcessError(1, command)
        if failure == "timeout":
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(module.subprocess, "run", terminate)
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
        assert calls == [
            (
                ["xcrun", "simctl", "terminate", "dedicated-simulator", "de.malaber.tracy"],
                {"capture_output": True, "text": True, "check": True, "timeout": 20},
            )
        ]
    finally:
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize(
    "families,gib,allowed",
    [
        (["iphone-duo-outer"], 7, False),
        (["iphone-duo-inner"], 7, False),
        (["iphone-6.3", "iphone-duo-inner"], 7, False),
        (["iphone-duo-outer"], 12, True),
        (["iphone-duo-inner"], 14, True),
        (["iphone-6.3", "ipad-13"], 7, True),
    ],
)
def test_duo_capture_rejects_undersized_hosts(families, gib, allowed):
    if allowed:
        module.require_capture_memory(families, gib * 1024**3)
    else:
        with pytest.raises(SystemExit, match="xcode-27-xlarge"):
            module.require_capture_memory(families, gib * 1024**3)


def test_resource_diagnostic_timeout_does_not_prevent_cleanup(tmp_path, monkeypatch):
    import subprocess

    def timeout(command, **kwargs):
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(module.subprocess, "run", timeout)
    path = tmp_path / "resources.log"
    module.record_host_resources(path)
    assert path.read_text().count("Resource diagnostic failed") == 4
