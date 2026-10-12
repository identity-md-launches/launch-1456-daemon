#!/usr/bin/env python3
"""Offline provenance check against the saved Sourcify full-match sources.

The ONLY adaptations allowed in factory fixtures are the @openzeppelin import prefix
and forge formatting. Existing v4 dependencies must match the original byte-for-byte.
No network, environment variables, or dependency installation is required.
"""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "docs/factory-source.json").read_text())
sources = json.loads((ROOT / "docs/verified-sources.json").read_text())
assert manifest["creationMatch"] == manifest["runtimeMatch"] == "match"
for target, entry in manifest["files"].items():
    original = sources[entry["originalPath"]]["content"]
    assert hashlib.sha256(original.encode()).hexdigest() == entry["originalSha256"], target
    adapted = original.replace("@openzeppelin/contracts/", "./openzeppelin/") if entry["originalPath"].startswith("src/") else original
    expected = subprocess.run(["forge", "fmt", "--raw", "-"], input=adapted, text=True,
                              cwd=ROOT, capture_output=True, check=True).stdout
    assert (ROOT / target).read_text() == expected, f"Unexpected source changes: {target}"
v4_count = 0
for path, source in sources.items():
    if path.startswith("lib/v4-core/"):
        assert (ROOT / path).read_text() == source["content"], f"v4 source mismatch: {path}"
        v4_count += 1
print(f"Verified {len(manifest['files'])} factory/OZ fixtures and {v4_count} exact v4 interfaces/types/libraries offline")
