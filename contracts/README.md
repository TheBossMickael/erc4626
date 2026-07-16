# Contracts — Foundry project

Solidity sources of the RWA vault. The full story — architecture, decision
log, invariants, threat model — lives in the [repo README](../README.md)
and [/docs](../docs).

```bash
forge build
forge test        # 77 tests: unit lifecycle + fuzzed invariants I1–I9
forge fmt --check
```

OpenZeppelin Contracts v5.2.0 is pinned as a submodule in `lib/`. The
optimizer settings in `foundry.toml` are deployment-critical — unoptimized,
the vault's runtime bytecode exceeds the EIP-170 size limit; don't change
them.

Deployment: `script/Deploy.s.sol`; the live Sepolia record is in
[docs/operations.md](../docs/operations.md).
