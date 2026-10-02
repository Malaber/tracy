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
    assert len(manifest) == 5
    for entry in manifest:
        with Image.open(target / entry["file"]) as image:
            assert image.mode == "RGB"
            assert image.size == (8, 16)
        assert len(entry["sha256"]) == 64


def test_package_rejects_wrong_dimensions(tmp_path):
    with pytest.raises(ValueError, match="expected"):
        package_device(captures(tmp_path), tmp_path / "ready", (16, 32))


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
