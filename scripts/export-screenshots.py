"""Copy named screenshots from an .xcresult bundle into a folder as <name>.png.

Usage: export-screenshots.py <result.xcresult> <output-folder>
"""
import json
import re
import pathlib
import shutil
import subprocess
import sys
import tempfile

result, output = sys.argv[1], pathlib.Path(sys.argv[2])
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as temp:
    subprocess.run(
        ["xcrun", "xcresulttool", "export", "attachments", "--path", result, "--output-path", temp],
        check=True, capture_output=True)
    manifest = json.loads((pathlib.Path(temp) / "manifest.json").read_text())
    count = 0
    for test in manifest:
        for attachment in test["attachments"]:
            name = attachment["suggestedHumanReadableName"].split("_0_")[0]
            if not re.fullmatch(r"[a-z0-9-]+", name):
                continue  # Xcode's automatic failure captures.
            shutil.copy(pathlib.Path(temp) / attachment["exportedFileName"], output / f"{name}.png")
            count += 1
print(f"{count} screenshots in {output}")
