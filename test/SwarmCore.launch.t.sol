// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @dev Stands in for the launch factory: deploys through CREATE2 from its own address, in one call,
/// the token followed by application contracts, checking after each constructor that the supply is
/// whole and still here. Mirrors the shape of the network's launch probe without its pool machinery.
contract LaunchFactoryFixture {
    address public immutable controller = msg.sender;

    function deployAll(bytes[] memory codes, bytes32[] memory salts, uint256 expectedSupply)
        external
        returns (address[] memory deployed)
    {
        require(msg.sender == controller, "not the controller");
        require(codes.length > 0 && codes.length == salts.length, "invalid project list");
        deployed = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = salts[i];
            address created;
            assembly ("memory-safe") {
                created := create2(0, add(code, 32), mload(code), salt)
            }
            require(created != address(0) && created.code.length > 0, "constructor failed");
            deployed[i] = created;
            IERC20 token = IERC20(deployed[0]);
            require(token.totalSupply() == expectedSupply, "manifest supply mismatch");
            require(token.balanceOf(address(this)) == expectedSupply, "a constructor moved the launch supply");
        }
    }

    function move(IERC20 token, address to, uint256 amount) external returns (bool) {
        require(msg.sender == controller, "not the controller");
        return token.transfer(to, amount);
    }

    function predict(bytes memory code, bytes32 salt) external view returns (address) {
        return
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(code))))));
    }
}

/// @dev An application contract deployed after the token in the same launch call. It may read the
/// token in its constructor; it must not be able to move anything.
contract ReaderProjectFixture {
    IERC20 public immutable token;
    uint256 public immutable supplySeen;
    uint256 public immutable factoryBalanceSeen;
    bool public immutable pullFailed;

    constructor(IERC20 token_) {
        token = token_;
        supplySeen = token_.totalSupply();
        factoryBalanceSeen = token_.balanceOf(msg.sender);
        (bool ok,) =
            address(token_).call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), 1));
        pullFailed = !ok;
    }
}

