// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultFenwickTest is GigaVaultTestBase {
    function testFenwickDebug() public {
        // Set up same scenario as probability test
        mintVault(alice, 1 ether);
        mintVault(bob, 1 ether);
        mintVault(charlie, 1 ether);

        // Take snapshot
        MockContract trigger = new MockContract(usdmy);
        usdmy.mint(address(trigger), 1 ether);
        trigger.mintVault(vault, 1 ether);

        // Check what indices point to what
        console.log("Holder indices:");
        for (uint256 i = 1; i <= vault.getHolderCount(); i++) {
            (address holder, uint256 balance) = vault.getHolderByIndex(i);
            console.log("Index:", i);
            console.log("Holder:", holder);
            console.log("Balance:", balance);
        }

        // Check cumulative sums
        console.log("\nCumulative sums:");
        for (uint256 i = 1; i <= vault.getHolderCount(); i++) {
            uint256 cumSum = vault.getSuffixSum(i);
            console.log("Cumulative at index", i, ":", cumSum);
        }

        // Test winner selection with different random values
        uint256 totalSupply = vault.getSuffixSum(vault.getHolderCount());
        console.log("\nTotal supply from Fenwick:", totalSupply);

        // Test different random positions
        uint256[] memory testPositions = new uint256[](5);
        testPositions[0] = 0;
        testPositions[1] = totalSupply / 4;
        testPositions[2] = totalSupply / 2;
        testPositions[3] = (totalSupply * 3) / 4;
        testPositions[4] = totalSupply - 1;

        for (uint256 i = 0; i < testPositions.length; i++) {
            uint256 position = testPositions[i];
            console.log("\nTesting position:", position);

            // Binary search to find winner
            uint256 winnerIndex = findWinnerIndex(position);
            (address winner, ) = vault.getHolderByIndex(winnerIndex);
            console.log("Winner index:", winnerIndex);
            console.log("Winner address:", winner);
        }
    }

    function testFenwickTreeCumulativeSums() public {
        // Add holders with known balances
        mintVault(alice, 1 ether); // 0.99 tokens
        mintVault(bob, 2 ether); // 1.98 tokens
        mintVault(charlie, 3 ether); // 2.97 tokens

        // getSuffixSum returns cumulative sum from index to end
        // So getSuffixSum(1) returns total of all holders
        uint256 cumSum1 = vault.getSuffixSum(1);
        uint256 cumSum2 = vault.getSuffixSum(2);
        uint256 cumSum3 = vault.getSuffixSum(3);

        // Total should be 0.99 + 1.98 + 2.97 = 5.94
        assertEq(
            cumSum1,
            5.94 ether,
            "Suffix sum from index 1 should be total (5.94)"
        );
        assertEq(
            cumSum2,
            1.98 ether + 2.97 ether,
            "Suffix sum from index 2 should be 4.95"
        );
        assertEq(cumSum3, 2.97 ether, "Suffix sum from index 3 should be 2.97");
    }

    function testFenwickTreeConsistencyAfterOperations() public {
        // Initial setup
        mintVault(alice, 5 ether);
        mintVault(bob, 3 ether);

        // Perform various operations
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.prank(bob);
        vault.transfer(charlie, 0.5 ether);

        // Add new holder
        mintVault(david, 2 ether);

        // Check consistency - getSuffixSum(1) gets total from beginning
        uint256 totalFromFenwick = vault.getSuffixSum(1);

        // Calculate expected total (accounting for fees)
        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 bobBalance = vault.balanceOf(bob);
        uint256 charlieBalance = vault.balanceOf(charlie);
        uint256 davidBalance = vault.balanceOf(david);

        uint256 expectedHolderTotal = aliceBalance +
            bobBalance +
            charlieBalance +
            davidBalance;

        assertEq(
            totalFromFenwick,
            expectedHolderTotal,
            "Fenwick total should match sum of holder balances"
        );
    }

    function testHolderTracking() public {
        // Initially no holders
        assertEq(vault.getHolderCount(), 0);

        // Alice becomes a holder
        mintVault(alice, 1 ether);
        assertEq(vault.getHolderCount(), 1);
        assertTrue(vault.isHolder(alice));

        // Bob becomes a holder
        mintVault(bob, 1 ether);
        assertEq(vault.getHolderCount(), 2);
        assertTrue(vault.isHolder(bob));

        // Alice transfers all to Bob (Alice should be removed as holder)
        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, aliceBalance);

        // Alice should no longer be a holder
        assertFalse(vault.isHolder(alice));
        // Holder count depends on whether alice was removed or not
        // In the implementation, holders are not removed when balance goes to 0
        // They're just tracked with 0 balance
        assertTrue(vault.isHolder(bob));
    }

    function testPackedStorageOptimization() public {
        // Test that many holders can be efficiently tracked
        uint256 numHolders = 50;

        for (uint256 i = 0; i < numHolders; i++) {
            address holder = address(uint160(0x1000 + i));
            usdmy.mint(holder, 1 ether);
            vm.startPrank(holder);
            usdmy.approve(address(vault), 0.1 ether);
            vault.mint(0.1 ether);
            vm.stopPrank();
        }

        assertEq(vault.getHolderCount(), numHolders);

        // Verify all holders are tracked correctly
        for (uint256 i = 1; i <= numHolders; i++) {
            (address holder, uint256 balance) = vault.getHolderByIndex(i);
            assertEq(holder, address(uint160(0x1000 + i - 1)));
            assertEq(balance, 0.099 ether); // 0.1 USDmY * 0.99 (after 1% fee)
        }
    }

    // Helper function for binary search
    function findWinnerIndex(uint256 position) internal view returns (uint256) {
        uint256 left = 1;
        uint256 right = vault.getHolderCount();

        while (left < right) {
            uint256 mid = (left + right) / 2;
            uint256 cumSum = vault.getSuffixSum(mid);

            if (cumSum <= position) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        return left;
    }
}
