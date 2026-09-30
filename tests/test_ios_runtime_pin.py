"""Exercise the workflow's download command without downloading a simulator."""

import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def test_ci_download_requests_the_build_it_verifies(tmp_path):
    workflow = (ROOT / ".github/workflows/ios.yml").read_text()
    build = re.search(r"^      IOS_RUNTIME_BUILD: (\S+)$", workflow, re.MULTILINE).group(1)
    command = re.search(
        r"- name: Install matching simulator runtime\n        run: (.+)", workflow
    ).group(1)
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
        },
        check=True,
    )
    arguments = capture.read_text().splitlines()
    requested = arguments[arguments.index("-buildVersion") + 1]
    assert requested == build == "23C52"
    assert requested != "26.2"  # Version aliases may resolve to 23C54 instead.
