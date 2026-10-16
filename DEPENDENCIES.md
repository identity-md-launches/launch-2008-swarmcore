# Vendored dependencies

All dependencies are ordinary source files under `lib/`; no package install, Git submodule, or network access is needed to build and test. Solidity 0.8.26 must be installed in the Foundry toolchain.

## openzeppelin-contracts

- Source: https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2
- Archive: https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
- Archive SHA-256: `18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a`
- Contents: unmodified Solidity sources and upstream licenses only.

## forge-std

- Source: https://github.com/foundry-rs/forge-std/tree/v1.9.7
- Archive: https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7
- Archive SHA-256: `45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94`
- Contents: unmodified Solidity sources and upstream licenses only.

OpenZeppelin includes only the ERC-20 implementation and its transitive imports (MIT). forge-std includes its `src/` tree for tests (MIT or Apache-2.0). Neither dependency is a separately deployed contract.

Verify vendored file integrity with `sha256sum -c lib/SHA256SUMS`.
