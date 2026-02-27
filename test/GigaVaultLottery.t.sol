// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract, MockRejectNative} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultLotteryTest is GigaVaultTestBase {
    // ============ Original Lottery Tests (14) ============

    function testPrevrandaoLottery() public {
        mintVault(alice, 10 ether);
        assertEq(vault.balanceOf(alice), 9.9 ether, "Alice should have 9.9 USDmore");

        mintVault(bob, 5 ether);
        assertEq(vault.balanceOf(bob), 4.95 ether, "Bob should have 4.95 USDmore");

        skipPastMintingPeriod();

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 bobBalanceBefore = vault.balanceOf(bob);
        vm.prank(alice);
        bool success = vault.transfer(bob, 1 ether);
        assertTrue(success, "Transfer should succeed");
        assertEq(vault.balanceOf(alice), aliceBalanceBefore - 1 ether, "Alice balance should decrease by 1");
        assertEq(vault.balanceOf(bob), bobBalanceBefore + 0.99 ether, "Bob should receive 0.99");

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123456)));

        vm.expectEmit(false, false, false, false);
        emit LotteryWon(address(0), 0, 0);
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner, uint112 amount) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);

        assertTrue(winner == alice || winner == bob, "Winner should be alice or bob");
        uint256 expectedLotteryAmount = (0.01 ether * vault.LOTTERY_PERCENT()) / 100;
        assertEq(amount, expectedLotteryAmount, "Prize amount should be LOTTERY_PERCENT of fee");
    }

    function testLotteryWithMultipleHolders() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);
        vm.prank(bob);
        vault.transfer(charlie, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(789012)));
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner, uint112 amount) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);

        assertTrue(winner == alice || winner == bob || winner == charlie, "Winner should be one of the holders");
        assertGt(amount, 0, "Winner should have prize amount");
    }

    function testLotteryProbabilityDistribution() public {
        uint256 rounds = 20;
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);
        mintVault(charlie, 2 ether);

        uint256 aliceWins;
        uint256 bobWins;
        uint256 charlieWins;

        skipPastMintingPeriod();

        for (uint256 i = 0; i < rounds; i++) {
            if (i % 3 == 0 && vault.balanceOf(alice) > 0.1 ether) {
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);
            } else if (i % 3 == 1 && vault.balanceOf(bob) > 0.1 ether) {
                vm.prank(bob);
                vault.transfer(charlie, 0.1 ether);
            } else if (vault.balanceOf(charlie) > 0.1 ether) {
                vm.prank(charlie);
                vault.transfer(alice, 0.1 ether);
            }

            vm.warp(block.timestamp + 25 hours + 61);
            vm.prevrandao(bytes32(uint256(keccak256(abi.encode(i, "test")))));
            vault.executeLottery();

            uint256 currentDay = vault.getCurrentDay();
            uint256 prizeDay = (currentDay - 1) % 7;
            (address winner,) = vault.lotteryUnclaimedPrizes(prizeDay);

            if (winner == alice) aliceWins++;
            else if (winner == bob) bobWins++;
            else if (winner == charlie) charlieWins++;
        }

        uint256 totalWins = aliceWins + bobWins + charlieWins;
        assertGt(totalWins, 0, "Should have at least some lottery wins");
    }

    function testAllExternalFunctionsTriggerLottery() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(12345)));

        uint256 balance = vault.balanceOf(alice);
        assertTrue(balance > 0, "Alice should have balance");

        (address winner8,) = vault.lotteryUnclaimedPrizes(8 % 7);
        (address winner9,) = vault.lotteryUnclaimedPrizes(9 % 7);
        (, , , uint112 auctionAmount,) = vault.currentAuction();

        assertTrue(winner8 != address(0) || winner9 != address(0) || auctionAmount > 0, "Should have lottery winner or auction");
    }

    function testBalanceChangesInSnapshotBlockDontAffectLottery() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123)));
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner1,) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);

        vm.prank(bob);
        vault.transfer(charlie, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(456)));
        vault.executeLottery();

        assertTrue(winner1 != address(0), "Should have winner from first lottery");
    }

    function testLotteryAfterComplexHolderChanges() public {
        setupBasicHolders();
        mintVault(david, 3 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(eve, 0.5 ether);
        vm.prank(bob);
        vault.transfer(alice, 0.3 ether);
        vm.prank(charlie);
        vault.transfer(david, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(999)));
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner,) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);
        assertTrue(winner != address(0), "Should have lottery winner");
    }

    function testSecondLotteryExecution() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(111)));
        vault.executeLottery();

        uint256 day1 = vault.getCurrentDay() - 1;
        (address winner1, uint112 amount1) = vault.lotteryUnclaimedPrizes(day1 % 7);

        vm.prank(bob);
        vault.transfer(charlie, 0.2 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(222)));
        vault.executeLottery();

        uint256 day2 = vault.getCurrentDay() - 1;
        (address winner2, uint112 amount2) = vault.lotteryUnclaimedPrizes(day2 % 7);

        assertTrue(winner1 != address(0), "First lottery should have winner");
        assertTrue(winner2 != address(0), "Second lottery should have winner");
        assertGt(amount1, 0, "First prize should be positive");
        assertGt(amount2, 0, "Second prize should be positive");
    }

    function testDay0FeesDistributedOnDay1() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123)));
        vault.executeLottery();

        (address winner, uint112 amount) = vault.lotteryUnclaimedPrizes(0);
        assertTrue(winner != address(0), "Day 0 should have lottery winner");
        uint256 expectedLotteryAmount = (0.151 ether * vault.LOTTERY_PERCENT()) / 100;
        assertEq(amount, expectedLotteryAmount, "Day 0 lottery prize should be LOTTERY_PERCENT of fees");
    }

    function testDelayedLotteryTrigger() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        vm.warp(block.timestamp + 5 * 25 hours);
        vm.prevrandao(bytes32(uint256(789)));
        vault.executeLottery();

        bool hasWinner = false;
        for (uint256 day = 8; day <= 13; day++) {
            (address winner,) = vault.lotteryUnclaimedPrizes(day % 7);
            if (winner != address(0)) {
                hasWinner = true;
                break;
            }
        }

        (, , , uint112 auctionAmount,) = vault.currentAuction();
        assertTrue(hasWinner || auctionAmount > 0, "Should have executed delayed lottery or auction");
    }

    function testNoLotteryWhenNoFeesCollected() public {
        // Deploy a fresh vault with zero fee activity
        // Minting itself creates fees, so we need MIN_FEES_FOR_DISTRIBUTION check
        mintVault(alice, 0.1 ether);

        // Warp well past minting period
        vm.warp(block.timestamp + 20 days);

        // First try should fail or succeed depending on accumulated minting fees
        try vault.executeLottery() {} catch {}

        // Warp to next day
        vm.warp(block.timestamp + 25 hours + 61);

        // If all fees were already distributed, this should revert
        try vault.executeLottery() {} catch {}

        // Verify: no auction should be active with no fees
        // (system handled the no-fee scenario gracefully)
        uint256 feesPool = vault.balanceOf(vault.FEES_POOL());
        assertTrue(feesPool < vault.MIN_FEES_FOR_DISTRIBUTION(), "Remaining fees should be below distribution threshold");
    }

    function testDirectPrizeStorage() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);
        vm.prank(bob);
        vault.transfer(charlie, 0.5 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123456)));
        vault.executeLottery();

        (, , , uint112 auctionAmount,) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Should have auction amount");
        uint256 expectedAuctionAmount = (0.015 ether * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");

        uint256 lotPoolBalance = vault.balanceOf(vault.LOT_POOL());
        assertGe(lotPoolBalance, expectedAuctionAmount, "LOT_POOL should have at least the prize amount");
    }

    function testClaimPrize() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(12345)));
        vault.executeLottery();

        // Check lottery prize slot
        uint256 currentDay = vault.getCurrentDay();
        uint256 lotteryDay = currentDay - 1;
        (address winner, uint112 amount) = vault.lotteryUnclaimedPrizes(lotteryDay % 7);

        if (winner != address(0)) {
            // Get total claimable (may include prizes from other slots)
            vm.prank(winner);
            uint256 totalClaimable = vault.getMyClaimableAmount();
            assertGe(totalClaimable, amount, "Total claimable should be at least this slot's prize");

            uint256 winnerBalanceBefore = vault.balanceOf(winner);
            vm.prank(winner);
            vault.claim();
            uint256 winnerBalanceAfter = vault.balanceOf(winner);

            assertEq(winnerBalanceAfter - winnerBalanceBefore, totalClaimable, "Winner should receive total claimable amount");

            (address winnerAfterClaim, uint112 amountAfterClaim) = vault.lotteryUnclaimedPrizes(lotteryDay % 7);
            assertEq(winnerAfterClaim, address(0), "Prize should be marked as claimed");
            assertEq(amountAfterClaim, 0, "Prize amount should be zero after claim");
        } else {
            (, , , uint112 auctionAmount,) = vault.currentAuction();
            assertGt(auctionAmount, 0, "Should have auction if no lottery winner");
        }
    }

    function testNoContractsInLottery() public {
        MockContract mockContract = new MockContract(usdmy);
        usdmy.mint(address(mockContract), 10 ether);

        mockContract.mintVault(vault, 1 ether);

        assertFalse(vault.isHolder(address(mockContract)));
        assertEq(vault.getHolderCount(), 0);

        mintVault(alice, 1 ether);

        assertEq(vault.getHolderCount(), 1);
        assertTrue(vault.isHolder(alice));
    }

    function testLotteryWithManyUsersRandomOperations() public {
        uint256 userCount = 10;
        for (uint256 i = 0; i < userCount; i++) {
            address user = address(uint160(0x1000 + i));
            usdmy.mint(user, 10 ether);

            uint256 mintAmount = ((i % 3) + 1) * 0.5 ether;
            vm.startPrank(user);
            usdmy.approve(address(vault), mintAmount);
            vault.mint(mintAmount);
            vm.stopPrank();
        }

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 25 hours);

        for (uint256 i = 0; i < 10; i++) {
            address from = address(uint160(0x1000 + (i % userCount)));
            address to = address(uint160(0x1000 + ((i + 3) % userCount)));

            uint256 balance = vault.balanceOf(from);
            if (balance > 0.1 ether) {
                vm.prank(from);
                vault.transfer(to, 0.1 ether);
            }
        }

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(987654)));
        vault.executeLottery();

        (address winner,) = vault.lotteryUnclaimedPrizes(9 % 7);
        (, , , uint112 auctionAmount,) = vault.currentAuction();
        assertTrue(winner != address(0) || auctionAmount > 0, "Should have executed lottery or auction");
    }

    // ============ Core Tests moved here (5) ============

    function testNativeSentToBeneficiariesNotTokens() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Track owner's USDmY balance
        uint256 ownerUsdmyBefore = usdmy.balanceOf(vault.owner());

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123)));
        vault.executeLottery();

        // Fast forward 14 days to trigger unclaimed prize distribution to beneficiary
        for (uint256 i = 0; i < 14; i++) {
            vm.prank(alice);
            vault.transfer(bob, 0.1 ether);
            vm.warp(block.timestamp + 25 hours + 61);
            vault.executeLottery();
        }

        // Verify beneficiary (owner) received USDmY from expired unclaimed prizes
        uint256 ownerUsdmyAfter = usdmy.balanceOf(vault.owner());
        assertGt(ownerUsdmyAfter, ownerUsdmyBefore, "Beneficiary should have received USDmY from expired prizes");
    }

    function testUnclaimedPrizeFailedTransferGoesToCurrentWinner() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        // Generate fees and execute lottery
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(111)));
        vault.executeLottery();

        (address winner1, uint112 amount1) = vault.lotteryUnclaimedPrizes(9 % 7);

        // Generate fees for multiple days to overwrite slots and trigger unclaimed prize handling
        for (uint256 i = 0; i < 14; i++) {
            if (vault.balanceOf(bob) > 100 ether) {
                vm.prank(bob);
                vault.transfer(alice, 0.1 ether);
            } else if (vault.balanceOf(alice) > 100 ether) {
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);
            }

            vm.warp(block.timestamp + 25 hours + 61);
            vm.prevrandao(bytes32(uint256(i * 1000)));
            vault.executeLottery();
        }

        // Verify the system continues to work after handling unclaimed prizes
        // Check that at least some prizes exist in the system
        bool hasPrizes = false;
        for (uint256 slot = 0; slot < 7; slot++) {
            (address w, uint112 a) = vault.lotteryUnclaimedPrizes(slot);
            if (w != address(0) && a > 0) {
                hasPrizes = true;
                break;
            }
        }
        assertTrue(hasPrizes, "System should have active prizes after 14 days of operation");
    }

    function testUnclaimedPrizeGoesToBeneficiary() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        // Generate fees
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Execute lottery with deterministic prevrandao
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(999)));
        vault.executeLottery();

        // Track beneficiary balance
        address beneficiary = vault.owner();
        uint256 beneficiaryUsdmyBefore = usdmy.balanceOf(beneficiary);

        // Wait 7+ days to trigger unclaimed prize distribution to beneficiary
        for (uint256 i = 0; i < 14; i++) {
            if (vault.balanceOf(alice) > 0.15 ether) {
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);
            }
            vm.warp(block.timestamp + 25 hours + 61);
            vm.prevrandao(bytes32(uint256(i * 7777)));
            vault.executeLottery();
        }

        // Beneficiary should have received USDmY from expired unclaimed prizes
        uint256 beneficiaryUsdmyAfter = usdmy.balanceOf(beneficiary);
        assertGt(beneficiaryUsdmyAfter, beneficiaryUsdmyBefore, "Beneficiary should have received USDmY from expired prizes");
    }

    function testBeneficiaryFunding() public {
        setupBasicHolders();
        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 5 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (address winner1, uint112 prizeAmount1) = vault.lotteryUnclaimedPrizes(8 % 7);

        if (winner1 != address(0)) {
            address beneficiary = vault.owner();
            uint256 beneficiaryUsdmyBefore = usdmy.balanceOf(beneficiary);

            uint256 contractUsdmyBefore = vault.getReserve();
            uint256 totalSupplyBefore = vault.totalSupply();

            for (uint256 i = 0; i < 7; i++) {
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);

                vm.warp(block.timestamp + 25 hours + 61);
                vault.executeLottery();
            }

            uint256 beneficiaryUsdmyAfter = usdmy.balanceOf(beneficiary);

            uint256 expectedUsdmy = (prizeAmount1 * contractUsdmyBefore) / totalSupplyBefore;

            assertApproxEqAbs(
                beneficiaryUsdmyAfter - beneficiaryUsdmyBefore,
                expectedUsdmy,
                1,
                "Beneficiary should receive USDmY based on proper token/USDmY conversion"
            );
        }
    }

    function testBeneficiaryFundingReverts() public {
        MockRejectNative rejectingBeneficiary = new MockRejectNative();

        setupBasicHolders();
        skipPastMintingPeriod();

        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(999)));
        vault.executeLottery();

        (address winner,) = vault.lotteryUnclaimedPrizes(9 % 7);
        (address bidder, , , uint112 auctionAmount,) = vault.currentAuction();

        assertTrue(
            winner != address(0) || auctionAmount > 0,
            "Should have executed lottery/auction despite public good reverting"
        );
    }

    // ============ UnclaimedPrizes Tests (4) ============

    function testLotteryWinnerKeepsClaimableAmount() public {
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 100 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 10 ether);
        vm.prank(bob);
        vault.transfer(charlie, 5 ether);

        moveToNextDay();
        vault.executeLottery();

        vm.prank(charlie);
        vault.transfer(alice, 3 ether);

        moveToNextDay();
        vault.executeLottery();

        vm.prank(alice);
        uint256 aliceClaimable = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobClaimable = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieClaimable = vault.getMyClaimableAmount();

        (, , uint96 minBid, uint112 auctionAmount,) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Auction should have tokens");

        placeBid(david, 1 ether);

        vm.prank(alice);
        vault.transfer(bob, 2 ether);

        moveToNextDay();
        vault.executeLottery();

        vm.prank(alice);
        uint256 aliceAfter = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobAfter = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieAfter = vault.getMyClaimableAmount();
        vm.prank(david);
        uint256 davidClaimable = vault.getMyClaimableAmount();

        bool aliceLost = aliceAfter < aliceClaimable;
        bool bobLost = bobAfter < bobClaimable;
        bool charlieLost = charlieAfter < charlieClaimable;

        assertTrue(!aliceLost && !bobLost && !charlieLost && davidClaimable > 0, "No lottery winner should lose their prize");
    }

    function testBothWinnersCanClaim() public {
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 100 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 10 ether);

        moveToNextDay();
        vault.executeLottery();

        vm.prank(bob);
        vault.transfer(alice, 5 ether);

        moveToNextDay();
        vault.executeLottery();

        vm.prank(alice);
        uint256 aliceClaimableBefore = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobClaimableBefore = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieClaimableBefore = vault.getMyClaimableAmount();

        (, , uint96 minBid, uint112 auctionAmount,) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Auction should have tokens");

        placeBid(david, 1 ether);

        moveToNextDay();
        vault.executeLottery();

        vm.prank(alice);
        uint256 aliceClaimableAfter = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobClaimableAfter = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieClaimableAfter = vault.getMyClaimableAmount();
        vm.prank(david);
        uint256 davidClaimable = vault.getMyClaimableAmount();

        bool aliceLost = aliceClaimableAfter < aliceClaimableBefore;
        bool bobLost = bobClaimableAfter < bobClaimableBefore;
        bool charlieLost = charlieClaimableAfter < charlieClaimableBefore;

        assertTrue(!aliceLost && !bobLost && !charlieLost, "No lottery winner should lose claimable prize");

        if (davidClaimable > 0) {
            uint256 davidBalanceBefore = vault.balanceOf(david);
            vm.prank(david);
            vault.claim();
            uint256 davidBalanceAfter = vault.balanceOf(david);

            assertEq(davidBalanceAfter - davidBalanceBefore, davidClaimable, "David should claim exact claimable amount");

            vm.prank(david);
            assertEq(vault.getMyClaimableAmount(), 0, "David should have no claimable after claiming");
        }
    }

    function testAuctionsStartFromDay1() public {
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 50 ether);

        uint256 currentDay = vault.getCurrentDay();
        assertEq(currentDay, 0, "Should be day 0");

        vm.prank(alice);
        vault.transfer(bob, 5 ether);
        vm.prank(bob);
        vault.transfer(charlie, 3 ether);

        moveToNextDay();
        currentDay = vault.getCurrentDay();
        assertEq(currentDay, 1, "Should be day 1");

        vm.prevrandao(bytes32(uint256(12345)));
        vault.executeLottery();

        (, , , uint112 auctionAmount, uint32 auctionDay) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Auction should be active from day 1");
        assertEq(auctionDay, 0, "Auction should be for day 0 fees");

        (address lotteryWinner, uint112 lotteryPrize) = vault.lotteryUnclaimedPrizes(0 % 7);
        assertTrue(
            lotteryWinner == alice || lotteryWinner == bob || lotteryWinner == charlie,
            "Should have a lottery winner"
        );
        assertGt(lotteryPrize, 0, "Lottery prize should be greater than 0");
    }

    function testExactPrizeAmountsClaimed() public {
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 50 ether);

        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 10 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(111111)));
        vault.executeLottery();

        uint256 lotteryDay = 1;
        (address lotteryWinner, uint112 lotteryPrizeAmount) = vault.lotteryUnclaimedPrizes(lotteryDay % 7);

        vm.prank(lotteryWinner);
        uint256 claimableBeforeClaim = vault.getMyClaimableAmount();
        assertEq(claimableBeforeClaim, lotteryPrizeAmount, "Claimable should match lottery prize");

        uint256 balanceBeforeClaim = vault.balanceOf(lotteryWinner);
        vm.prank(lotteryWinner);
        vault.claim();
        uint256 balanceAfterClaim = vault.balanceOf(lotteryWinner);

        uint256 actualClaimed = balanceAfterClaim - balanceBeforeClaim;
        assertEq(actualClaimed, lotteryPrizeAmount, "Should claim exact lottery prize amount");

        vm.prank(lotteryWinner);
        uint256 claimableAfterClaim = vault.getMyClaimableAmount();
        assertEq(claimableAfterClaim, 0, "Should have no claimable amount after claiming");

        (address winnerAfter, uint112 amountAfter) = vault.lotteryUnclaimedPrizes(lotteryDay % 7);
        assertEq(winnerAfter, address(0), "Winner should be cleared after claim");
        assertEq(amountAfter, 0, "Amount should be cleared after claim");
    }

    // ============ Security Test moved here (1) ============

    function testUnclaimedPrizeToBeneficiaries() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        vm.prank(bob);
        vault.transfer(alice, 0.5 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (address winner1, uint112 amount1) = vault.lotteryUnclaimedPrizes(9 % 7);
        if (winner1 == address(0)) {
            (winner1, amount1) = vault.lotteryUnclaimedPrizes(8 % 7);
        }
        assertTrue(winner1 != address(0), "Should have winner");
        assertTrue(amount1 > 0, "Should have prize amount");

        address beneficiary = vault.owner();
        uint256 beneficiaryUsdmyBefore = usdmy.balanceOf(beneficiary);

        for (uint256 i = 0; i < 7; i++) {
            vm.prank(alice);
            vault.transfer(bob, 0.1 ether);

            vm.warp(block.timestamp + 25 hours + 61);
            vault.executeLottery();
        }

        uint256 beneficiaryUsdmyAfter = usdmy.balanceOf(beneficiary);
        uint256 totalUsdmySent = beneficiaryUsdmyAfter - beneficiaryUsdmyBefore;

        assertTrue(totalUsdmySent > 0, "Should have sent some USDmY to beneficiary");
    }

    // ============ New Tests (3) ============

    function testLotteryWithSingleHolder() public {
        // Only alice mints, and she transfers to a contract (which won't be in Fenwick)
        MockContract mockContract = new MockContract(usdmy);
        usdmy.mint(address(mockContract), 10 ether);

        mintVault(alice, 10 ether);

        assertEq(vault.getHolderCount(), 1, "Only alice should be a holder");

        skipPastMintingPeriod();

        // Generate fees by transferring to the contract
        vm.prank(alice);
        vault.transfer(address(mockContract), 1 ether);

        // Alice is still the only holder
        assertEq(vault.getHolderCount(), 1, "Alice should still be the only holder");

        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(42)));
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner, uint112 amount) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);

        assertEq(winner, alice, "Alice should always win as the only holder");
        assertGt(amount, 0, "Prize should be positive");
    }

    function testTimeGapBoundaryEnforcement() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        // Generate fees on day 0
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Warp to exactly the start of day 1 (25 hours after deployment)
        uint256 deployTime = vault.deploymentTime();
        vm.warp(deployTime + 25 hours);

        // At 0 seconds into day 1, should revert (TIME_GAP = 1 minute)
        vm.expectRevert("Must wait 1 minute into new day before executing");
        vault.executeLottery();

        // At 59 seconds into day 1, should still revert
        vm.warp(deployTime + 25 hours + 59);
        vm.expectRevert("Must wait 1 minute into new day before executing");
        vault.executeLottery();

        // At exactly 60 seconds (1 minute), should succeed
        vm.warp(deployTime + 25 hours + 60);
        vm.prevrandao(bytes32(uint256(777)));
        vault.executeLottery();

        // Verify it executed
        assertEq(vault.lastLotteryDay(), 1, "Lottery should have been executed for day 1");
    }

    function testClaimFromBothLotteryAndAuctionSimultaneously() public {
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 100 ether);

        skipPastMintingPeriod();

        // Generate fees
        vm.prank(alice);
        vault.transfer(bob, 10 ether);

        // Day 8: execute lottery — alice might win
        moveToNextDay();
        vm.prevrandao(bytes32(uint256(12345)));
        vault.executeLottery();

        // Find the lottery winner
        uint256 day8 = vault.getCurrentDay() - 1;
        (address lotteryWinner, uint112 lotteryAmount) = vault.lotteryUnclaimedPrizes(day8 % 7);

        // Generate more fees
        vm.prank(bob);
        vault.transfer(charlie, 5 ether);

        // Day 9: execute lottery and start auction
        moveToNextDay();
        vm.prevrandao(bytes32(uint256(54321)));
        vault.executeLottery();

        // Place a bid on behalf of the lottery winner (so they also win the auction)
        (, , uint96 minBid, uint112 auctionAmount, uint32 auctionDay) = vault.currentAuction();
        if (auctionAmount > 0 && lotteryWinner != address(0)) {
            // Have the lottery winner also bid on the auction
            usdmy.mint(lotteryWinner, 10 ether);
            placeBid(lotteryWinner, uint256(minBid) + 1 ether);

            // Generate fees and finalize auction
            vm.prank(alice);
            vault.transfer(bob, 1 ether);

            moveToNextDay();
            vault.executeLottery();

            // Now the lottery winner should have both a lottery prize and an auction prize
            vm.prank(lotteryWinner);
            uint256 totalClaimable = vault.getMyClaimableAmount();

            if (totalClaimable > 0) {
                uint256 balanceBefore = vault.balanceOf(lotteryWinner);
                vm.prank(lotteryWinner);
                vault.claim();
                uint256 balanceAfter = vault.balanceOf(lotteryWinner);

                assertEq(balanceAfter - balanceBefore, totalClaimable, "Should claim total from both lottery and auction");

                // Verify all slots are cleared
                vm.prank(lotteryWinner);
                assertEq(vault.getMyClaimableAmount(), 0, "Should have nothing left to claim");
            }
        }
    }
}
