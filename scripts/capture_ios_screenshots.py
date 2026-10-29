"""Capture actual native UI; validate and package Apple-sized, opaque PNGs."""

import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading
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
DERIVED_DATA = ROOT / "e2e-artifacts/ios-marketing-derived-data"
RUNTIMES = {
    "27.0": ("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "24A434"),
    "27.1": ("com.apple.CoreSimulator.SimRuntime.iOS-27-1", "24A94232"),
}
DEVICES = {
    "iphone-6.3": ("iPhone 18 Pro", (1206, 2622), "27.0"),
    "ipad-13": ("iPad Pro 13-inch (M5)", (2064, 2752), "27.0"),
    "iphone-duo-outer": ("iPhone Duo", (1398, 2034), "27.1"),
    "iphone-duo-inner": ("iPhone Duo", (2853, 2007), "27.1"),
}
SCENES = (
    "01-today",
    "02-entry",
    "03-recent-days",
    "04-offline",
    "05-dark",
    "06-statistics",
    "07-settings",
    "08-empty-day",
    "09-completed-day",
    "10-month-forecast",
)


def run(*args):
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        print(result.stdout + result.stderr, file=sys.stderr, flush=True)
        result.check_returncode()
    return result.stdout.strip()


def xcodebuild(log_path, *arguments):
    """Keep full build logs and surface the failure context in the Actions log."""
    with log_path.open("w") as log:
        result = subprocess.run(
            [
                "xcodebuild",
                "-project",
                str(IOS / "TracyApp.xcodeproj"),
                "-scheme",
                "TracyMarketing",
                "-derivedDataPath",
                str(DERIVED_DATA),
                "-parallel-testing-enabled",
                "NO",
                "CODE_SIGNING_ALLOWED=NO",
                *arguments,
            ],
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    if result.returncode:
        print("\n".join(log_path.read_text().splitlines()[-80:]), file=sys.stderr, flush=True)
        result.check_returncode()


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
                rgb = image.convert("RGB")
                if max(high for low, high in rgb.getextrema()) <= 8:
                    raise ValueError(f"Blank or inactive display: {scene}")
                rgb.save(target)
            found[scene] = {
                "file": target.name,
                "width": dimensions[0],
                "height": dimensions[1],
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            }
    if set(found) != set(SCENES):
        raise ValueError(f"Missing screenshots: {set(SCENES) - set(found)}")
    return [found[scene] for scene in SCENES]


def start_native_capture(identifier, stage):
    """Serve native PNGs only to the local XCTest runner, synchronized per scene."""

    class CaptureHandler(BaseHTTPRequestHandler):
        def do_GET(self):
            scene = self.path.removeprefix("/")
            if scene not in SCENES:
                self.send_error(404)
                return
            try:
                path = stage / f"native-{scene}.png"
                run(
                    "xcrun",
                    "simctl",
                    "io",
                    identifier,
                    "screenshot",
                    "--display=primary-1",
                    str(path),
                )
                data = path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as error:
                self.send_error(500, str(error))

        def log_message(self, *_args):
            pass

    server = HTTPServer(("127.0.0.1", 0), CaptureHandler)
    bundle = (
        DERIVED_DATA
        / "Build/Products/Debug-iphonesimulator"
        / "TracyMarketingTests-Runner.app/PlugIns/TracyMarketingTests.xctest"
    )
    (bundle / "capture-port.txt").write_text(str(server.server_port))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument(
        "--device",
        choices=DEVICES,
        action="append",
        help="Capture selected device families; defaults to all",
    )
    args = parser.parse_args()
    if run("xcodebuild", "-version") != "Xcode 27.1\nBuild version 27A9275":
        raise SystemExit("Screenshot captures require Xcode 27.1 build 27A9275")
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    for version in {DEVICES[name][2] for name in (args.device or DEVICES)}:
        identifier, build = RUNTIMES[version]
        if not any(
            r["identifier"] == identifier and r["buildversion"] == build and r["isAvailable"]
            for r in runtimes
        ):
            raise SystemExit(f"Screenshot captures require iOS {version} build {build}")
    output = ROOT / "e2e-artifacts/app-store"
    output.mkdir(parents=True, exist_ok=True)
    hinge = output / "duo-hinge"
    if any("duo" in name for name in (args.device or DEVICES)):
        run(
            "xcrun",
            "--sdk",
            "iphonesimulator",
            "clang",
            "-target",
            "arm64-apple-ios27.1-simulator",
            "-fobjc-arc",
            "-framework",
            "Foundation",
            str(ROOT / "scripts/duo_hinge.m"),
            "-o",
            str(hinge),
        )
    # Compile before booting CoreSimulator, as in the regular native CI job.
    # This avoids concurrent compiler and simulator startup on the smaller CI host.
    print("Building screenshot runner", flush=True)
    xcodebuild(
        output / "build-for-testing.log",
        "-destination",
        "generic/platform=iOS Simulator",
        "build-for-testing",
    )
    manifest = {
        "version": args.version,
        "commit": run("git", "rev-parse", "HEAD"),
        "locale": "en-US",
        "xcode": "27.1 (27A9275)",
        "runtimes": RUNTIMES,
        "content": "Synthetic local UI-test data; real app screens, no live account",
        "devices": {},
    }
    with tempfile.TemporaryDirectory(dir=output, delete=False) as temporary:
        stage = Path(temporary)
        package = stage / "screenshots"
        for family in args.device or DEVICES:
            device, dimensions, version = DEVICES[family]
            print(f"Capturing {family}: {device}", flush=True)
            identifier = run(
                "xcrun", "simctl", "create", "Tracy marketing", device, RUNTIMES[version][0]
            )
            result = stage / f"{family}.xcresult"
            capture_server = None
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
                if "duo" in family:
                    run(
                        "xcrun",
                        "simctl",
                        "spawn",
                        identifier,
                        str(hinge),
                        "180" if family.endswith("inner") else "0",
                    )
                run(
                    "xcrun",
                    "simctl",
                    "status_bar",
                    identifier,
                    "override",
                    "--time",
                    # A literal clock stays stable across host time zones.
                    "09:41",
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
                if family.endswith("inner"):
                    capture_server = start_native_capture(identifier, stage)
                xcodebuild(
                    output / f"{family}-build.log",
                    "-destination",
                    f"platform=iOS Simulator,id={identifier}",
                    "-resultBundlePath",
                    str(result),
                    "-only-testing:TracyMarketingTests/MarketingScreenshots/"
                    + ("testCaptureDuoInner" if family.endswith("inner") else "testCapture"),
                    "test-without-building",
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
                if capture_server:
                    capture_server.shutdown()
                    capture_server.server_close()
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
