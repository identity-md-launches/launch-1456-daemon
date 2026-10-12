# Local verification results

Date: 2026-10-12. Foundry profile: the existing, unchanged repository configuration.

- Forge 1.8.3, commit `cae51ad458f6abb64852b7709eb784352429825d`.
- Solc **0.8.26+commit.8a97fa7a**, pinned by `foundry.toml`.
- Cancun, optimizer 200 runs, no via-IR, bytecode hash none, FFI disabled, no filesystem cheatcodes.
- No RPC, environment-variable reads/writes, external APIs or network-dependent fixtures in tests.
- All source dependencies are repository files. No package install or submodule is required.

| Command | Result |
| --- | --- |
| `forge build` | Exit 0; full compiler/lint output in `build.txt` |
| `forge test` | Exit 0; **92 passed, 0 failed, 0 skipped**, 8 suites; `test.txt` |
| `forge fmt --check` | Exit 0; `fmt.txt` is empty because success emits no output |
| `python3 scripts/export_abis.py --check` | Exit 0; 8 ABIs match compiler artifacts |
| `python3 scripts/verify_sources.py` | Exit 0; 21 factory/OZ source fixtures and 16 exact v4 files verified offline |
| Runtime artifact inspection | All 5 application contracts below 24,576 bytes; no link placeholders; `contract-sizes.json` |

Test breakdown:

| Suite | Passed | Coverage |
| --- | ---: | --- |
| DaemonHookTest | 20 | Four native swap modes, fees, dust, settlement, partial fills, forwarding, authorization |
| HookOrderMatrixTest | 9 | Eight explicit synthetic callback combinations plus order/direction/mode fuzzing |
| DaemonTokenTest | 5 | Original fixed supply, transfer behavior, no additional mint/burn |
| DeployTest | 3 | Explicit-config local helper, missing config, public-chain broadcast refusal |
| DistributionReceiverTest | 6 | 4:1:2 allocation, conservation fuzzing, partial distributions, authorization |
| FactoryIntegrationTest | 7 | Actual verified launch/fees code; exact allocation, creator authorization, 80/20 split, retries |
| GameRewardsTest | 27 | Ladder, season, authorization, locked roles, budgets, duplicate awards/claims/NFTs, failed receivers |
| NFTTreasuryTest | 15 | ETH/token purchasing, caps, all allowlists, deadlines, temporary approvals, custody, reentrancy |
| Total | **92** | All passed |

The four fuzz tests ran the configuration's 64 cases each. `forge test` uses a fresh isolated fixture for
each case/test and has no test ordering dependency. Its default parallel test runner was used. No
special environment or tests under `test/scratch/` are needed for the recorded results.

Foundry emitted lint warnings; the build is not represented as warning-free. Warnings include deliberate
signed-delta casts, timestamp bounds, externally observed balances, bounded allocation-loop calls,
Solmate's lack of an internal code-presence check and event-analysis heuristics. The source bounds
casts, validates configured assets/typed balance calls, limits publication to 128 entries, authenticates
external targets and guards treasury/reward interactions against reentrancy. The full output is retained
for independent review. These checks do not replace that review.

## Reproduce

From the repository root, with Foundry and the pinned compiler available:

```sh
forge build
forge test
forge fmt --check
python3 scripts/verify_sources.py
python3 scripts/export_abis.py --check
```

To regenerate ABIs after an intentional source change, run `forge build` followed by
`python3 scripts/export_abis.py`. This does not modify any build configuration or dependency path.

The factory source verification is local evidence of the downloaded Sourcify full-match source and
its import-only adaptation. It is not a mainnet fork or live integration. No Slither/Mythril run,
independent security review, deployment, payer signature, real match or website update is claimed.
