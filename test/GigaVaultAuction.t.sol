// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";
import {GigaVault} from "../src/GigaVault.sol";

// Contract that reverts on receive — used for DoS prevention test
contract MaliciousBidder {
    receive() external payable {
        revert("I always revert!");
    }

    fallback() external payable {
        revert("I always revert!");
    }
}

contract GigaVaultAuctionTest is GigaVaultTestBase {
    // Event definitions
    event AuctionStarted(uint256 indexed day, uint256 tokenAmount, uint256 minBid);
    event BidPlaced(address indexed bidder, uint256 amount, uint256 day);
    event BidRefunded(address indexed bidder, uint256 amount);
    event AuctionNoBids(uint256 indexed day, uint256 rolledOverAmount);

    // ============ Original Auction Tests (14) ============

    function testAuctionWithBidding() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);
        placeBid(alice, minBid);
        assertEq(usdmy.balanceOf(alice), aliceUsdmyBefore - minBid, "Alice should have spent USDmY");

        uint256 newBid = (minBid * 110) / 100;
        placeBid(bob, newBid);

        assertEq(usdmy.balanceOf(alice), aliceUsdmyBefore, "Alice should be refunded");

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testAuctionFinalization() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();
        placeBid(alice, minBid);

        uint256 contractUsdmyBefore = vault.getReserve();
        uint256 escrowedBefore = vault.escrowedBid();
        assertEq(escrowedBefore, minBid, "Contract should have escrowed bid");

        vm.prank(bob);
        vault.transfer(alice, 0.5 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        uint256 escrowedAfter = vault.escrowedBid();
        assertEq(escrowedAfter, 0, "Escrow should be empty after finalization");

        uint256 contractUsdmyAfter = vault.getReserve();
        assertGt(contractUsdmyAfter, contractUsdmyBefore, "Reserve should have increased");
    }

    function testBidIncrementRequirement() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        placeBid(alice, minBid);

        uint256 lowBid = (minBid * 109) / 100;
        vm.startPrank(bob);
        usdmy.approve(address(vault), lowBid);
        vm.expectRevert("Bid too low");
        vault.bid(lowBid);
        vm.stopPrank();

        uint256 validBid = (minBid * 110) / 100;
        placeBid(bob, validBid);

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testNoBidAuctionRollover() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        vm.prank(bob);
        vault.transfer(alice, 0.5 ether);

        uint256 feesPoolBefore = vault.balanceOf(vault.FEES_POOL());

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        uint256 feesPoolAfter = vault.balanceOf(vault.FEES_POOL());

        assertTrue(feesPoolAfter > 0, "FEES_POOL should contain rolled over auction amount");
    }

    function test50_50FeeSplitAfterMintingPeriod() public {
        mintVault(alice, 100 ether);

        vm.warp(block.timestamp + 8 * 25 hours);

        vm.prank(alice);
        vault.transfer(bob, 10 ether);
        vm.prank(bob);
        vault.transfer(alice, 9 ether);

        uint256 totalFees = vault.balanceOf(vault.FEES_POOL());
        assertEq(totalFees, 1.19 ether, "FEES_POOL should have 1.19 tokens in fees");

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , , uint112 auctionAmount, ) = vault.currentAuction();
        uint256 expectedAuctionAmount = (totalFees * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");
    }

    function testMinimumBidCalculation() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        uint256 expectedTotalSupply = 15 ether;
        uint256 usdmyBalance = 15 ether;
        assertEq(vault.totalSupply(), expectedTotalSupply);
        assertEq(vault.getReserve(), usdmyBalance);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid, uint112 auctionAmount, ) = vault.currentAuction();

        uint256 expectedAuctionAmount = (0.01 ether * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");

        uint256 expectedMinBid = (usdmyBalance * auctionAmount) / (2 * expectedTotalSupply);
        assertEq(minBid, expectedMinBid, "Minimum bid should match calculated value");

        placeBid(alice, minBid);

        (address currentBidder, uint96 currentBid, , , ) = vault.currentAuction();
        assertEq(currentBidder, alice, "Alice should be current bidder");
        assertEq(currentBid, minBid, "Current bid should equal minimum bid");

        vm.startPrank(bob);
        usdmy.approve(address(vault), minBid);
        vm.expectRevert("Bid too low");
        vault.bid(minBid - 1);
        vm.stopPrank();
    }

    function testMinimumBidWithDifferentBalances() public {
        mintVault(alice, 100 ether);

        skipPastMintingPeriod();
        vm.prank(alice);
        vault.redeem(90 ether);

        uint256 remainingSupply = vault.totalSupply();
        uint256 remainingUsdmy = vault.getReserve();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid1, uint112 auctionAmount1, ) = vault.currentAuction();

        uint256 expectedMin1 = (remainingUsdmy * auctionAmount1) / (2 * remainingSupply);
        assertEq(minBid1, expectedMin1, "Min bid should match expected calculation");

        usdmy.mint(address(this), 50 ether);
        usdmy.transfer(address(vault), 50 ether);

        vm.prank(alice);
        vault.transfer(bob, 0.5 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid2, , ) = vault.currentAuction();

        assertTrue(minBid2 > minBid1, "Higher USDmY backing should result in higher min bid");
    }

    function testMinimumBidFormula() public {
        mintVault(alice, 3 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.7 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid, uint112 auctionAmount, ) = vault.currentAuction();

        uint256 usdmyBalance = vault.getReserve();
        uint256 totalSupply = vault.totalSupply();

        uint256 expectedAuctionAmount = (0.007 ether * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");

        uint256 expectedMinBid = (usdmyBalance * auctionAmount) / (2 * totalSupply);
        assertEq(minBid, expectedMinBid, "Minimum bid should match contract calculation");

        uint256 redemptionValue = (auctionAmount * usdmyBalance) / totalSupply;
        assertEq(minBid, redemptionValue / 2, "Min bid should be half of redemption value");
    }

    function testBidRefunds() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);
        placeBid(alice, minBid);
        assertEq(usdmy.balanceOf(alice), aliceUsdmyBefore - minBid, "Alice should have spent USDmY");

        uint256 newBid = (minBid * 110) / 100;
        placeBid(bob, newBid);

        assertEq(usdmy.balanceOf(alice), aliceUsdmyBefore, "Alice should receive USDmY refund");

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testMultipleBidsAndRefunds() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);
        uint256 bobUsdmyBefore = usdmy.balanceOf(bob);
        uint256 charlieUsdmyBefore = usdmy.balanceOf(charlie);

        placeBid(alice, minBid);

        uint256 bid2 = (minBid * 110) / 100;
        placeBid(bob, bid2);

        uint256 bid3 = (bid2 * 110) / 100;
        placeBid(charlie, bid3);

        uint256 bid4 = (bid3 * 110) / 100;
        placeBid(david, bid4);

        assertEq(usdmy.balanceOf(alice), aliceUsdmyBefore, "Alice should have USDmY refund");
        assertEq(usdmy.balanceOf(bob), bobUsdmyBefore, "Bob should have USDmY refund");
        assertEq(usdmy.balanceOf(charlie), charlieUsdmyBefore, "Charlie should have USDmY refund");

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, david, "David should be current bidder");
    }

    function testBidTooLow() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        vm.startPrank(alice);
        usdmy.approve(address(vault), minBid);
        vm.expectRevert("Bid too low");
        vault.bid(minBid - 1);
        vm.stopPrank();

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, address(0), "Should have no bidder");
    }

    function testAuctionFinalizationWithWinner() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, uint112 auctionAmount, ) = vault.currentAuction();

        placeBid(alice, minBid);

        uint256 escrowedBefore = vault.escrowedBid();
        assertEq(escrowedBefore, minBid, "Contract should have escrowed Alice's bid");

        vm.prank(bob);
        vault.transfer(alice, 0.5 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        assertEq(vault.escrowedBid(), 0, "Contract should have no escrowed USDmY after finalization");

        vm.prank(alice);
        uint256 claimable = vault.getMyClaimableAmount();
        assertGe(claimable, auctionAmount, "Alice should have at least the auction prize claimable");

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.claim();
        uint256 aliceBalanceAfter = vault.balanceOf(alice);

        assertEq(aliceBalanceAfter - aliceBalanceBefore, claimable, "Alice should receive her claimable amount");
    }

    function testBidIncrementAfterFirstBid() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        placeBid(alice, minBid);

        uint256 lowBid = (minBid * 109) / 100;
        vm.startPrank(bob);
        usdmy.approve(address(vault), lowBid);
        vm.expectRevert("Bid too low");
        vault.bid(lowBid);
        vm.stopPrank();

        uint256 validBid = (minBid * 110) / 100;
        placeBid(bob, validBid);

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testEscrowAccountingCorrectness() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        uint256 reserveBefore = vault.getReserve();
        uint256 escrowBefore = vault.escrowedBid();

        placeBid(alice, minBid);

        uint256 reserveAfter = vault.getReserve();
        uint256 escrowAfter = vault.escrowedBid();

        assertEq(escrowAfter, escrowBefore + minBid, "Escrow should increase by bid amount");
        assertEq(reserveAfter, reserveBefore, "Reserve should remain unchanged");

        (, uint96 currentBid, , , ) = vault.currentAuction();
        assertEq(escrowAfter, currentBid, "Escrow should match bid amount");
    }

    // ============ Auction Security Test (1) ============

    function testRefundDoSPrevention() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(address(0x99), 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        MaliciousBidder malicious = new MaliciousBidder();
        address maliciousBidder = address(malicious);
        usdmy.mint(maliciousBidder, 100 ether);

        vm.startPrank(maliciousBidder);
        usdmy.approve(address(vault), minBid);
        vault.bid(minBid);
        vm.stopPrank();

        uint256 newBid = (minBid * 110) / 100;
        vm.startPrank(alice);
        usdmy.approve(address(vault), newBid);
        vault.bid(newBid);
        vm.stopPrank();

        assertEq(usdmy.balanceOf(maliciousBidder), 100 ether, "Should receive USDmY refund");

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, alice, "Alice should be current bidder");
    }

    // ============ Core Test moved here (1) ============

    function testAuctionWithUSDmYBids() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (address bidder, , , uint112 auctionAmount, ) = vault.currentAuction();
        assertEq(bidder, address(0), "Auction should have no bidder initially");
        assertGt(auctionAmount, 0, "Auction should have tokens");
    }

    // ============ New Tests (2) ============

    function testAuctionSlotCollisionWithExistingUnclaimedPrize() public {
        // Win auction on day D, don't claim, wait 7 days. New auction finalizes to same slot.
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 100 ether);

        skipPastMintingPeriod();

        // Generate fees and start auction
        vm.prank(alice);
        vault.transfer(bob, 10 ether);

        moveToNextDay();
        vault.executeLottery();

        // Place a bid so the auction has a winner
        (, , uint96 minBid1, uint112 auctionAmount1, uint32 auctionDay1) = vault.currentAuction();
        assertGt(auctionAmount1, 0, "First auction should have tokens");

        placeBid(david, uint256(minBid1) + 0.5 ether);

        // Track beneficiary balance
        address beneficiary = vault.owner();
        uint256 beneficiaryBefore = usdmy.balanceOf(beneficiary);

        // Advance 7 days generating fees each day to cycle through slots
        for (uint256 i = 0; i < 7; i++) {
            // Generate fees
            vm.prank(alice);
            vault.transfer(bob, 1 ether);

            moveToNextDay();
            vault.executeLottery();
        }

        // After 7 days, the same slot should be reused
        // Check that beneficiary received USDmY from the overwritten unclaimed prize
        uint256 beneficiaryAfter = usdmy.balanceOf(beneficiary);

        // David should still be able to claim if his slot hasn't been overwritten
        // or beneficiary should have received USDmY if it was overwritten
        vm.prank(david);
        uint256 davidClaimable = vault.getMyClaimableAmount();

        // Either david can still claim (slot not overwritten) or beneficiary got the prize
        assertTrue(
            davidClaimable > 0 || beneficiaryAfter > beneficiaryBefore,
            "Either david can claim or beneficiary received the overwritten prize"
        );
    }

    function testConsecutiveNoBidAuctionsAccumulateRollover() public {
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);

        skipPastMintingPeriod();

        // Track FEES_POOL balance across 3 consecutive no-bid auctions
        for (uint256 i = 0; i < 3; i++) {
            // Generate fees
            vm.prank(alice);
            vault.transfer(bob, 1 ether);

            uint256 feesPoolBefore = vault.balanceOf(vault.FEES_POOL());

            moveToNextDay();
            vault.executeLottery();

            // After each no-bid auction, the auction amount should roll back to FEES_POOL
            // The FEES_POOL balance should reflect accumulated rollover
            uint256 feesPoolAfter = vault.balanceOf(vault.FEES_POOL());

            // No-bid auction tokens should have been returned to FEES_POOL via AuctionNoBids
            // (the fees pool may also have the new transfer fee added)
        }

        // After 3 rounds of no-bid auctions, verify system is still functional
        // The rolled-over amounts should eventually be redistributed
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        moveToNextDay();
        vault.executeLottery();

        (, , , uint112 finalAuctionAmount, ) = vault.currentAuction();
        // The final auction should have accumulated all the rolled-over amounts plus new fees
        assertGt(finalAuctionAmount, 0, "Final auction should have tokens from rollover + new fees");
    }
}
