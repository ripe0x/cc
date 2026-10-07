# v2 artifacts

prebuilt artcoins v2 contracts, vendored so the engine tests can deploy the real v2 stack onto the pinned fork without compiling v2 sources.

* source: github.com/ripe0x/artcoins branch v2, commit 87a75228 (clone at /home/claude/nmcl/v2)
* compiler: solc 0.8.26 (svm binary, `~/.local/share/svm/0.8.26/solc-0.8.26`), forge 1.5.1
* profile: `ci` of the v2 foundry.toml (the one script/v2/env/mainnet.env selects): viaIR, optimizer runs 200, yul stackAllocation, evm cancun, bytecode_hash none, cbor_metadata false
* libs: the eight v2 submodules at the commits `git submodule status` lists (checked out from a sibling copy at the same hashes, the clone had empty lib folders)

## build

```
cd /home/claude/nmcl/v2
FOUNDRY_PROFILE=ci forge build --skip test --skip script     # about 75 s, 257 files
```

do not pass `src/v2/...` paths: with this forge a path filter leaves some artifacts unwritten. then run the trimming step (abi, bytecode.object, deployedBytecode.object, linkReferences only) over `foundry-out/<File>.sol/<Name>.json`. the hook artifact is `foundry-out/hooks/ArtCoinsHookV2.sol/ArtCoinsHookV2.json` (the other `ArtCoinsHookV2.sol` folder is the v1 legacy hook with the same name).

## files (runtime bytes, ci profile)

| file | runtime | note |
|---|---|---|
| ArtCoinsFeeEscrowV2.json | 3,844 | |
| ArtCoinsPoolExtensionAllowlist.json | 868 | v1 tree contract the v2 deploy lib uses |
| ArtCoinsHookV2.json | 15,741 | src/v2/hooks, mined by CREATE2, flags 0x28CC |
| ArtCoinsLpLockerV2.json | 13,586 | |
| ArtCoinsMevLinearSkimV2.json | 2,432 | |
| ArtCoinsFactoryV2.json | 19,771 | |
| ArtCoinsDeployerV2.json | 15,536 | creates the coin; embeds the token creation code |
| BurnRouterV2.json | 9,303 | |
| ProtocolFeeControllerV2.json | 3,930 | |
| ArtCoinsKeeperV2.json | 3,548 | |
| FeeAutoSwapperV2.json | 9,119 | not in DeployV2Lib, deployed per coin by the owner |
| ArtCoinsTokenV2.json | 9,464 | abi and reference bytecode, the factory launches its own copy |

no contract has link references (no external libraries). STATUS.md quotes hook 16,716 and deployer 21,166 for ci; this build gives 15,741 and 15,536, so those doc numbers do not match this commit (see docs/V2-PORT.md notes).

## regenerate

1. run the build above, 2. trim each artifact to `{abi, bytecode:{object,linkReferences}, deployedBytecode:{object,linkReferences}}`, 3. rerun `forge test --match-path test/V2Stack.t.sol`. loaded with `vm.getCode("test/v2-artifacts/<Name>.json")`.
