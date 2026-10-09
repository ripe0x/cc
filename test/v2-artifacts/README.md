# v2 artifacts

prebuilt artcoins v2 contracts, vendored so the engine tests can deploy the real v2 stack onto the pinned fork without compiling v2 sources.

* source: github.com/ripe0x/new-material-coin-launcher branch v2-legibility, commit d4aa46b2c30a9e23100ac3a390bff971d99e4003, built 2026-10-09
* compiler: solc 0.8.26 (0.8.26+commit.8a97fa7a), forge 1.8.1 (982849d3, 2026-08-28)
* profile: `ci` of the v2 foundry.toml (the one script/v2/env/mainnet.env selects): viaIR, optimizer runs 200, yul stackAllocation, evm cancun, bytecode_hash none, cbor_metadata false
* libs: the eight v2 submodules at the commits `git submodule status` lists (forge-std, openzeppelin-contracts, openzeppelin-contracts-upgradeable, permit2, solady, universal-router, v4-core, v4-periphery)

## build

```
cd <clone of the branch above, submodules initialised>
FOUNDRY_PROFILE=ci forge build --skip test --skip script     # about 3 min cold, 260 files
```

do not pass `src/v2/...` paths: with this forge a path filter leaves some artifacts unwritten. then run the trimming step (abi, bytecode.object, deployedBytecode.object, linkReferences only) over `foundry-out/<File>.sol/<Name>.json`. the hook artifact is `foundry-out/hooks/ArtCoinsHookV2.sol/ArtCoinsHookV2.json` (the other `ArtCoinsHookV2.sol` folder is the v1 legacy hook with the same name).

## files (runtime bytes, ci profile)

| file | runtime | note |
|---|---|---|
| ArtCoinsFeeEscrowV2.json | 3,796 |  |
| ArtCoinsPoolExtensionAllowlist.json | 868 | v1 tree contract the v2 deploy lib uses |
| ArtCoinsHookV2.json | 16,170 | src/v2/hooks, mined by CREATE2, flags 0x28CC |
| ArtCoinsLpLockerV2.json | 15,482 |  |
| ArtCoinsMevLinearSkimV2.json | 2,280 |  |
| ArtCoinsFactoryV2.json | 19,272 |  |
| ArtCoinsDeployerV2.json | 14,665 | creates the coin; embeds the token creation code |
| BurnRouterV2.json | 9,526 |  |
| ProtocolFeeControllerV2.json | 4,048 |  |
| ArtCoinsKeeperV2.json | 3,643 |  |
| FeeAutoSwapperV2.json | 8,950 | not in DeployV2Lib, deployed per coin by the owner |
| ArtCoinsTokenV2.json | 9,154 | abi and reference bytecode, the factory launches its own copy |

no contract has link references (no external libraries).

## regenerate

1. run the build above, 2. trim each artifact to `{abi, bytecode:{object,linkReferences}, deployedBytecode:{object,linkReferences}}`, 3. rerun `forge test --match-path test/V2Stack.t.sol`. loaded with `vm.getCode("test/v2-artifacts/<Name>.json")`.
