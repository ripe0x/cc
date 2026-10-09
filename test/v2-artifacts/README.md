# v2 artifacts

build output of `FeeAutoSwapperV2`, the one v2 contract the tests deploy themselves. it is deployed per coin by the owner and is not part of the live stack (script/config/v2-mainnet.json), so there is no chain copy to attach to. test/utils/V2Stack.sol `deploySwapper` loads it with `vm.getCode`.

* source: github.com/ripe0x/new-material-coin-launcher, `src/v2/FeeAutoSwapperV2.sol`, contract sources of commit d4aa46b2c30a9e23100ac3a390bff971d99e4003 (unchanged at the deployed commit fbe07c7)
* compiler: solc 0.8.26, forge 1.8.1, profile `ci` of the v2 foundry.toml (viaIR, optimizer runs 200, evm cancun, bytecode_hash none, cbor_metadata false)
* runtime size: 8,950 bytes, no link references

## regenerate

```
cd <clone of the launcher at the commit above, submodules initialised>
FOUNDRY_PROFILE=ci forge build --skip test --skip script
```

then trim `foundry-out/FeeAutoSwapperV2.sol/FeeAutoSwapperV2.json` to `{abi, bytecode:{object,linkReferences}, deployedBytecode:{object,linkReferences}}`.
