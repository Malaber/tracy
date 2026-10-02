"""Capture actual native UI; validate and package Apple-sized, opaque PNGs."""

import argparse
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import shutil
import tempfile
import sys
import zipfile

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios/TracyIOS"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
DEVICES = {
    "iphone-6.5": ("iPhone 13 Pro Max", (1284, 2778)),
    "ipad-13": ("iPad Pro 13-inch (M5)", (2064, 2752)),
}
SCENES = ("01-today", "02-entry", "03-recent-days", "04-offline", "05-dark")


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        print(result.stdout + result.stderr, file=sys.stderr, flush=True)
        result.check_returncode()
    return result.stdout.strip()


def package_device(export, destination, dimensions):
    """Accept exactly one successful capture of every expected scene, at native resolution."""
    destination.mkdir(parents=True)
    found = {}
    for test in json.loads((export / "manifest.json").read_text()):
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"]
            scene = next((s for s in SCENES if name.startswith(f"marketing-{s}")), None)
            if scene is None:
                continue
            if scene in found or attachment["isAssociatedWithFailure"]:
                raise ValueError(f"Duplicate or failed screenshot: {scene}")
            target = destination / f"{scene}.png"
            with Image.open(export / attachment["exportedFileName"]) as image:
                if image.size != dimensions:
                    raise ValueError(f"{scene}: expected {dimensions}, got {image.size}")
                image.convert("RGB").save(target)
            found[scene] = {
                "file": target.name,
                "width": dimensions[0],
                "height": dimensions[1],
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            }
    if set(found) != set(SCENES):
        raise ValueError(f"Missing screenshots: {set(SCENES) - set(found)}")
    return [found[scene] for scene in SCENES]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    if run("xcodebuild", "-version") != "Xcode 27.0\nBuild version 27A266a":
        raise SystemExit("Screenshot captures require Xcode 27.0 build 27A266a")
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    if not any(
        r["identifier"] == RUNTIME and r["buildversion"] == "23C52" and r["isAvailable"]
        for r in runtimes
    ):
        raise SystemExit("Screenshot captures require iOS 26.2 build 23C52")
    output = ROOT / "e2e-artifacts/app-store"
    output.mkdir(parents=True, exist_ok=True)
    manifest = {
        "version": args.version,
        "commit": run("git", "rev-parse", "HEAD"),
        "locale": "en-US",
        "xcode": "27.0 (27A266a)",
        "runtime": "iOS 26.2 (23C52)",
        "content": "Synthetic local UI-test data; real app screens, no live account",
        "devices": {},
    }
    with tempfile.TemporaryDirectory(dir=output, delete=False) as temporary:
        stage = Path(temporary)
        package = stage / "screenshots"
        for family, (device, dimensions) in DEVICES.items():
            print(f"Capturing {family}: {device}", flush=True)
            identifier = run("xcrun", "simctl", "create", "Tracy marketing", device, RUNTIME)
            result = stage / f"{family}.xcresult"
            try:
                devices = json.loads(run("xcrun", "simctl", "list", "devices", "--json"))
                simulator = next(
                    d
                    for group in devices["devices"].values()
                    for d in group
                    if d["udid"] == identifier
                )
                preferences = (
                    Path(simulator["dataPath"]) / "Library/Preferences/.GlobalPreferences.plist"
                )
                preferences.parent.mkdir(parents=True, exist_ok=True)
                values = plistlib.loads(preferences.read_bytes()) if preferences.exists() else {}
                values.update(AppleLanguages=["en"], AppleLocale="en_US")
                preferences.write_bytes(plistlib.dumps(values))
                run("xcrun", "simctl", "boot", identifier)
                run("xcrun", "simctl", "bootstatus", identifier, "-b")
                run("xcrun", "simctl", "ui", identifier, "appearance", "light")
                run(
                    "xcrun",
                    "simctl",
                    "status_bar",
                    identifier,
                    "override",
                    "--time",
                    # simctl rejects ISO timestamps without fractional seconds.
                    "2026-09-30T09:41:00.000+00:00",
                    "--dataNetwork",
                    "wifi",
                    "--wifiMode",
                    "active",
                    "--wifiBars",
                    "3",
                    "--batteryState",
                    "charged",
                    "--batteryLevel",
                    "100",
                )
                with (output / f"{family}-build.log").open("w") as log:
                    subprocess.run(
                        [
                            "xcodebuild",
                            "-project",
                            str(IOS / "TracyApp.xcodeproj"),
                            "-scheme",
                            "TracyMarketing",
                            "-destination",
                            f"platform=iOS Simulator,id={identifier}",
                            "-derivedDataPath",
                            str(IOS / "DerivedDataMarketing"),
                            "-resultBundlePath",
                            str(result),
                            "-parallel-testing-enabled",
                            "NO",
                            "CODE_SIGNING_ALLOWED=NO",
                            "test",
                        ],
                        check=True,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                export = stage / f"{family}-attachments"
                run(
                    "xcrun",
                    "xcresulttool",
                    "export",
                    "attachments",
                    "--path",
                    str(result),
                    "--output-path",
                    str(export),
                )
                manifest["devices"][family] = package_device(
                    export, package / "en-US" / family, dimensions
                )
            finally:
                run("xcrun", "simctl", "delete", identifier)
        (package / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        archive = output / f"tracy-app-store-{args.version}.zip"
        with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
            for path in sorted(package.rglob("*")):
                if path.is_file():
                    bundle.write(path, path.relative_to(package))
        # Keep convenient PNGs alongside the uploadable archive.
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(output / args.version)
        print(f"App Store screenshots: {archive}", flush=True)
    shutil.rmtree(stage)


if __name__ == "__main__":
    main()
