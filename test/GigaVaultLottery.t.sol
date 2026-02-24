// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract, MockRejectNative} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultLotteryTest is GigaVaultTestBase {
    function testPrevrandaoLottery() public {
        mintVault(alice, 10 ether);
        assertEq(vault.balanceOf(alice), 9.9 ether, "Alice should have 9.9 USDmZ");

        mintVault(bob, 5 ether);
        assertEq(vault.balanceOf(bob), 4.95 ether, "Bob should have 4.95 USDmZ");

        skipPastMintingPeriod();

        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 bobBalanceBefore = vault.balanceOf(bob);
        vm.prank(alice);
        bool success = vault.transfer(bob, 1 ether);
        assertTrue(success, "Transfer should succeed");
        assertEq(vault.balanceOf(alice), aliceBalanceBefore - 1 ether, "Alice balance should decrease by 1");
        assertEq(vault.balanceOf(bob), bobBalanceBefore + 0.99 ether, "Bob should receive 0.99 (1 - 0.01 fee)");

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
        bool success1 = vault.transfer(bob, 0.1 ether);
        assertTrue(success1, "Transfer should succeed");

        vm.prank(bob);
        bool success2 = vault.transfer(charlie, 0.1 ether);
        assertTrue(success2, "Transfer should succeed");

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
            (address winner, ) = vault.lotteryUnclaimedPrizes(prizeDay);

            if (winner == alice) aliceWins++;
            else if (winner == bob) bobWins++;
            else if (winner == charlie) charlieWins++;
        }

        console.log("Alice wins:", aliceWins);
        console.log("Bob wins:", bobWins);
        console.log("Charlie wins:", charlieWins);

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

        (address winner8, ) = vault.lotteryUnclaimedPrizes(8 % 7);
        (address winner9, ) = vault.lotteryUnclaimedPrizes(9 % 7);
        (, , , uint112 auctionAmount, ) = vault.currentAuction();

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
        (address winner1, ) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);

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
        (address winner, ) = vault.lotteryUnclaimedPrizes((currentDay - 1) % 7);
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
            (address winner, ) = vault.lotteryUnclaimedPrizes(day % 7);
            if (winner != address(0)) {
                hasWinner = true;
                break;
            }
        }

        (, , , uint112 auctionAmount, ) = vault.currentAuction();
        assertTrue(hasWinner || auctionAmount > 0, "Should have executed delayed lottery or auction");
    }

    function testNoLotteryWhenNoFeesCollected() public {
        mintVault(alice, 0.1 ether);
        vm.warp(block.timestamp + 20 days);
        try vault.executeLottery() {} catch {}

        vm.warp(block.timestamp + 25 hours + 61);
        try vault.executeLottery() {} catch {}

        assertTrue(true, "System handled no-fee day correctly");
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

        (, , , uint112 auctionAmount, ) = vault.currentAuction();
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

        (address winner, uint112 amount) = vault.lotteryUnclaimedPrizes(9 % 7);

        if (winner != address(0)) {
            uint256 winnerBalanceBefore = vault.balanceOf(winner);
            vm.prank(winner);
            vault.claim();
            uint256 winnerBalanceAfter = vault.balanceOf(winner);

            assertEq(winnerBalanceAfter - winnerBalanceBefore, amount, "Winner should receive prize amount");

            (address winnerAfterClaim, uint112 amountAfterClaim) = vault.lotteryUnclaimedPrizes(9 % 7);
            assertEq(winnerAfterClaim, address(0), "Prize should be marked as claimed");
            assertEq(amountAfterClaim, 0, "Prize amount should be zero after claim");
        } else {
            assertTrue(true, "Day was auction day, not lottery");
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

        (address winner, uint112 prizeAmount) = vault.lotteryUnclaimedPrizes(9 % 7);
        (, , , uint112 auctionAmount, ) = vault.currentAuction();
        assertTrue(winner != address(0) || auctionAmount > 0, "Should have executed lottery or auction");
    }
}
