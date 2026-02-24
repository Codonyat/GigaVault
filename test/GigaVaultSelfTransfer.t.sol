// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GigaVault} from "../src/GigaVault.sol";

// Mock ERC20 USDmY for testing
contract MockUSDmY {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(
            allowance[from][msg.sender] >= amount,
            "Insufficient allowance"
        );

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }
}

contract GigaVaultSelfTransferTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        usdmy = new MockUSDmY();
        vault = new GigaVault(address(usdmy));

        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
    }

    // Helper to mint vault tokens
    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    function testSelfTransferFenwickConsistency() public {
        // Alice mints tokens
        mintVault(alice, 10 ether);

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 fenwickBefore = vault.getSuffixSum(1);

        console.log("Alice balance before self-transfer:", aliceBalanceBefore);
        console.log("Fenwick sum before self-transfer:", fenwickBefore);

        // Alice transfers to herself
        vm.prank(alice);
        vault.transfer(alice, 100 ether);

        uint256 aliceBalanceAfter = vault.balanceOf(alice);
        uint256 fenwickAfter = vault.getSuffixSum(1);

        console.log("Alice balance after self-transfer:", aliceBalanceAfter);
        console.log("Fenwick sum after self-transfer:", fenwickAfter);

        // Alice should lose 1% fee even on self-transfer
        assertEq(
            aliceBalanceAfter,
            aliceBalanceBefore - 1 ether,
            "Should charge fee on self-transfer"
        );

        // Fenwick should still be consistent
        assertEq(
            fenwickAfter,
            aliceBalanceAfter,
            "Fenwick should match Alice's balance"
        );
    }

    function testSelfTransferWithMultipleHolders() public {
        // Multiple users mint
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        uint256 totalBefore = vault.balanceOf(alice) + vault.balanceOf(bob);
        uint256 fenwickBefore = vault.getSuffixSum(1);
        assertEq(
            fenwickBefore,
            totalBefore,
            "Initial Fenwick should match total"
        );

        // Alice self-transfers
        vm.prank(alice);
        vault.transfer(alice, 500 ether);

        uint256 totalAfter = vault.balanceOf(alice) + vault.balanceOf(bob);
        uint256 fenwickAfter = vault.getSuffixSum(1);

        // Total should decrease by fee amount
        assertEq(
            totalBefore - totalAfter,
            5 ether,
            "Total should decrease by fee"
        );

        // Fenwick should still track correctly
        assertEq(fenwickAfter, totalAfter, "Fenwick should match new total");
    }

    function testRapidSelfTransfers() public {
        mintVault(alice, 10 ether);

        uint256 expectedBalance = 9.9 ether;

        // Do 10 self-transfers rapidly
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            vault.transfer(alice, 0.9 ether);
            expectedBalance -= 0.009 ether; // 1% fee each time

            // Check Fenwick consistency after each transfer
            uint256 fenwick = vault.getSuffixSum(1);
            uint256 aliceBalance = vault.balanceOf(alice);
            assertEq(fenwick, aliceBalance, "Fenwick should match balance");
            assertEq(
                aliceBalance,
                expectedBalance,
                "Balance should match expected"
            );
        }
    }

    function testSyntheticAddressesNotInFenwick() public {
        // Verify that FEES_POOL and LOT_POOL are never tracked in Fenwick tree
        mintVault(alice, 10 ether);

        // After minting, alice has 9900, FEES_POOL has 100
        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 feesBalance = vault.balanceOf(vault.FEES_POOL());

        assertEq(aliceBalance, 9.9 ether, "Alice should have 9.9");
        assertEq(feesBalance, 0.1 ether, "FEES_POOL should have 0.1");

        // Fenwick should only track Alice, not FEES_POOL
        uint256 fenwick = vault.getSuffixSum(1);
        assertEq(fenwick, aliceBalance, "Fenwick should only track Alice");

        // Do a transfer to generate more fees
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Check that Fenwick still only tracks real holders
        uint256 totalHolderBalance = vault.balanceOf(alice) +
            vault.balanceOf(bob);
        uint256 fenwickAfter = vault.getSuffixSum(1);
        assertEq(
            fenwickAfter,
            totalHolderBalance,
            "Fenwick should only track real holders"
        );

        // Verify fees went to FEES_POOL but aren't in Fenwick
        uint256 newFeesBalance = vault.balanceOf(vault.FEES_POOL());
        assertGt(
            newFeesBalance,
            feesBalance,
            "FEES_POOL should have more fees"
        );
    }
}
