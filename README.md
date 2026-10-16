# SwarmCore (SWARMCOR)

SwarmCore is a fixed-supply ERC-20. Its constructor mints **1,000,000,000 tokens with 18 decimals** to the immediate deployer in one issuance. The implementation is [src/SwarmCore.sol](src/SwarmCore.sol), using the vendored OpenZeppelin Contracts v5.0.2 ERC-20 implementation.

## Deployment parameters

| Parameter | Value |
| --- | --- |
| Solidity contract | `SwarmCore` |
| Artifact | `out/SwarmCore.sol/SwarmCore.json` |
| Constructor arguments | None (`[]`) |
| Native currency sent with deployment | None |
| Token name | `SwarmCore` |
| Token symbol | `SWARMCOR` |
| Decimals | `18` |
| `INITIAL_SUPPLY` / `totalSupply()` | `1000000000000000000000000000` base units (`10^27`) |
| Initial recipient | Constructor `msg.sender` |
| Launch chain | Ethereum, chain ID 1 |
| Compiler / EVM target | Solidity `0.8.26` / `cancun` |
| Optimizer | Enabled, 200 runs |
| Metadata bytecode hash | `none` |

Deploy the artifact's creation bytecode without appending constructor arguments. When a factory deploys it, the factory receives the entire supply; the transaction origin and the caller of the factory receive nothing from the constructor. There are no constructor calls to other contracts, linked libraries, initialization transactions, owner addresses, or external service parameters.

The network's separate launch process deploys the contract and supplies its manifest. This repository does not broadcast transactions or contain a launch manifest. No application contracts are needed.

## Behavior and assumptions

- The requested custom token uses ordinary ERC-20 transfer and approval behavior. No transfer tax, burn, rebase, vesting, transfer limits, or other optional token extensions are assumed.
- There are no externally callable mint or burn methods. The total supply remains `10^27` base units throughout the deployed contract's lifetime.
- There is no owner, administrator, pause, blacklist, seizure, or upgrade mechanism. The deployer has the same transfer permissions as any other holder.
- Successful `transfer`, `approve`, and `transferFrom` return `true`; invalid operations revert with the vendored ERC-20 custom errors. Failed transfers also roll back allowance changes.
- Zero-value transfers to nonzero addresses succeed and emit `Transfer`. Transfers to the zero address and approvals of the zero address revert. Self-transfers preserve balances but require sufficient balance; delegated self-transfers still spend finite allowances.
- `approve` replaces the existing allowance. Finite allowances decrease on `transferFrom`; the maximum `uint256` allowance remains unchanged. `Approval` is emitted on explicit approval, while this implementation does not emit it on allowance spending. Integrations should query `allowance` for the current value.
- The constructor emits one `Transfer` from the zero address. Subsequent transfers emit standard `Transfer` events. There are no recipient callbacks or other external calls in token operations.

## After launch

No token settings need to be configured, and no administrator needs to maintain the contract. The launch operator is responsible for deploying the exact reviewed artifact, verifying the source and metadata, confirming the supply and initial factory balance, and carrying out the launch distribution through ordinary transfers.

The launch terms allocate 10% to the network distributor, 88% to pool seeding, and 2% to the requester's designated remainder recipient. These are responsibilities of the launch factory and manifest process; the token initially allocates 100% to its deployer and imposes no address-specific transfer rules. Pair selection, liquidity, opening price, and pool fees are managed outside this token.

Holders and integrating applications are responsible for destination addresses and spending approvals. Prefer allowances limited to the required amount, revoke unused approvals, and consider setting an existing allowance to zero and waiting for confirmation before replacing it to reduce the standard ERC-20 allowance-change race. The token does not recover lost keys or assets sent to an inaccessible address or to the token contract itself. Ordinary native-currency payments revert; forcibly received native currency cannot be withdrawn.

## Build and test

Foundry and Solidity 0.8.26 are toolchain prerequisites. Solidity dependencies and their licenses are included as ordinary files under `lib/`. Builds and tests require no RPC, wallet, environment configuration, dependency download, or filesystem cheatcode permissions. See [DEPENDENCIES.md](DEPENDENCIES.md) for versions, provenance, and integrity hashes.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x3316a94f86d139d5689ec4a85324b772f1ed4bfd909f96cca11f907a9ad4d837 forge test
forge fmt --check
```

`foundry.toml` uses 512 cases per fuzz test and 256 invariant sequences of up to 64 calls. It does not pin a seed, so the command above selects the assignment's verification seed. Every test creates fresh fixtures and can run independently and in parallel. No test reads or changes environment variables.

- Unit tests cover exact metadata and issuance, mint event count, factory deployment, untaxed distribution and settlement transfers, approval replacement/revocation, event and return-value behavior, self/zero/full-balance transfers, infinite allowance semantics, failure atomicity, unauthorized spending, rejected admin selectors, native-currency rejection, and forbidden runtime opcodes.
- Fuzz tests cover arbitrary recipients and quantities, balance conservation, delegated allowance accounting, and rejected transfers above the available balance or allowance.
- Stateful invariant tests compare every tracked balance and allowance with an independent ledger after randomized transfers, approvals, delegated transfers, and failed overspends. Both supply conservation and authorization accounting must hold throughout each sequence.

The local factory and pool-address fixtures test ERC-20 transfer behavior, not Uniswap pool initialization or real swaps. The supplied protected integration tests depend on the network's separate launch harness, contracts, and resolved manifest inputs; those are not available in this project and are not claimed as executed locally.

## Review scope

The security review for this delivery checks the pinned ERC-20 implementation, the single constructor mint, absence of privileged entrypoints, allowance boundaries, exact transfer accounting, and the lack of external calls, proxies, or linked code. Reentrancy guards, oracle checks, signature validation, and randomness are unnecessary for this contract because those mechanisms are absent. Validation uses Foundry unit tests, fuzzing, invariant tests, and compilation; Slither and Mythril have not been run. This work is not an independent security audit. The network's independent review and deployed-source verification remain release responsibilities.
