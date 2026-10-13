"""Exercise the workflow's download command without downloading a simulator."""

import json
import os
from pathlib import Path
import re
import subprocess
import textwrap

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize(
    "installed_build,available", [(None, False), ("24A434", True), ("24A434", False), ("old", True)]
)
def test_ci_download_requests_the_build_it_verifies(tmp_path, installed_build, available):
    workflow = (ROOT / ".github/workflows/ios.yml").read_text()
    build = re.search(r"^      IOS_RUNTIME_BUILD: (\S+)$", workflow, re.MULTILINE).group(1)
    command = textwrap.dedent(
        re.search(
            r"- name: Install matching simulator runtime\n        run: \|\n(.*?)      - name:",
            workflow,
            re.DOTALL,
        ).group(1)
    )
    runtimes = (
        []
        if installed_build is None
        else [
            {
                "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
                "buildversion": installed_build,
                "isAvailable": available,
            }
        ]
    )
    runtime_file = tmp_path / "runtimes.json"
    runtime_file.write_text(json.dumps({"runtimes": runtimes}))
    simctl = tmp_path / "xcrun"
    simctl.write_text('#!/bin/sh\ncat "$RUNTIMES"\n')
    simctl.chmod(0o755)
    recorder = tmp_path / "xcodebuild"
    recorder.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$CAPTURE"\n')
    recorder.chmod(0o755)
    capture = tmp_path / "arguments"
    subprocess.run(
        ["sh", "-eu", "-c", command],
        env={
            **os.environ,
            "PATH": f"{tmp_path}:{os.environ['PATH']}",
            "IOS_RUNTIME_BUILD": build,
            "CAPTURE": str(capture),
            "RUNTIMES": str(runtime_file),
        },
        check=True,
    )
    if installed_build == build and available:
        assert not capture.exists()
        return
    arguments = capture.read_text().splitlines()
    requested = arguments[arguments.index("-buildVersion") + 1]
    assert requested == build == "24A434"
    assert requested != "27.0"  # Version aliases can select a different runtime build.
