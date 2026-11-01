"""Install missing pinned runtimes and verify availability after every download."""

import argparse
import json
import subprocess

RUNTIMES = {"27.0": "24A434", "27.1": "24A94232"}


def available(version):
    result = subprocess.run(
        ["xcrun", "simctl", "list", "runtimes", "--json"],
        check=True,
        capture_output=True,
        text=True,
    )
    identifier = "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")
    return any(
        runtime["identifier"] == identifier
        and runtime["buildversion"] == RUNTIMES[version]
        and runtime["isAvailable"]
        for runtime in json.loads(result.stdout)["runtimes"]
    )


def ensure(version):
    if not available(version):
        result = subprocess.run(
            [
                "xcodebuild",
                "-downloadPlatform",
                "iOS",
                "-buildVersion",
                RUNTIMES[version],
                "-architectureVariant",
                "arm64",
            ],
            check=False,
        )
        # Xcode may return 70 for a cached download. Availability is authoritative;
        # a nonzero exit never excuses an absent or mismatched runtime.
        if not available(version):
            raise RuntimeError(
                f"iOS {version} ({RUNTIMES[version]}) unavailable after download "
                f"(exit {result.returncode})"
            )
    print(f"Verified iOS {version} ({RUNTIMES[version]})", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("versions", nargs="+", choices=RUNTIMES)
    for version in parser.parse_args().versions:
        ensure(version)
