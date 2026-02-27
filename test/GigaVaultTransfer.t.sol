// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultTransferTest is GigaVaultTestBase {
    // ============ Core Transfer Tests (3) ============

    function testTransferWithFee() public {
        mintVault(alice, 10 ether);

        uint256 aliceInitial = vault.balanceOf(alice);
        assertEq(aliceInitial, 9.9 ether, "Alice should have 9.9 vault tokens after minting");
        assertEq(vault.balanceOf(vault.FEES_POOL()), 0.1 ether, "Fees pool should have 0.1 vault tokens from mint");

        uint256 transferAmount = 1 ether;
        uint256 expectedFee = 0.01 ether;
        uint256 expectedReceived = transferAmount - expectedFee;

        vm.prank(alice);
        bool success = vault.transfer(bob, transferAmount);
        assertTrue(success, "Transfer should succeed");

        assertEq(vault.balanceOf(alice), aliceInitial - transferAmount, "Alice balance should decrease by transfer amount");
        assertEq(vault.balanceOf(bob), expectedReceived, "Bob should receive amount minus fee");
        assertEq(vault.balanceOf(vault.FEES_POOL()), 0.1 ether + expectedFee, "Fees pool should increase by transfer fee");
    }

    function testLOT_POOLTransfersRedirectedToFEES_POOL() public {
        usdmy.mint(address(this), 10 ether);
        usdmy.approve(address(vault), 10 ether);
        vault.mint(10 ether);

        uint256 testContractBalance = vault.balanceOf(address(this));
        assertEq(testContractBalance, 9.9 ether, "Test contract should have 9.9 tokens");

        uint256 feesPoolBefore = vault.balanceOf(vault.FEES_POOL());
        uint256 lotPoolBefore = vault.balanceOf(vault.LOT_POOL());

        vault.transfer(vault.LOT_POOL(), 0.1 ether);

        uint256 feesPoolAfter = vault.balanceOf(vault.FEES_POOL());
        uint256 lotPoolAfter = vault.balanceOf(vault.LOT_POOL());

        assertEq(lotPoolAfter, lotPoolBefore, "LOT_POOL balance should not change");
        assertEq(feesPoolAfter, feesPoolBefore + 0.1 ether, "FEES_POOL should receive 0.1 tokens (redirected from LOT_POOL)");
    }

    function testTransferZeroAmount() public {
        mintVault(alice, 1 ether);

        vm.prank(alice);
        bool success = vault.transfer(bob, 0);
        assertTrue(success, "Zero transfer should succeed");

        assertEq(vault.balanceOf(alice), 0.99 ether);
    }

    // ============ Internal LOT_POOL Transfer (1, with fixed assertion) ============

    function testInternalLOT_POOLTransfersStillWork() public {
        setupBasicHolders();

        skipPastMintingPeriod();

        // Generate fees
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Execute lottery — internally transfers fees from FEES_POOL to LOT_POOL
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123456)));
        vault.executeLottery();

        // LOT_POOL should hold prizes after internal transfers completed successfully
        uint256 lotPoolAfter = vault.balanceOf(vault.LOT_POOL());
        assertGt(lotPoolAfter, 0, "LOT_POOL should hold prize tokens after lottery/auction");

        // Verify a winner was selected or auction was started (internal transfer worked)
        uint256 currentDay = vault.getCurrentDay();
        (address winner,) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);
        (, , , uint112 auctionAmount,) = vault.currentAuction();
        assertTrue(winner != address(0) || auctionAmount > 0, "Should have lottery winner or auction");
    }

    // ============ SelfTransfer Tests (4) ============

    function testSelfTransferFenwickConsistency() public {
        mintVault(alice, 10 ether);

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 fenwickBefore = vault.getSuffixSum(1);

        vm.prank(alice);
        vault.transfer(alice, 100 ether);

        uint256 aliceBalanceAfter = vault.balanceOf(alice);
        uint256 fenwickAfter = vault.getSuffixSum(1);

        // Alice should lose 1% fee even on self-transfer
        assertEq(aliceBalanceAfter, aliceBalanceBefore - 1 ether, "Should charge fee on self-transfer");

        // Fenwick should still be consistent
        assertEq(fenwickAfter, aliceBalanceAfter, "Fenwick should match Alice's balance");
    }

    function testSelfTransferWithMultipleHolders() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        uint256 totalBefore = vault.balanceOf(alice) + vault.balanceOf(bob);
        uint256 fenwickBefore = vault.getSuffixSum(1);
        assertEq(fenwickBefore, totalBefore, "Initial Fenwick should match total");

        vm.prank(alice);
        vault.transfer(alice, 500 ether);

        uint256 totalAfter = vault.balanceOf(alice) + vault.balanceOf(bob);
        uint256 fenwickAfter = vault.getSuffixSum(1);

        assertEq(totalBefore - totalAfter, 5 ether, "Total should decrease by fee");

        assertEq(fenwickAfter, totalAfter, "Fenwick should match new total");
    }

    function testRapidSelfTransfers() public {
        mintVault(alice, 10 ether);

        uint256 expectedBalance = 9.9 ether;

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            vault.transfer(alice, 0.9 ether);
            expectedBalance -= 0.009 ether;

            uint256 fenwick = vault.getSuffixSum(1);
            uint256 aliceBalance = vault.balanceOf(alice);
            assertEq(fenwick, aliceBalance, "Fenwick should match balance");
            assertEq(aliceBalance, expectedBalance, "Balance should match expected");
        }
    }

    function testSyntheticAddressesNotInFenwick() public {
        mintVault(alice, 10 ether);

        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 feesBalance = vault.balanceOf(vault.FEES_POOL());

        assertEq(aliceBalance, 9.9 ether, "Alice should have 9.9");
        assertEq(feesBalance, 0.1 ether, "FEES_POOL should have 0.1");

        uint256 fenwick = vault.getSuffixSum(1);
        assertEq(fenwick, aliceBalance, "Fenwick should only track Alice");

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        uint256 totalHolderBalance = vault.balanceOf(alice) + vault.balanceOf(bob);
        uint256 fenwickAfter = vault.getSuffixSum(1);
        assertEq(fenwickAfter, totalHolderBalance, "Fenwick should only track real holders");

        uint256 newFeesBalance = vault.balanceOf(vault.FEES_POOL());
        assertGt(newFeesBalance, feesBalance, "FEES_POOL should have more fees");
    }

    // ============ New Test (1) ============

    function testTransferToVaultAddressRedirectedToFeesPool() public {
        mintVault(alice, 10 ether);

        uint256 feesPoolBefore = vault.balanceOf(vault.FEES_POOL());
        uint256 aliceBefore = vault.balanceOf(alice);

        // Transfer to address(vault) — should be redirected to FEES_POOL
        vm.prank(alice);
        vault.transfer(address(vault), 1 ether);

        uint256 feesPoolAfter = vault.balanceOf(vault.FEES_POOL());
        uint256 aliceAfter = vault.balanceOf(alice);

        // Alice loses 1 ether
        assertEq(aliceBefore - aliceAfter, 1 ether, "Alice should lose 1 ether");
        // FEES_POOL should receive 1 ether (no fee on redirect, it goes directly to FEES_POOL)
        assertEq(feesPoolAfter - feesPoolBefore, 1 ether, "FEES_POOL should receive the full 1 ether (redirect, no fee)");
        // Vault address itself should have 0 balance (redirected)
        assertEq(vault.balanceOf(address(vault)), 0, "Vault address should have 0 balance");
    }
}
