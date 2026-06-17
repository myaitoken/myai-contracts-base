// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {MyAIToken} from "../../contracts/MyAIToken.sol";

/// @notice Unit + branch coverage for MyAIToken (OZ ERC20 + ERC20Burnable,
/// fixed supply). Covers metadata, initial mint, transfers, allowance/
/// transferFrom, burn/burnFrom, and the standard revert branches.
contract MyAITokenUnitTest is Test {
    MyAIToken public token;
    address deployer;            // = address(this)
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    uint256 constant SUPPLY = 1_000_000_000 ether; // 1e9 * 1e18

    function setUp() public {
        deployer = address(this);
        token = new MyAIToken();
    }

    // ─── Metadata + initial state ──────────────────────────────────────────
    function test_metadata() public view {
        assertEq(token.name(), "MyAI");
        assertEq(token.symbol(), "MYAI");
        assertEq(token.decimals(), 18);
    }

    function test_initialSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    // ─── Transfers ─────────────────────────────────────────────────────────
    function test_transfer() public {
        token.transfer(alice, 1_000 ether);
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
    }

    function test_transfer_revertsInsufficientBalance() public {
        vm.prank(alice); // alice has 0
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", alice, 0, 1
            )
        );
        token.transfer(bob, 1);
    }

    function test_transfer_revertsToZero() public {
        vm.expectRevert(
            abi.encodeWithSignature("ERC20InvalidReceiver(address)", address(0))
        );
        token.transfer(address(0), 1 ether);
    }

    function testFuzz_transfer(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
    }

    // ─── Allowance + transferFrom ──────────────────────────────────────────
    function test_approveAndTransferFrom() public {
        token.transfer(alice, 500 ether);
        vm.prank(alice);
        token.approve(bob, 200 ether);
        assertEq(token.allowance(alice, bob), 200 ether);

        vm.prank(bob);
        token.transferFrom(alice, bob, 150 ether);
        assertEq(token.balanceOf(bob), 150 ether);
        assertEq(token.allowance(alice, bob), 50 ether); // spent 150
    }

    function test_transferFrom_revertsInsufficientAllowance() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        token.approve(bob, 10 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", bob, 10 ether, 20 ether
            )
        );
        token.transferFrom(alice, bob, 20 ether);
    }

    // ─── Burn / burnFrom (ERC20Burnable) ───────────────────────────────────
    function test_burn() public {
        token.transfer(alice, 1_000 ether);
        vm.prank(alice);
        token.burn(400 ether);
        assertEq(token.balanceOf(alice), 600 ether);
        assertEq(token.totalSupply(), SUPPLY - 400 ether);
    }

    function test_burn_revertsInsufficientBalance() public {
        vm.prank(alice); // 0 balance
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientBalance(address,uint256,uint256)", alice, 0, 1
            )
        );
        token.burn(1);
    }

    function test_burnFrom_spendsAllowance() public {
        token.transfer(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(bob, 300 ether);
        vm.prank(bob);
        token.burnFrom(alice, 250 ether);
        assertEq(token.balanceOf(alice), 750 ether);
        assertEq(token.allowance(alice, bob), 50 ether);
        assertEq(token.totalSupply(), SUPPLY - 250 ether);
    }

    function test_burnFrom_revertsInsufficientAllowance() public {
        token.transfer(alice, 1_000 ether);
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", bob, 100 ether, 200 ether
            )
        );
        token.burnFrom(alice, 200 ether);
    }

    function testFuzz_burn(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        token.burn(amount);
        assertEq(token.totalSupply(), SUPPLY - amount);
    }
}
