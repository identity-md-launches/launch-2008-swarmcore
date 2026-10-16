// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @dev Drives the token with unbounded amounts, arbitrary recipients and an unfunded stranger
/// sending arbitrary calldata. Every call's outcome is predicted from a ghost ledger before it is
/// made, so both the success and the failure path of each entrypoint are checked on every step,
/// and the handler itself never reverts.
contract SwarmCoreAdversarialHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant ACTORS = 6;

    SwarmCore public immutable token;
    address public immutable deployer;
    address public immutable attacker;
    address[ACTORS] public actors;
    address[] public touched;
    mapping(address => bool) internal isTouched;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    /// @dev Sum of every finite approval granted, an upper bound on what a spender can ever move.
    mapping(address => mapping(address => uint256)) public ghostApprovedTotal;
    mapping(address => mapping(address => bool)) public ghostEverUnlimited;
    mapping(address => mapping(address => uint256)) public ghostSpentTotal;
    mapping(address => uint256) public ghostOutflow;
    mapping(address => uint256) public ghostInflow;

    uint256 public calls;
    uint256 public successes;
    uint256 public rejections;
    uint256 public strangerCalls;
    uint256 public skipped;

    constructor() {
        deployer = address(this);
        attacker = makeAddr("adversarial stranger");
        token = new SwarmCore();
        actors[0] = address(this);
        _touch(address(this));
        for (uint256 i = 1; i < ACTORS; ++i) {
            address actor = makeAddr(string.concat("adversarial actor ", vm.toString(i)));
            actors[i] = actor;
            _touch(actor);
        }
        ghostBalance[address(this)] = SUPPLY;
        ghostInflow[address(this)] = SUPPLY;
        // Uneven seeding: one whale, several small holders, one empty actor.
        uint256[ACTORS] memory seeds = [uint256(0), SUPPLY / 2, SUPPLY / 10, 1 ether, 1, 0];
        for (uint256 i = 1; i < ACTORS; ++i) {
            if (seeds[i] == 0) continue;
            assertTrue(token.transfer(actors[i], seeds[i]));
            ghostBalance[address(this)] -= seeds[i];
            ghostBalance[actors[i]] += seeds[i];
            ghostOutflow[address(this)] += seeds[i];
            ghostInflow[actors[i]] += seeds[i];
        }
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function _touch(address account) internal {
        if (!isTouched[account]) {
            isTouched[account] = true;
            touched.push(account);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % ACTORS];
    }

    /// @dev Picks an actor most of the time, otherwise an arbitrary non-zero address so balances
    /// can leak out to bystanders and must still be accounted for.
    function _recipient(uint256 seed, address arbitrary) internal returns (address to) {
        bool usable = arbitrary != address(0) && arbitrary != attacker && arbitrary != address(token);
        if (seed % 8 == 0 && usable) {
            to = arbitrary;
        } else {
            to = _actor(seed);
        }
        _touch(to);
    }

    function _amount(uint256 seed, uint256 ceiling) internal pure returns (uint256) {
        // Mostly within reach; sometimes at, just above, or far above it; sometimes zero.
        uint256 mode = seed % 10;
        if (mode == 0) return 0;
        if (mode == 1) return ceiling;
        if (mode == 2) return ceiling == type(uint256).max ? ceiling : ceiling + 1;
        if (mode == 3) return type(uint256).max;
        if (mode == 4) return SUPPLY + 1;
        return bound(seed, 0, ceiling);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, address arbitrary, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed, arbitrary);
        uint256 balance = ghostBalance[from];
        uint256 amount = _amount(amountSeed, balance);
        calls++;
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertLe(amount, balance, "transfer above balance succeeded");
            successes++;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ghostOutflow[from] += amount;
            ghostInflow[to] += amount;
        } catch (bytes memory reason) {
            assertGt(amount, balance, "transfer within balance reverted");
            assertEq(
                reason,
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
                "wrong revert reason"
            );
            rejections++;
        }
    }

    function transferToZero(uint256 fromSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        uint256 amount = _amount(amountSeed, ghostBalance[from]);
        calls++;
        vm.prank(from);
        try token.transfer(address(0), amount) {
            assertTrue(false, "transfer to the zero address succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            rejections++;
        }
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, address arbitrary, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _recipient(spenderSeed, arbitrary);
        uint256 amount = _amount(amountSeed, SUPPLY);
        calls++;
        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        assertTrue(ok, "approve returned false");
        successes++;
        ghostAllowance[owner][spender] = amount;
        if (amount == type(uint256).max) {
            ghostEverUnlimited[owner][spender] = true;
        } else {
            ghostApprovedTotal[owner][spender] += amount;
        }
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        calls++;
        vm.prank(owner);
        try token.approve(address(0), amount) {
            assertTrue(false, "approval of the zero spender succeeded");
        } catch (bytes memory reason) {
            assertEq(reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            rejections++;
        }
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, address arbitrary, uint256 amountSeed)
        external
    {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        address to = _recipient(toSeed, arbitrary);
        uint256 balance = ghostBalance[from];
        uint256 allowed = ghostAllowance[from][spender];
        uint256 reach = balance < allowed ? balance : allowed;
        uint256 amount = _amount(amountSeed, reach);
        calls++;
        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertLe(amount, allowed, "transferFrom above allowance succeeded");
            assertLe(amount, balance, "transferFrom above balance succeeded");
            successes++;
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ghostOutflow[from] += amount;
            ghostInflow[to] += amount;
            ghostSpentTotal[from][spender] += amount;
            if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        } catch (bytes memory reason) {
            bytes memory expected = amount > allowed
                ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount);
            assertTrue(amount > allowed || amount > balance, "transferFrom within reach reverted");
            assertEq(reason, expected, "wrong revert reason");
            rejections++;
        }
    }

    /// @dev Whatever an unfunded stranger with no approvals sends, it may only touch its own
    /// approvals. The invariants check that nothing tracked moved.
    function strangerCall(bytes4 selector, bytes calldata args) external {
        calls++;
        strangerCalls++;
        vm.prank(attacker);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        ok;
    }

    /// @dev The deployer is just another holder: it may not pull from anyone who did not approve it.
    function deployerPullsWithoutApproval(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        if (from == address(this)) from = actors[1];
        calls++;
        uint256 allowed = ghostAllowance[from][address(this)];
        if (allowed != type(uint256).max) {
            amount = bound(amount, allowed + 1, type(uint256).max);
            try token.transferFrom(from, address(this), amount) {
                assertTrue(false, "deployer pulled above its allowance");
            } catch (bytes memory reason) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientAllowance.selector, address(this), allowed, amount
                    )
                );
                rejections++;
            }
        } else {
            skipped++;
        }
    }
}

