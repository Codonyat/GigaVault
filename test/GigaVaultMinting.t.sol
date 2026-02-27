// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultMintingTest is GigaVaultTestBase {
    // ============ Original Minting Tests (9) ============

    function testMintingWithFee() public {
        uint256 usdmyAmount = 1 ether;
        uint256 expectedTokens = (usdmyAmount * 99) / 100;
        uint256 expectedFee = usdmyAmount / 100;

        mintVault(alice, usdmyAmount);

        assertEq(vault.balanceOf(alice), expectedTokens);
        assertEq(vault.balanceOf(vault.FEES_POOL()), expectedFee);
        assertEq(vault.getReserve(), usdmyAmount);
    }

    function testRedeemWithFee() public {
        mintVault(alice, 10 ether);

        uint256 initialBalance = vault.balanceOf(alice);
        uint256 redeemAmount = 1 ether;
        uint256 expectedFee = 0.01 ether;
        uint256 netRedeemed = redeemAmount - expectedFee;
        uint256 expectedUsdmy = netRedeemed;

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(alice, redeemAmount, expectedUsdmy, expectedFee);

        vm.prank(alice);
        vault.redeem(redeemAmount);

        assertEq(vault.balanceOf(alice), initialBalance - redeemAmount);
        assertEq(usdmy.balanceOf(alice) - aliceUsdmyBefore, expectedUsdmy);
    }

    function testMintingPeriodEnforcement() public {
        mintVault(alice, 1 ether);
        assertGt(vault.balanceOf(alice), 0);

        skipPastMintingPeriod();

        vm.startPrank(bob);
        usdmy.approve(address(vault), 1 ether);
        vm.expectRevert("Max supply reached");
        vault.mint(1 ether);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(0.1 ether);

        mintVault(bob, 0.09 ether);
        assertGt(vault.balanceOf(bob), 0);
    }

    function testCannotMintAfterPeriodWithoutCapacity() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();

        vm.startPrank(bob);
        usdmy.approve(address(vault), 1 ether);
        vm.expectRevert("Max supply reached");
        vault.mint(1 ether);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(1 ether);

        mintVault(bob, 0.9 ether);
        assertGt(vault.balanceOf(bob), 0);
    }

    function testRedeemingAllTokensDepletesContractUsdmy() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceBalance);

        uint256 bobBalance = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobBalance);

        assertTrue(vault.getReserve() < 1 ether);
    }

    function testMaxSupplyNeverExceededWithBeneficiaryDonations() public {
        address beneficiary1 = address(0x1001);
        address beneficiary2 = address(0x1002);

        usdmy.mint(beneficiary1, 100 ether);
        usdmy.mint(beneficiary2, 100 ether);

        mintVault(alice, 100 ether);

        vm.warp(block.timestamp + 8 days);

        vm.prank(alice);
        vault.redeem(1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertEq(maxSupply, 100 ether);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            vault.transfer(bob, 1 ether);

            vm.warp(block.timestamp + 25 hours + 61);
            vault.executeLottery();
        }

        mintVault(bob, 0.9 ether);

        uint256 totalSupply = vault.totalSupply();
        assertLe(totalSupply, maxSupply, "Total supply should not exceed max");
    }

    function testUsdmyDonations() public {
        uint256 initialContractBalance = vault.getReserve();

        uint256 donationAmount = 5 ether;

        vm.prank(alice);
        usdmy.transfer(address(vault), donationAmount);

        assertEq(
            vault.getReserve(),
            initialContractBalance + donationAmount,
            "Contract balance should increase by donation amount"
        );

        assertEq(vault.balanceOf(alice), 0, "No tokens should be minted for donations");
        assertEq(vault.totalSupply(), 0, "Total supply should remain unchanged");
    }

    function testContractsCanTransferTokens() public {
        MockContract mockContract = new MockContract(usdmy);
        usdmy.mint(address(mockContract), 10 ether);

        mockContract.mintVault(vault, 1 ether);
        assertEq(vault.balanceOf(address(mockContract)), 0.99 ether);

        assertFalse(vault.isHolder(address(mockContract)));

        address testAlice = address(0x1234);
        mockContract.transferVault(vault, testAlice, 0.1 ether);

        assertEq(vault.balanceOf(testAlice), 0.099 ether, "Alice should receive 0.099 after 1% fee");
        assertEq(vault.balanceOf(address(mockContract)), 0.89 ether, "Contract should have 0.89 left");

        assertTrue(vault.isHolder(testAlice), "testAlice should be tracked as holder");

        MockContract secondContract = new MockContract(usdmy);
        mockContract.transferVault(vault, address(secondContract), 0.2 ether);

        assertEq(vault.balanceOf(address(secondContract)), 0.198 ether, "Second contract should receive 0.198 after fee");
        assertEq(vault.balanceOf(address(mockContract)), 0.69 ether, "First contract should have 0.69 left");

        assertFalse(vault.isHolder(address(secondContract)), "Second contract should not be tracked");

        mockContract.approveVault(vault, address(secondContract), 0.3 ether);
        assertEq(vault.allowance(address(mockContract), address(secondContract)), 0.3 ether);

        secondContract.transferFromVault(vault, address(mockContract), testAlice, 0.3 ether);

        assertEq(vault.balanceOf(testAlice), 0.099 ether + 0.297 ether, "testAlice should have original 0.099 + 0.297 from transferFrom");
        assertEq(vault.balanceOf(address(mockContract)), 0.39 ether, "First contract should have 0.39 left");

        assertEq(vault.getHolderCount(), 1, "Only testAlice should be counted as holder");

        vm.warp(block.timestamp + 8 days);

        mockContract.transferVault(vault, testAlice, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner,) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);
        if (winner != address(0)) {
            assertEq(winner, testAlice, "Winner must be testAlice, the only EOA holder");
        }
    }

    function testMinimumMintAmountAfterMintingPeriod() public {
        mintVault(alice, 1 ether);
        mintVault(bob, 1 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.01 ether);

        assertEq(vault.maxSupplyEver(), 2 ether, "Max supply should be 2 USDmore");

        vm.prank(alice);
        vault.redeem(0.5 ether);

        usdmy.mint(address(this), 10000 ether);
        usdmy.transfer(address(vault), 10000 ether);

        vm.startPrank(charlie);
        usdmy.approve(address(vault), 1 wei);
        vm.expectRevert("Minimum mint amount is 100 wei");
        vault.mint(1 wei);
        vm.stopPrank();

        vm.startPrank(charlie);
        usdmy.approve(address(vault), 658000 wei);
        vm.expectRevert("Minimum mint amount is 100 wei");
        vault.mint(658000 wei);
        vm.stopPrank();

        vm.startPrank(charlie);
        usdmy.approve(address(vault), 665000 wei);
        vault.mint(665000 wei);
        vm.stopPrank();

        uint256 charlieBalance = vault.balanceOf(charlie);
        assertEq(charlieBalance, 99, "Charlie should have exactly 99 wei after fee");
    }

    // ============ Donation Tests (7) ============

    function testDonationIncreasesRedemptionValue() public {
        uint256 mintAmount = 10 ether;
        uint256 expectedTokens = mintAmount * 99 / 100;
        uint256 expectedFee = mintAmount / 100;

        mintVault(alice, mintAmount);

        assertEq(vault.balanceOf(alice), expectedTokens, "Alice should receive 9.9 tokens");
        assertEq(vault.balanceOf(vault.FEES_POOL()), expectedFee, "Fees pool should have 0.1 tokens");

        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 contractBalanceBefore = vault.getReserve();
        assertEq(totalSupplyBefore, 10 ether, "Total supply should be 10 tokens");
        assertEq(contractBalanceBefore, mintAmount, "Contract should hold 10 USDmY");

        uint256 redeemAmount = 1 ether;
        uint256 fee = redeemAmount / 100;
        uint256 netAmount = redeemAmount - fee;
        uint256 redemptionValueBefore = (netAmount * contractBalanceBefore) / totalSupplyBefore;
        assertEq(redemptionValueBefore, 0.99 ether, "Redemption value before should be 0.99 USDmY");

        uint256 donationAmount = 5 ether;
        donateUsdmy(alice, donationAmount);

        assertEq(vault.getReserve(), contractBalanceBefore + donationAmount, "Contract balance should increase by 5 USDmY");
        assertEq(vault.totalSupply(), totalSupplyBefore, "Total supply should remain 10 tokens");

        uint256 redemptionValueAfter = (netAmount * vault.getReserve()) / vault.totalSupply();
        assertEq(redemptionValueAfter, 1.485 ether, "Redemption value after should be 1.485 USDmY");

        assertEq(redemptionValueAfter - redemptionValueBefore, 0.495 ether, "Redemption value should increase by 0.495 USDmY");
    }

    function testDonationDoesntAffectMinting() public {
        mintVault(alice, 1 ether);
        assertEq(vault.balanceOf(alice), 0.99 ether, "Alice should get 0.99 tokens");

        uint256 donationAmount = 10 ether;
        donateUsdmy(alice, donationAmount);
        assertEq(vault.getReserve(), 11 ether, "Contract should have 11 USDmY");

        mintVault(bob, 1 ether);

        assertEq(vault.balanceOf(bob), 0.99 ether, "Bob should get 0.99 tokens despite donation");
        assertEq(vault.getReserve(), 12 ether, "Contract should have 12 USDmY");
    }

    function testDonationDoesntBreakLottery() public {
        mintVault(alice, 10 ether);
        assertEq(vault.balanceOf(alice), 9.9 ether, "Alice should have 9.9 tokens");

        mintVault(bob, 10 ether);
        assertEq(vault.balanceOf(bob), 9.9 ether, "Bob should have 9.9 tokens");

        uint256 transferAmount = 1 ether;

        vm.prank(alice);
        vault.transfer(bob, transferAmount);
        assertEq(vault.balanceOf(alice), 8.9 ether, "Alice should have 8.9 tokens");
        assertEq(vault.balanceOf(bob), 10.89 ether, "Bob should have 10.89 tokens");
        assertEq(vault.balanceOf(vault.FEES_POOL()), 0.21 ether, "Fees pool should have 0.21 tokens");

        uint256 donationAmount = 5 ether;
        donateUsdmy(charlie, donationAmount);
        assertEq(vault.getReserve(), 25 ether, "Contract should have 25 USDmY");

        vm.warp(block.timestamp + 25 hours);

        vm.prank(bob);
        vault.transfer(alice, transferAmount);
        assertEq(vault.balanceOf(bob), 9.89 ether, "Bob should have 9.89 tokens");
        assertEq(vault.balanceOf(alice), 9.89 ether, "Alice should have 9.89 tokens");
        assertEq(vault.balanceOf(vault.FEES_POOL()), 0.22 ether, "Fees pool should have 0.22 tokens");

        vm.warp(block.timestamp + 25 hours + 61);

        vault.executeLottery();

        assertEq(vault.lastLotteryDay(), 2, "Lottery should be executed for day 2");
    }

    function testMultipleDonations() public {
        mintVault(alice, 1 ether);

        uint256 initialBalance = vault.getReserve();

        for (uint256 i = 0; i < 5; i++) {
            address currentDonor = address(uint160(0x100 + i));
            usdmy.mint(currentDonor, 10 ether);
            donateUsdmy(currentDonor, 1 ether);
        }

        assertEq(vault.getReserve(), initialBalance + 5 ether);
        assertEq(vault.totalSupply(), 1 ether);
    }

    function testDonationAfterMintingPeriod() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.redeem(0.1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertTrue(maxSupply > 0, "Max supply should be set");

        donateUsdmy(charlie, 5 ether);

        assertEq(vault.maxSupplyEver(), maxSupply);

        usdmy.mint(bob, 10 ether);
        mintVault(bob, 0.09 ether);
    }

    function testRedemptionWithDonation() public {
        uint256 mintAmount = 10 ether;
        mintVault(alice, mintAmount);

        uint256 aliceTokens = vault.balanceOf(alice);
        assertEq(aliceTokens, 9.9 ether, "Alice should have 9.9 tokens");

        uint256 donationAmount = 5 ether;
        donateUsdmy(charlie, donationAmount);
        assertEq(vault.getReserve(), 15 ether, "Contract should have 15 USDmY");

        uint256 redeemAmount = aliceTokens / 2;
        uint256 redeemFee = redeemAmount / 100;
        uint256 netRedeemed = redeemAmount - redeemFee;
        uint256 expectedCollateral = (netRedeemed * 15 ether) / vault.totalSupply();

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(alice, redeemAmount, expectedCollateral, redeemFee);

        vm.prank(alice);
        vault.redeem(redeemAmount);

        uint256 aliceUsdmyAfter = usdmy.balanceOf(alice);
        uint256 usdmyReceived = aliceUsdmyAfter - aliceUsdmyBefore;

        assertEq(usdmyReceived, expectedCollateral, "Alice should receive exact USDmY amount");
        assertTrue(usdmyReceived > 7.35 ether, "Should receive over 7.35 USDmY due to donation");
        assertEq(vault.balanceOf(alice), 4.95 ether, "Alice should have 4,950 tokens left");
    }

    function testFuzzDonations(uint256 donationAmount, uint8 numDonors) public {
        donationAmount = bound(donationAmount, 0.001 ether, 10 ether);
        numDonors = uint8(bound(numDonors, 1, 10));

        mintVault(alice, 1 ether);

        uint256 totalDonated = 0;
        uint256 initialBalance = vault.getReserve();

        for (uint256 i = 0; i < numDonors; i++) {
            address currentDonor = address(uint160(0x1000 + i));
            usdmy.mint(currentDonor, donationAmount + 1 ether);
            donateUsdmy(currentDonor, donationAmount);
            totalDonated += donationAmount;
        }

        assertEq(vault.getReserve(), initialBalance + totalDonated);
        assertEq(vault.totalSupply(), 1 ether);
    }

    // ============ MaxSupplyOrder Tests (3) ============

    function testMaxSupplySetBeforeBurns() public {
        mintVault(alice, 50 ether);
        mintVault(bob, 30 ether);
        mintVault(charlie, 20 ether);

        uint256 totalSupplyAtEndOfMinting = vault.totalSupply();
        assertEq(totalSupplyAtEndOfMinting, 100 ether, "Total supply should be 100 vault tokens");

        vm.warp(vault.mintingEndTime() + 1);

        assertEq(vault.maxSupplyEver(), 0, "Max supply not yet set");

        uint256 totalSupplyBeforeFirstTx = vault.totalSupply();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        uint256 maxSupplyEver = vault.maxSupplyEver();
        assertEq(maxSupplyEver, totalSupplyBeforeFirstTx, "Max supply should be set to initial total");
        assertEq(maxSupplyEver, 100 ether, "Max supply should be 100 vault tokens");

        uint256 currentSupply = vault.totalSupply();
        assertEq(currentSupply, maxSupplyEver, "Supply unchanged - fees just moved between accounts");

        vm.prank(bob);
        vault.transfer(charlie, 2 ether);

        assertEq(vault.maxSupplyEver(), maxSupplyEver, "Max supply should never change once set");
    }

    function testMaxSupplyWithImmediateBeneficiaryBurn() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        for (uint256 i = 0; i < 7; i++) {
            vm.prank(bob);
            vault.transfer(alice, 0.1 ether);

            vm.warp(block.timestamp + 25 hours + 61);

            if (block.timestamp <= vault.mintingEndTime()) {
                vault.executeLottery();
            }
        }

        assertTrue(block.timestamp > vault.mintingEndTime(), "Should be past minting period");

        vm.prank(alice);
        vault.transfer(bob, 0.2 ether);

        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 maxSupplyBefore = vault.maxSupplyEver();

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        uint256 maxSupply = vault.maxSupplyEver();
        uint256 totalSupplyAfter = vault.totalSupply();

        assertTrue(maxSupply > 0, "Max supply should be set");
        if (maxSupplyBefore == 0) {
            assertEq(maxSupply, totalSupplyBefore, "Max supply should be set before burns");
        } else {
            assertEq(maxSupply, maxSupplyBefore, "Max supply shouldn't change");
        }

        if (totalSupplyAfter < totalSupplyBefore) {
            assertTrue(totalSupplyAfter < maxSupply, "Current supply should be less than max after burns");
        }
    }

    function testTransferTriggersMaxSupplyBeforeLottery() public {
        mintVault(alice, 10 ether);

        vm.warp(vault.mintingEndTime() + 1);

        assertEq(vault.maxSupplyEver(), 0, "Max supply not yet set");

        uint256 totalSupplyBefore = vault.totalSupply();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertEq(maxSupply, totalSupplyBefore, "Max supply should be set by transfer");
        assertEq(maxSupply, 10 ether, "Max supply should be 10 vault tokens");
    }

    // ============ Security Tests moved to Minting (5) ============

    function testMintZeroAmount() public {
        vm.startPrank(alice);
        usdmy.approve(address(vault), 0);
        vm.expectRevert("Must send USDmY");
        vault.mint(0);
        vm.stopPrank();
    }

    function testRedeemZeroAmount() public {
        mintVault(alice, 1 ether);

        vm.prank(alice);
        vm.expectRevert("Amount must be greater than 0");
        vault.redeem(0);
    }

    function testRedeemWithInsufficientContractUsdmy() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        vm.prank(alice);
        vault.redeem(9.9 ether);

        vm.prank(bob);
        vault.redeem(9.9 ether);

        assertTrue(vault.getReserve() < 1 ether, "Contract should be nearly empty");
    }

    function testMaxSupplyEnforcement() public {
        mintVault(alice, 100 ether);

        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        vm.prank(alice);
        vault.redeem(1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertGt(maxSupply, 0, "Max supply should be set");
        assertEq(maxSupply, 100 ether, "Max supply should be 100 vault tokens");

        usdmy.mint(bob, 10 ether);
        mintVault(bob, 0.9 ether);

        vm.startPrank(bob);
        usdmy.approve(address(vault), 0.1 ether);
        vm.expectRevert("Max supply reached");
        vault.mint(0.1 ether);
        vm.stopPrank();
    }

    function testLargeFeeCalculation() public {
        uint256 largeAmount = 10_000 ether;

        usdmy.mint(alice, largeAmount + 1 ether);
        mintVault(alice, largeAmount);

        uint256 expectedTokens = (largeAmount * 99) / 100;
        assertEq(vault.balanceOf(alice), expectedTokens, "Should receive correct amount");

        uint256 expectedFee = largeAmount / 100;
        assertEq(vault.balanceOf(vault.FEES_POOL()), expectedFee, "Fee should be correct");
    }

    // ============ New Tests (3) ============

    function testExactProportionalMintingFormula() public {
        // Day 0: Alice mints at 1:1
        mintVault(alice, 10 ether);
        assertEq(vault.balanceOf(alice), 9.9 ether, "Alice should have 9.9 tokens after fee");

        // Donate to change reserve/supply ratio
        usdmy.mint(address(this), 5 ether);
        usdmy.transfer(address(vault), 5 ether);

        // Move past day 1 (proportional minting kicks in after oneDayEndTime)
        vm.warp(block.timestamp + 25 hours + 1);

        // State: reserve = 15 ether, totalSupply = 10 ether
        uint256 reserveBefore = vault.getReserve();
        uint256 supplyBefore = vault.totalSupply();
        assertEq(reserveBefore, 15 ether, "Reserve should be 15 USDmY");
        assertEq(supplyBefore, 10 ether, "Supply should be 10 USDmore");

        // Bob mints 3 USDmY
        uint256 collateral = 3 ether;
        uint256 expectedTokensToMint = (collateral * supplyBefore) / reserveBefore; // 3 * 10 / 15 = 2
        uint256 expectedFee = (expectedTokensToMint * 100) / 10_000; // 1% fee
        uint256 expectedNet = expectedTokensToMint - expectedFee;

        mintVault(bob, collateral);

        assertEq(vault.balanceOf(bob), expectedNet, "Bob should receive exact proportional amount minus fee");
    }

    function testRedemptionRoundingWithSmallAmounts() public {
        mintVault(alice, 10 ether);

        // Redeem 101 wei
        uint256 tinyRedeem = 101;
        uint256 fee = (tinyRedeem * 100) / 10_000; // 1 wei
        uint256 netTokens = tinyRedeem - fee; // 100 wei
        uint256 expectedCollateral = (netTokens * vault.getReserve()) / vault.totalSupply();

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(tinyRedeem);
        uint256 usdmyReceived = usdmy.balanceOf(alice) - aliceUsdmyBefore;

        assertEq(usdmyReceived, expectedCollateral, "Collateral should match exact formula");
        // Rounding should lose at most 1 wei
        assertGe(expectedCollateral, netTokens - 1, "Rounding should lose at most 1 wei");

        // Redeem 200 wei
        uint256 smallRedeem = 200;
        uint256 fee2 = (smallRedeem * 100) / 10_000; // 2 wei
        uint256 netTokens2 = smallRedeem - fee2; // 198 wei
        uint256 expectedCollateral2 = (netTokens2 * vault.getReserve()) / vault.totalSupply();

        uint256 aliceUsdmyBefore2 = usdmy.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(smallRedeem);
        uint256 usdmyReceived2 = usdmy.balanceOf(alice) - aliceUsdmyBefore2;

        assertEq(usdmyReceived2, expectedCollateral2, "Collateral should match exact formula for 200 wei");
    }

    function testMintAtExactMaxSupplyBoundary() public {
        // Mint during minting period
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();

        // Trigger max supply lock
        vm.prank(alice);
        vault.redeem(1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertEq(maxSupply, 10 ether, "Max supply should be 10 USDmore");

        // Calculate remaining capacity
        uint256 currentSupply = vault.totalSupply();
        uint256 remainingCapacity = maxSupply - currentSupply;
        assertTrue(remainingCapacity > 0, "Should have some remaining capacity");

        // Calculate how much USDmY to mint exactly the remaining capacity
        // tokensToMint = (collateral * totalSupply) / reserve
        // collateral = (tokensToMint * reserve) / totalSupply
        uint256 reserve = vault.getReserve();
        uint256 exactCollateral = (remainingCapacity * reserve) / currentSupply;

        // Mint exactly the remaining capacity — should succeed
        usdmy.mint(bob, exactCollateral + 1 ether);
        mintVault(bob, exactCollateral);
        assertGt(vault.balanceOf(bob), 0, "Bob should have minted successfully");

        // Now supply should be at or very near max
        uint256 supplyAfter = vault.totalSupply();
        assertLe(supplyAfter, maxSupply, "Supply should not exceed max");

        // Minting 1 more wei should revert (either "Max supply reached" or "Minimum mint amount")
        vm.startPrank(bob);
        usdmy.approve(address(vault), 1 ether);
        vm.expectRevert();
        vault.mint(1 ether);
        vm.stopPrank();
    }
}