/// @notice Launch-shaped and adversarial checks on top of the plain ERC-20 suite: what the factory
/// sees in one transaction, what an unknown caller can reach, and algebraic round trips over fuzzed
/// amounts and arbitrary addresses.
/// forge-config: default.fuzz.runs = 1000
contract SwarmCoreLaunchTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 internal constant SWARM_BPS = 1_000;

    SwarmCore internal token;
    address internal holder;
    address internal recipient;
    address internal spender;
    address internal attacker;

    function setUp() public {
        holder = makeAddr("holder");
        recipient = makeAddr("recipient");
        spender = makeAddr("spender");
        attacker = makeAddr("attacker");
        token = new SwarmCore();
    }

    // ---------------------------------------------------------------------------------------------
    // Launch shape: CREATE2 from the factory, one transaction, project contracts after the token.
    // ---------------------------------------------------------------------------------------------

    function test_creationCodeTakesNoConstructorArguments() public {
        bytes memory code = type(SwarmCore).creationCode;
        assertGt(code.length, 0);
        // The manifest records constructorArgs = []; appending anything is not needed for deployment.
        address created;
        assembly ("memory-safe") {
            created := create(0, add(code, 32), mload(code))
        }
        assertTrue(created != address(0));
        assertEq(SwarmCore(created).totalSupply(), SUPPLY);
        assertEq(SwarmCore(created).balanceOf(address(this)), SUPPLY);
    }

    function test_factoryDeploysTokenAndProjectInOneCallAndKeepsWholeSupply() public {
        LaunchFactoryFixture factory = new LaunchFactoryFixture();
        uint64 launchNumber = 42;
        bytes32 tokenSalt = bytes32(uint256(launchNumber));
        address predictedToken = factory.predict(type(SwarmCore).creationCode, tokenSalt);

        bytes[] memory codes = new bytes[](2);
        bytes32[] memory salts = new bytes32[](2);
        codes[0] = type(SwarmCore).creationCode;
        salts[0] = tokenSalt;
        codes[1] = abi.encodePacked(type(ReaderProjectFixture).creationCode, abi.encode(predictedToken));
        salts[1] = keccak256("project 0");

        address origin = makeAddr("tx origin");
        vm.prank(address(this), origin);
        address[] memory deployed = factory.deployAll(codes, salts, SUPPLY);

        assertEq(deployed[0], predictedToken, "token address prediction");
        SwarmCore launched = SwarmCore(deployed[0]);
        assertEq(launched.name(), "SwarmCore");
        assertEq(launched.symbol(), "SWARMCOR");
        assertEq(launched.decimals(), 18);
        assertEq(launched.totalSupply(), SUPPLY);
        assertEq(launched.balanceOf(address(factory)), SUPPLY, "the factory holds the whole supply");
        assertEq(launched.balanceOf(address(this)), 0, "the factory's caller got nothing");
        assertEq(launched.balanceOf(origin), 0, "the transaction origin got nothing");
        assertEq(launched.balanceOf(deployed[1]), 0, "the project got nothing");

        ReaderProjectFixture project = ReaderProjectFixture(deployed[1]);
        assertEq(address(project.token()), deployed[0]);
        assertEq(project.supplySeen(), SUPPLY, "a later constructor reads the minted supply");
        assertEq(project.factoryBalanceSeen(), SUPPLY, "a later constructor sees the factory funded");
        assertTrue(project.pullFailed(), "a project constructor must not be able to pull supply");
        assertLe(deployed[0].code.length, 24_576);
        assertLe(deployed[1].code.length, 24_576);
    }

    function test_sameSaltCannotRedeployTheToken() public {
        LaunchFactoryFixture factory = new LaunchFactoryFixture();
        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(SwarmCore).creationCode;
        salts[0] = bytes32(uint256(7));
        factory.deployAll(codes, salts, SUPPLY);
        vm.expectRevert(bytes("constructor failed"));
        factory.deployAll(codes, salts, SUPPLY);
    }

    function test_launchFlowsMoveExactlyWhatTheySay() public {
        LaunchFactoryFixture factory = new LaunchFactoryFixture();
        bytes[] memory codes = new bytes[](1);
        bytes32[] memory salts = new bytes32[](1);
        codes[0] = type(SwarmCore).creationCode;
        salts[0] = bytes32(uint256(1));
        SwarmCore launched = SwarmCore(factory.deployAll(codes, salts, SUPPLY)[0]);

        address distributor = makeAddr("distributor");
        address claimant = makeAddr("claimant");
        address poolManager = makeAddr("pool manager");
        address remainderTo = makeAddr("remainder recipient");
        uint256 swarm = SUPPLY * SWARM_BPS / 10_000;
        uint256 pool = SUPPLY * 8_800 / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.move(launched, distributor, swarm));
        assertEq(launched.balanceOf(distributor), swarm, "the swarm's share arrived short");
        assertTrue(factory.move(launched, poolManager, pool));
        assertEq(launched.balanceOf(poolManager), pool, "the seed arrived short");
        assertTrue(factory.move(launched, remainderTo, remainder));
        assertEq(launched.balanceOf(remainderTo), remainder, "the remainder arrived short");
        assertEq(launched.balanceOf(address(factory)), 0, "the factory kept something back");

        // Every claim leaves the distributor whole; the last claimant is not shorted.
        uint256 perClaim = swarm / 3;
        vm.startPrank(distributor);
        assertTrue(launched.transfer(claimant, perClaim));
        assertTrue(launched.transfer(claimant, perClaim));
        assertTrue(launched.transfer(claimant, swarm - 2 * perClaim));
        vm.stopPrank();
        assertEq(launched.balanceOf(claimant), swarm);
        assertEq(launched.balanceOf(distributor), 0);

        // The factory cannot pull anything back once the launch is distributed.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        vm.prank(address(factory));
        launched.transferFrom(claimant, address(factory), 1);
        assertEq(launched.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Privileged hands: the protected harness's lists, from a stranger and from the factory.
    // ---------------------------------------------------------------------------------------------

    function test_noCommonAdminCallIncreasesSupplyFromStrangerOrDeployer() public {
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
            // address(this) is the deployer, the address a token would most plausibly trust.
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
        }
    }

    function test_noPrivilegedHandMovesOrFreezesAHolder() public {
        token.transfer(holder, SUPPLY / 1_000);
        uint256 held = token.balanceOf(holder);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], holder, true);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(attacker);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        (bool moved,) =
            address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, holder, address(this), 1));
        assertFalse(moved, "the deployer pulled from a holder without approval");
        assertEq(token.balanceOf(holder), held, "a privileged call moved the holder's balance");
        vm.prank(holder);
        assertTrue(token.transfer(recipient, held / 2), "the holder can no longer transfer");
        assertEq(token.balanceOf(recipient), held / 2);
        assertEq(token.balanceOf(holder), held - held / 2);
    }

    function test_noAllowanceHelpersPermitOrOwnerEntrypoints() public {
        bytes[8] memory calls = [
            abi.encodeWithSignature("increaseAllowance(address,uint256)", spender, 1),
            abi.encodeWithSignature("decreaseAllowance(address,uint256)", spender, 1),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("paused()"),
            abi.encodeWithSignature("nonces(address)", holder),
            abi.encodeWithSignature("DOMAIN_SEPARATOR()"),
            abi.encodeWithSignature("renounceOwnership()"),
            abi.encodeWithSignature("burn(address,uint256)", holder, 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "unexpected entrypoint answered");
        }
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_runtimeMakesNoExternalCallsAndCreatesNothing() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf0 && op != 0xf5, "CREATE in runtime");
            assertTrue(op != 0xf1 && op != 0xf2 && op != 0xf4 && op != 0xfa, "external call in runtime");
            assertTrue(op != 0xff, "SELFDESTRUCT in runtime");
        }
    }

    function test_standardInterfaceIsFullyAnswered() public view {
        assertEq(IERC20Metadata(address(token)).name(), "SwarmCore");
        assertEq(IERC20Metadata(address(token)).symbol(), "SWARMCOR");
        assertEq(IERC20Metadata(address(token)).decimals(), 18);
        assertEq(IERC20(address(token)).totalSupply(), SUPPLY);
        assertEq(IERC20(address(token)).balanceOf(address(this)), SUPPLY);
        assertEq(IERC20(address(token)).allowance(address(this), spender), 0);
        bytes4[9] memory selectors = [
            IERC20Metadata.name.selector,
            IERC20Metadata.symbol.selector,
            IERC20Metadata.decimals.selector,
            IERC20.totalSupply.selector,
            IERC20.balanceOf.selector,
            IERC20.allowance.selector,
            IERC20.transfer.selector,
            IERC20.approve.selector,
            IERC20.transferFrom.selector
        ];
        bytes32[9] memory expected = [
            bytes32(bytes4(keccak256("name()"))),
            bytes32(bytes4(keccak256("symbol()"))),
            bytes32(bytes4(keccak256("decimals()"))),
            bytes32(bytes4(keccak256("totalSupply()"))),
            bytes32(bytes4(keccak256("balanceOf(address)"))),
            bytes32(bytes4(keccak256("allowance(address,address)"))),
            bytes32(bytes4(keccak256("transfer(address,uint256)"))),
            bytes32(bytes4(keccak256("approve(address,uint256)"))),
            bytes32(bytes4(keccak256("transferFrom(address,address,uint256)")))
        ];
        for (uint256 i; i < selectors.length; ++i) {
            assertEq(bytes32(selectors[i]), expected[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Arbitrary callers and arbitrary calldata.
    // ---------------------------------------------------------------------------------------------

    /// @dev Whatever an unfunded stranger sends, with any selector and any arguments, nothing it
    /// does not own moves: the supply, every funded balance and every allowance it was not granted.
    function testFuzz_strangerWithArbitraryCalldataChangesNothingItDoesNotOwn(bytes4 selector, bytes memory args)
        public
    {
        token.transfer(holder, 1_000 ether);
        vm.prank(holder);
        token.approve(spender, 500 ether);

        vm.prank(attacker);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        ok;

        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
        assertEq(token.balanceOf(holder), 1_000 ether);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(holder, spender), 500 ether);
        assertEq(token.allowance(holder, attacker), 0);
        assertEq(token.allowance(address(this), attacker), 0);
    }

    /// @dev The standard entrypoints with arbitrary arguments from an unfunded stranger: the only
    /// ones that succeed are the zero-amount ones and the stranger's own approvals.
    function testFuzz_strangerStandardCallsOnlySucceedWhenHarmless(uint8 which, address a, address b, uint256 amount)
        public
    {
        token.transfer(holder, 1_000 ether);
        which = uint8(bound(which, 0, 2));
        bytes memory data = which == 0
            ? abi.encodeWithSelector(IERC20.transfer.selector, a, amount)
            : which == 1
                ? abi.encodeWithSelector(IERC20.approve.selector, a, amount)
                : abi.encodeWithSelector(IERC20.transferFrom.selector, a, b, amount);
        vm.prank(attacker);
        (bool ok,) = address(token).call(data);
        if (which == 0) {
            assertEq(ok, a != address(0) && amount == 0, "transfer outcome");
        } else if (which == 1) {
            assertEq(ok, a != address(0), "approve outcome");
            if (ok) assertEq(token.allowance(attacker, a), amount);
        } else {
            // Zero-amount pulls need no allowance, but neither end may be the zero address.
            assertEq(ok, a != address(0) && b != address(0) && amount == 0, "transferFrom outcome");
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(holder), 1_000 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1_000 ether);
        assertEq(token.balanceOf(attacker), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Algebra over fuzzed amounts: round trips, splits, overwrites, ordering of checks.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferRoundTripRestoresBothBalances(address other, uint256 amount) public {
        other = address(uint160(bound(uint160(other), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 mineBefore = token.balanceOf(address(this));
        uint256 theirsBefore = token.balanceOf(other);
        assertTrue(token.transfer(other, amount));
        vm.prank(other);
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), mineBefore);
        assertEq(token.balanceOf(other), theirsBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitTransferEqualsSingleTransfer(uint256 first, uint256 second) public {
        first = bound(first, 0, SUPPLY);
        second = bound(second, 0, SUPPLY - first);
        SwarmCore other = new SwarmCore();
        assertTrue(token.transfer(holder, first));
        assertTrue(token.transfer(holder, second));
        assertTrue(other.transfer(holder, first + second));
        assertEq(token.balanceOf(holder), other.balanceOf(holder));
        assertEq(token.balanceOf(address(this)), other.balanceOf(address(this)));
        assertEq(token.balanceOf(holder) + token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferToArbitraryRecipientNeverCallsBackOrFails(address to, uint256 amount) public {
        to = address(uint160(bound(uint160(to), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        uint256 before = token.balanceOf(to);
        vm.recordLogs();
        assertTrue(token.transfer(to, amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event per transfer");
        assertEq(logs[0].emitter, address(token));
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
        if (to == address(this)) {
            assertEq(token.balanceOf(to), before);
        } else {
            assertEq(token.balanceOf(to), before + amount);
            assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        }
        assertLe(token.balanceOf(to), SUPPLY);
    }

    function testFuzz_approveOverwritesRatherThanAccumulates(uint256 first, uint256 second) public {
        assertTrue(token.approve(spender, first));
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(address(this), spender), second);
        assertEq(token.allowance(spender, address(this)), 0, "approval is directional");
    }

    function testFuzz_approvalFromUnfundedOwnerIsRecordedButUnspendable(address owner, uint256 amount) public {
        owner = address(uint160(bound(uint160(owner), 1, type(uint160).max)));
        if (owner == address(this)) owner = holder;
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        assertEq(token.allowance(owner, spender), amount);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, 0, 1));
        vm.prank(spender);
        token.transferFrom(owner, recipient, 1);
        assertEq(token.allowance(owner, spender), amount, "a failed pull must not consume allowance");
    }

    function testFuzz_allowanceIsCheckedBeforeBalance(uint256 balance, uint256 allowed, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        token.transfer(holder, balance);
        vm.prank(holder);
        token.approve(spender, allowed);
        bool shouldSucceed = amount <= allowed && amount <= balance;
        if (amount > allowed) {
            // The allowance is checked first, even when the balance would also be short.
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        } else if (amount > balance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, amount)
            );
        }
        vm.prank(spender);
        bool ok = token.transferFrom(holder, recipient, amount);
        if (shouldSucceed) {
            assertTrue(ok);
            assertEq(token.balanceOf(recipient), amount);
            assertEq(token.balanceOf(holder), balance - amount);
            assertEq(token.allowance(holder, spender), allowed - amount);
        } else {
            assertEq(token.balanceOf(recipient), 0);
            assertEq(token.balanceOf(holder), balance);
            assertEq(token.allowance(holder, spender), allowed);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_spendingAllowanceEmitsTransferOnly(uint256 allowed, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        allowed = bound(allowed, amount, type(uint256).max);
        token.approve(spender, allowed);
        vm.recordLogs();
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "this implementation emits no Approval on spend");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(address(this)))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(recipient))));
        assertEq(abi.decode(logs[0].data, (uint256)), amount);
    }

    function testFuzz_manyRecipientsNeverExceedSupply(uint8 count, uint256 seed) public {
        count = uint8(bound(count, 1, 32));
        uint256 remaining = SUPPLY;
        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            address to = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            uint256 amount = uint256(keccak256(abi.encode(seed, i, "amount"))) % (remaining + 1);
            assertTrue(token.transfer(to, amount));
            if (to != address(this)) {
                remaining -= amount;
                distributed += amount;
            }
            assertLe(token.balanceOf(to), SUPPLY);
        }
        assertEq(token.balanceOf(address(this)), SUPPLY - distributed);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumAmountsRevertWithoutOverflow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        token.transfer(holder, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, SUPPLY + 1)
        );
        token.transfer(holder, SUPPLY + 1);
        token.approve(spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(spender);
        token.transferFrom(address(this), holder, type(uint256).max);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_tokensSentToTheContractItselfAreStrandedNotRecoverable() public {
        assertTrue(token.transfer(address(token), 5 ether));
        assertEq(token.balanceOf(address(token)), 5 ether);
        (bool ok,) = address(token).call(abi.encodeWithSignature("recover(address,uint256)", address(this), 5 ether));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("sweep(address)", address(this)));
        assertFalse(ok);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(address(token), address(this), 1);
        assertEq(token.balanceOf(address(token)), 5 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