/// @notice Invariants that must survive any sequence the handler produces: a fixed supply fully
/// accounted for by tracked balances, a ledger that matches the token exactly, allowances that only
/// move by approval or authorised spending, and a stranger that never gains anything.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmCoreAdversarialInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmCoreAdversarialHandler internal handler;
    SwarmCore internal token;

    function setUp() public {
        handler = new SwarmCoreAdversarialHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.transferToZero.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.approveZeroSpender.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.strangerCall.selector;
        selectors[6] = handler.deployerPullsWithoutApproval.selector;
        selectors[7] = handler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyIsFixedAndFullyHeldByTrackedAccounts() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, SUPPLY, "tokens leaked to an untracked account or vanished");
    }

    function invariant_everyTrackedBalanceMatchesTheLedger() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address account = handler.touched(i);
            uint256 balance = token.balanceOf(account);
            assertEq(balance, handler.ghostBalance(account), "balance drifted from ledger");
            assertLe(balance, SUPPLY, "balance above supply");
            assertEq(
                handler.ghostInflow(account) - handler.ghostOutflow(account), balance, "flows do not explain balance"
            );
        }
    }

    function invariant_allowancesMoveOnlyByApprovalOrAuthorisedSpending() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < 6; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < n; ++j) {
                address spender = handler.touched(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
                if (!handler.ghostEverUnlimited(owner, spender)) {
                    assertLe(
                        handler.ghostSpentTotal(owner, spender),
                        handler.ghostApprovedTotal(owner, spender),
                        "a spender moved more than it was ever approved"
                    );
                }
            }
        }
    }

    function invariant_strangerAndNonParticipantsHoldNothing() public view {
        address stranger = handler.attacker();
        assertEq(token.balanceOf(stranger), 0, "the stranger acquired tokens");
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
        for (uint256 i; i < 6; ++i) {
            assertEq(token.allowance(handler.actors(i), stranger), 0, "the stranger acquired an allowance");
        }
    }

    function invariant_everyCallWasEitherAcceptedOrRejectedAsPredicted() public view {
        assertEq(
            handler.successes() + handler.rejections() + handler.strangerCalls() + handler.skipped(),
            handler.calls(),
            "a call was neither accepted nor rejected as predicted"
        );
    }
}
