// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase} from "./helpers/GigaVaultTestBase.sol";

contract GigaVaultUSDmTest is GigaVaultTestBase {
    function testMintWithUSDm() public {
        uint256 usdmAmount = 10 ether;

        vm.startPrank(alice);
        usdm.approve(address(vault), usdmAmount);
        vault.mintWithUSDm(usdmAmount);
        vm.stopPrank();

        // Alice should have USDmore tokens (minus 1% fee)
        uint256 expectedNet = usdmAmount - (usdmAmount * 100) / 10_000;
        assertEq(vault.balanceOf(alice), expectedNet);

        // Reserve should have the USDmY (converted from USDm)
        assertEq(vault.getReserve(), usdmAmount);
    }

    function testMintWithUSDmMatchesRegularMint() public {
        uint256 amount = 5 ether;

        // Mint with USDm for alice
        mintVaultWithUSDm(alice, amount);
        uint256 aliceBalance = vault.balanceOf(alice);

        // Mint with USDmY for bob (same amount, since 1:1 mock ratio)
        mintVault(bob, amount);
        uint256 bobBalance = vault.balanceOf(bob);

        // Both should get the same USDmore amount (during first day, 1:1)
        assertEq(aliceBalance, bobBalance);
    }

    function testMintWithUSDmFees() public {
        uint256 amount = 10 ether;

        mintVaultWithUSDm(alice, amount);

        uint256 expectedFee = (amount * 100) / 10_000; // 1%
        uint256 expectedNet = amount - expectedFee;

        assertEq(vault.balanceOf(alice), expectedNet);
        assertEq(vault.balanceOf(vault.FEES_POOL()), expectedFee);
    }

    function testRedeemToUSDm() public {
        uint256 mintAmount = 10 ether;

        // First mint some tokens
        mintVault(alice, mintAmount);

        uint256 aliceVaultBalance = vault.balanceOf(alice);
        uint256 aliceUsdmBefore = usdm.balanceOf(alice);

        vm.startPrank(alice);
        vault.redeemToUSDm(aliceVaultBalance);
        vm.stopPrank();

        // Alice should have 0 vault tokens
        assertEq(vault.balanceOf(alice), 0);

        // Alice should have received USDm (not USDmY)
        uint256 aliceUsdmAfter = usdm.balanceOf(alice);
        assertGt(aliceUsdmAfter, aliceUsdmBefore);

        // Alice's USDmY balance should be unchanged (she didn't receive USDmY)
        // She started with 100 ether USDmY, spent 10 ether on mint
        assertEq(usdmy.balanceOf(alice), 90 ether);
    }

    function testRedeemToUSDmAmountCorrect() public {
        uint256 mintAmount = 10 ether;

        mintVault(alice, mintAmount);

        uint256 aliceVaultBalance = vault.balanceOf(alice);
        uint256 aliceUsdmBefore = usdm.balanceOf(alice);

        // Calculate expected USDm output
        uint256 fee = (aliceVaultBalance * 100) / 10_000;
        uint256 netTokens = aliceVaultBalance - fee;
        uint256 expectedCollateral = (netTokens * vault.getReserve()) / vault.totalSupply();

        vm.startPrank(alice);
        vault.redeemToUSDm(aliceVaultBalance);
        vm.stopPrank();

        // At 1:1 mock ratio, USDm received should equal expected USDmY collateral
        uint256 usdmReceived = usdm.balanceOf(alice) - aliceUsdmBefore;
        assertEq(usdmReceived, expectedCollateral);
    }

    // Helper to set up an auction (must advance past minting period so auctionDay > 0)
    function _setupAuction() internal {
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        // Skip past minting period
        skipPastMintingPeriod();

        // Generate fees via transfer
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Advance to next day and trigger lottery/auction
        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();
    }

    function testBidWithUSDm() public {
        _setupAuction();

        (, , uint96 minBid, , uint32 auctionDay) = vault.currentAuction();
        require(auctionDay != 0, "No auction started");

        uint256 bidAmount = uint256(minBid) + 1 ether;

        // Bid with USDm
        vm.startPrank(charlie);
        usdm.approve(address(vault), bidAmount);
        vault.bidWithUSDm(bidAmount);
        vm.stopPrank();

        // Charlie should be the current bidder
        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, charlie);
    }

    function testBidWithUSDmRefundInUSDmY() public {
        _setupAuction();

        (, , uint96 minBid, , ) = vault.currentAuction();

        uint256 firstBid = uint256(minBid) + 1 ether;

        // First bid with USDm (charlie)
        vm.startPrank(charlie);
        usdm.approve(address(vault), firstBid);
        vault.bidWithUSDm(firstBid);
        vm.stopPrank();

        uint256 charlieUsdmyBefore = usdmy.balanceOf(charlie);

        // Second bid with USDmY (david) - must be 10% higher
        uint256 secondBid = (firstBid * 110) / 100 + 1;
        vm.startPrank(david);
        usdmy.approve(address(vault), secondBid);
        vault.bid(secondBid);
        vm.stopPrank();

        // Charlie should be refunded in USDmY (not USDm)
        uint256 charlieUsdmyAfter = usdmy.balanceOf(charlie);
        assertEq(charlieUsdmyAfter - charlieUsdmyBefore, firstBid);
    }

    function testBidWithUSDmTooLow() public {
        _setupAuction();

        (, , uint96 minBid, , ) = vault.currentAuction();
        require(minBid > 1, "Min bid too low for test");

        // Try to bid less than minBid
        uint256 lowBid = uint256(minBid) - 1;

        vm.startPrank(charlie);
        usdm.approve(address(vault), lowBid);
        vm.expectRevert("Bid too low");
        vault.bidWithUSDm(lowBid);
        vm.stopPrank();

        // Charlie's USDm should be unchanged (tx reverted atomically)
        assertEq(usdm.balanceOf(charlie), 100 ether);
    }

    function testMintWithUSDmZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert("Must send USDm");
        vault.mintWithUSDm(0);
        vm.stopPrank();
    }

    function testMintWithUSDmAfterMintingPeriod() public {
        // Mint during minting period to set max supply
        mintVault(alice, 50 ether);

        skipPastMintingPeriod();

        // Trigger max supply lock by minting a small amount within capacity
        // Max supply = totalSupply at end of minting period = 50 ether
        // After minting period, first mint locks max supply and still adds to supply
        // So try to mint more than remaining capacity

        // The max supply will be set to 50 ether (total at minting period end)
        // Alice has 49.5 (50 - 1% fee), FEES_POOL has 0.5
        // Total supply is 50 ether. Max supply will be 50 ether.
        // Minting 10 ether worth of tokens would push past max supply.

        vm.startPrank(charlie);
        usdm.approve(address(vault), 10 ether);
        vm.expectRevert("Max supply reached");
        vault.mintWithUSDm(10 ether);
        vm.stopPrank();
    }

    function testRedeemToUSDmFullFlow() public {
        uint256 mintAmount = 10 ether;

        // Mint with USDm
        mintVaultWithUSDm(alice, mintAmount);

        uint256 aliceBalance = vault.balanceOf(alice);
        assertGt(aliceBalance, 0);

        uint256 aliceUsdmBefore = usdm.balanceOf(alice);

        // Redeem to USDm
        vm.startPrank(alice);
        vault.redeemToUSDm(aliceBalance);
        vm.stopPrank();

        // Alice should have 0 vault tokens
        assertEq(vault.balanceOf(alice), 0);

        // Alice should have received USDm back (minus fees)
        uint256 usdmReceived = usdm.balanceOf(alice) - aliceUsdmBefore;
        assertGt(usdmReceived, 0);

        // Due to 1% fee on mint and 1% fee on redeem, she should get less than she put in
        assertLt(usdmReceived, mintAmount);
    }
}
