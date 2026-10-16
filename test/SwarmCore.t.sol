// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SwarmCore} from "../src/SwarmCore.sol";

/// @dev Local fixture for deployment and the factory's subsequent ordinary ERC-20 transfers.
contract TokenFactoryFixture {
    function deploy() external returns (SwarmCore) {
        return new SwarmCore();
    }

    function send(SwarmCore token, address to, uint256 amount) external {
        require(token.transfer(to, amount), "transfer failed");
    }
}

contract SwarmCoreTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    SwarmCore internal token;
    address internal holder;
    address internal recipient;
    address internal spender;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        holder = makeAddr("holder");
        recipient = makeAddr("recipient");
        spender = makeAddr("spender");
        token = new SwarmCore();
    }

    function test_metadataAndExactInitialSupply() public view {
        assertEq(token.name(), "SwarmCore");
        assertEq(token.symbol(), "SWARMCOR");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function test_constructorEmitsExactlyOneMint() public {
        vm.recordLogs();
        SwarmCore deployed = new SwarmCore();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(deployed));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(address(this)))));
        assertEq(abi.decode(logs[0].data, (uint256)), SUPPLY);
    }

    function test_factoryReceivesWholeSupplyAndLaunchTransfersArriveWhole() public {
        TokenFactoryFixture factory = new TokenFactoryFixture();
        vm.prank(holder);
        SwarmCore deployed = factory.deploy();
        assertEq(deployed.balanceOf(address(factory)), SUPPLY);
        assertEq(deployed.balanceOf(holder), 0);

        address distributor = makeAddr("distributor fixture");
        address poolManager = makeAddr("pool manager fixture");
        address trader = makeAddr("trader fixture");
        factory.send(deployed, distributor, SUPPLY / 10);
        factory.send(deployed, poolManager, SUPPLY * 88 / 100);
        factory.send(deployed, holder, SUPPLY * 2 / 100);
        assertEq(deployed.balanceOf(address(factory)), 0);
        assertEq(deployed.balanceOf(distributor), SUPPLY / 10);
        assertEq(deployed.balanceOf(poolManager), SUPPLY * 88 / 100);
        assertEq(deployed.balanceOf(holder), SUPPLY * 2 / 100);

        vm.prank(distributor);
        assertTrue(deployed.transfer(recipient, SUPPLY / 10));
        assertEq(deployed.balanceOf(recipient), SUPPLY / 10);
        assertEq(deployed.balanceOf(distributor), 0);

        // Exercise exact token settlement in both directions; this fixture is not a Uniswap integration.
        vm.prank(poolManager);
        assertTrue(deployed.transfer(trader, 123 ether));
        assertEq(deployed.balanceOf(trader), 123 ether);
        vm.prank(trader);
        assertTrue(deployed.transfer(poolManager, 123 ether));
        assertEq(deployed.balanceOf(trader), 0);
        assertEq(deployed.balanceOf(poolManager), SUPPLY * 88 / 100);
        assertEq(deployed.totalSupply(), SUPPLY);
    }

    function test_transferEmitsEventAndMovesExactAmount() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), holder, 123 ether + 1);
        assertTrue(token.transfer(holder, 123 ether + 1));
        assertEq(token.balanceOf(holder), 123 ether + 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 123 ether - 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(token.transfer(holder, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function test_selfTransferPreservesBalance() public {
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, 0));
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_transferToZeroRevertsEvenForZeroAmount() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferAboveBalanceRevertsWithoutStateChange() public {
        token.transfer(holder, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 10, 11));
        vm.prank(holder);
        token.transfer(recipient, 11);
        assertEq(token.balanceOf(holder), 10);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferAboveBalanceStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        vm.prank(holder);
        token.transfer(holder, 1);
    }

    function test_approveEmitsEventOverwritesAndRevokes() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(address(this), spender, 100);
        assertTrue(token.approve(spender, 100));
        assertEq(token.allowance(address(this), spender), 100);
        assertTrue(token.approve(spender, 40));
        assertEq(token.allowance(address(this), spender), 40);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(address(this), spender), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
        assertEq(token.allowance(address(this), address(0)), 0);
    }

    function test_transferFromEmitsEventAndConsumesAllowance() public {
        token.approve(spender, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(address(this), recipient, 40);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 40));
        assertEq(token.balanceOf(address(this)), SUPPLY - 40);
        assertEq(token.balanceOf(recipient), 40);
        assertEq(token.allowance(address(this), spender), 60);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, 60));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(recipient), 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumAllowanceIsNotDecremented() public {
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, SUPPLY));
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(recipient), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_transferFromToSelfConsumesAllowanceButPreservesBalance() public {
        token.approve(spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), address(this), 7));
        assertEq(token.allowance(address(this), spender), 3);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_zeroTransferFromNeedsNoAllowance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(holder, recipient, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, 0));
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_transferFromAboveAllowanceRevertsWithoutStateChange() public {
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10, 11));
        vm.prank(spender);
        token.transferFrom(address(this), recipient, 11);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_transferFromInsufficientBalanceRollsBackAllowance() public {
        vm.prank(holder);
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 10));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 10);
        assertEq(token.allowance(holder, spender), 10);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_transferFromZeroReceiverRollsBackAllowance() public {
        token.approve(spender, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 10);
        assertEq(token.allowance(address(this), spender), 10);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deployerCannotSpendHolderFundsWithoutApproval() public {
        token.transfer(holder, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(holder, address(this), 1);
        assertEq(token.balanceOf(holder), 10);
        vm.prank(holder);
        assertTrue(token.transfer(recipient, 10));
        assertEq(token.balanceOf(recipient), 10);
    }

    function test_allowancesAreIsolatedByOwnerAndSpender() public {
        token.transfer(holder, 100);
        token.approve(spender, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, recipient, 0, 1));
        vm.prank(recipient);
        token.transferFrom(address(this), recipient, 1);
        assertEq(token.allowance(address(this), spender), 100);
    }

    function test_noMintBurnOrAdministrativeEntrypoints() public {
        token.transfer(holder, 100);
        bytes[12] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", recipient, 1),
            abi.encodeWithSignature("mint(uint256)", 1),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("burnFrom(address,uint256)", holder, 1),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", holder),
            abi.encodeWithSignature("freeze(address)", holder),
            abi.encodeWithSignature("seize(address)", holder),
            abi.encodeWithSignature("initialize(address)", recipient),
            abi.encodeWithSignature("transferOwnership(address)", recipient),
            abi.encodeWithSignature("upgradeTo(address)", recipient),
            abi.encodeWithSignature("setMinter(address)", recipient)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool fromDeployer,) = address(token).call(calls[i]);
            assertFalse(fromDeployer);
            vm.prank(holder);
            (bool fromHolder,) = address(token).call(calls[i]);
            assertFalse(fromHolder);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(holder), 100);
        }
        vm.prank(holder);
        assertTrue(token.transfer(recipient, 100));
        assertEq(token.balanceOf(recipient), 100);
    }

    function test_runtimeHasNoForbiddenOpcodesAndFitsSizeLimit() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function test_directEtherPaymentReverts() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(token).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(token).balance, 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 balance, uint256 excess) public {
        balance = bound(balance, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - balance);
        token.transfer(holder, balance);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, balance, balance + excess)
        );
        vm.prank(holder);
        token.transfer(recipient, balance + excess);
        assertEq(token.balanceOf(holder), balance);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_delegatedTransferAccounting(uint256 allowed, uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        allowed = bound(allowed, amount, type(uint256).max);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), recipient, amount));
        assertEq(token.allowance(address(this), spender), allowed == type(uint256).max ? allowed : allowed - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientAllowanceIsAtomic(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, SUPPLY);
        token.approve(spender, allowed);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
        vm.prank(spender);
        token.transferFrom(address(this), recipient, amount);
        assertEq(token.allowance(address(this), spender), allowed);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }
}
