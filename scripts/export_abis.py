#!/usr/bin/env python3
"""Export checked build ABIs. Run forge build first; --check refuses stale delivery files."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = [
    "DaemonToken", "DaemonHook", "NFTTreasury", "GameRewards",
    "DistributionReceiver", "Deploy", "ICreatorFeeFactory", "HookFlags",
]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
for name in CONTRACTS:
    source = "Deploy.s.sol" if name == "Deploy" else name + ".sol"
    artifact = json.loads((ROOT / "out" / source / (name + ".json")).read_text())
    expected = json.dumps(artifact["abi"], indent=2) + "\n"
    target = ROOT / "abi" / (name + ".json")
    if args.check:
        if not target.exists() or target.read_text() != expected:
            raise SystemExit(f"Stale or missing ABI: {target}")
    else:
        target.write_text(expected)
print(f"{'Checked' if args.check else 'Exported'} {len(CONTRACTS)} ABIs")
