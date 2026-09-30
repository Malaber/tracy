import os
from pathlib import Path
import subprocess

import pytest


@pytest.mark.parametrize("arguments, expected", [(["--ios"], ""), ([], "install-deps\n")])
def test_setup_native_mode_skips_web_dependencies(tmp_path, arguments, expected):
    script = Path(__file__).resolve().parents[1] / ".codex/setup.sh"
    binaries = tmp_path / ".venv/bin"
    binaries.mkdir(parents=True)
    for name, content in {
        "python": "#!/bin/sh\nexit 0\n",
        "inv": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$SETUP_CALLS"\n',
    }.items():
        executable = binaries / name
        executable.write_text(content)
        executable.chmod(0o755)
    log = tmp_path / "calls"
    subprocess.run(
        ["sh", str(script), *arguments],
        cwd=tmp_path,
        env={**os.environ, "SETUP_CALLS": str(log)},
        check=True,
    )
    assert (log.read_text() if log.exists() else "") == expected


def test_setup_rejects_unknown_mode_before_installing(tmp_path):
    script = Path(__file__).resolve().parents[1] / ".codex/setup.sh"
    result = subprocess.run(["sh", str(script), "--unknown"], cwd=tmp_path, capture_output=True)
    assert result.returncode == 2
    assert not (tmp_path / ".venv").exists()
