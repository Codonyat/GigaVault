// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, ReentrancyAttacker} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultSecurityTest is GigaVaultTestBase {
    // ============ Timing Tests (2) ============

    function testTimestampManipulationResistance() public {
        mintVault(alice, 10 ether);

        // Fast forward to just before day 2
        vm.warp(block.timestamp + 50 hours - 1);

        uint256 day = vault.getCurrentDay();
        assertEq(day, 1, "Should still be day 1");

        // Fast forward 2 seconds
        vm.warp(block.timestamp + 2);

        day = vault.getCurrentDay();
        assertEq(day, 2, "Should be day 2");
    }

    function testPreventDoubleLotteryExecution() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        // Move past minting period
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // Generate fees
        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        // Fast forward to next day
        vm.warp(block.timestamp + 25 hours + 61);

        // Execute lottery once
        vault.executeLottery();

        // Try to execute again — should revert
        vm.expectRevert("No pending lottery/auction (same day)");
        vault.executeLottery();
    }

    // ============ Ownership Tests (2) ============

    function testRenounceOwnershipReverts() public {
        vm.expectRevert("Cannot renounce ownership");
        vault.renounceOwnership();
    }

    function testOwnerTransfer() public {
        address initialOwner = vault.owner();
        assertEq(initialOwner, address(this), "Initial owner should be deployer");

        // Step 1: Transfer ownership to bob
        vault.transferOwnership(bob);
        assertEq(vault.owner(), address(this), "Owner should not change until accepted");

        // Step 2: Bob accepts ownership
        vm.prank(bob);
        vault.acceptOwnership();
        assertEq(vault.owner(), bob, "Owner should now be bob");
    }

    // ============ Stress Tests (1) ============

    function testFenwickTreeConsistencyUnderStress() public {
        address[] memory users = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            users[i] = address(uint160(0x1000 + i));
            usdmy.mint(users[i], 10 ether);
        }

        for (uint256 i = 0; i < 20; i++) {
            mintVault(users[i], 1 ether);
        }

        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // Random transfers to generate fees
        for (uint256 i = 0; i < 50; i++) {
            uint256 from = i % 20;
            uint256 to = (i + 7) % 20;
            uint256 amount = 0.1 ether * ((i % 5) + 1);

            if (vault.balanceOf(users[from]) >= amount) {
                vm.prank(users[from]);
                vault.transfer(users[to], amount);
            }
        }

        // System should still be consistent
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery(); // Should not revert
    }

    // ============ Reentrancy Tests (1) ============

    function testReentrancyGuardWorks() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(vault, usdmy);
        usdmy.mint(address(attacker), 10 ether);

        // Attacker tries to reenter during mint
        vm.prank(address(attacker));
        attacker.attack(2 ether);

        // Check that only one mint succeeded
        uint256 attackerBalance = vault.balanceOf(address(attacker));
        assertEq(attackerBalance, 1.98 ether); // Only one mint: 2 USDmY * 0.99 (after 1% fee)
    }
}
