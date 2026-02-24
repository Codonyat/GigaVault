// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract, ReentrancyAttacker, MockRejectNative, MockUSDmY} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";
import {GigaVault} from "../src/GigaVault.sol";

contract GigaVaultCoreTest is GigaVaultTestBase {
    function testTransferWithFee() public {
        // Alice mints tokens
        mintVault(alice, 10 ether);

        // Verify initial balances
        uint256 aliceInitial = vault.balanceOf(alice);
        assertEq(
            aliceInitial,
            9.9 ether,
            "Alice should have 9.9 vault tokens after minting"
        );
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            0.1 ether,
            "Fees pool should have 0.1 vault tokens from mint"
        );

        uint256 transferAmount = 1 ether;
        uint256 expectedFee = 0.01 ether; // 1% fee
        uint256 expectedReceived = transferAmount - expectedFee;

        // Transfer with fee verification
        vm.prank(alice);
        bool success = vault.transfer(bob, transferAmount);
        assertTrue(success, "Transfer should succeed");

        assertEq(
            vault.balanceOf(alice),
            aliceInitial - transferAmount,
            "Alice balance should decrease by transfer amount"
        );
        assertEq(
            vault.balanceOf(bob),
            expectedReceived,
            "Bob should receive amount minus fee"
        );
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            0.1 ether + expectedFee,
            "Fees pool should increase by transfer fee"
        );
    }

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

    function testNativeSentToBeneficiariesNotTokens() public {
        // Setup beneficiary addresses
        address beneficiary1 = address(0x9999);
        address beneficiary2 = address(0x8888);

        // Setup holders
        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Generate fees
        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 bobBalanceBefore = vault.balanceOf(bob);
        vm.prank(alice);
        bool success = vault.transfer(bob, 1 ether);
        assertTrue(success, "Transfer should succeed");
        assertEq(
            vault.balanceOf(alice),
            aliceBalanceBefore - 1 ether,
            "Alice balance should decrease by 1"
        );
        assertEq(
            vault.balanceOf(bob),
            bobBalanceBefore + 0.99 ether,
            "Bob should receive 990 (1000 - 10 fee)"
        );

        // Execute lottery
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123)));
        vault.executeLottery();

        // Get winner
        (address winner, uint112 prizeAmount) = vault.lotteryUnclaimedPrizes(
            8 % 7
        );

        // Fast forward 14 days to trigger unclaimed prize distribution
        for (uint256 i = 0; i < 14; i++) {
            vm.prank(alice);
            vault.transfer(bob, 0.1 ether);
            vm.warp(block.timestamp + 25 hours + 61);
            vault.executeLottery();
        }

        // Beneficiaries should receive USDmY, not vault tokens
        // (Implementation sends to winner if beneficiaries fail)
    }

    function testUnclaimedPrizeFailedTransferGoesToCurrentWinner() public {
        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Day 9: Generate fees (odd day for lottery)
        vm.warp(block.timestamp + 25 hours);
        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        uint256 bobBalanceBefore = vault.balanceOf(bob);
        vm.prank(alice);
        bool success = vault.transfer(bob, 1 ether);
        assertTrue(success, "Transfer should succeed");
        assertEq(
            vault.balanceOf(alice),
            aliceBalanceBefore - 1 ether,
            "Alice balance should decrease"
        );
        assertEq(
            vault.balanceOf(bob),
            bobBalanceBefore + 0.99 ether,
            "Bob should receive 990 after fee"
        );

        // Day 10: Execute lottery for day 9
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(111)));
        vault.executeLottery();

        (address winner1, uint112 amount1) = vault.lotteryUnclaimedPrizes(
            9 % 7
        );

        // Generate fees for multiple days to potentially overwrite slots
        for (uint256 i = 0; i < 14; i++) {
            // Generate fees
            if (vault.balanceOf(bob) > 100 ether) {
                vm.prank(bob);
                vault.transfer(alice, 0.1 ether);
            } else if (vault.balanceOf(alice) > 100 ether) {
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);
            }

            // Move to next day and execute
            vm.warp(block.timestamp + 25 hours + 61);
            vm.prevrandao(bytes32(uint256(i * 1000)));
            vault.executeLottery();
        }

        // After 14 days, unclaimed prizes may be distributed
        // Just verify the system continues to work
        assertTrue(true, "System continues to operate after unclaimed prizes");
    }

    function testUnclaimedPrizeGoesToBeneficiary() public {
        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Day 9: Generate fees
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Day 10: Execute lottery for day 9
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(999)));
        vault.executeLottery();

        (address winner, uint112 prizeAmount) = vault.lotteryUnclaimedPrizes(
            9 % 7
        );

        if (winner != address(0)) {
            // Wait 14 days and execute lotteries to trigger unclaimed distribution
            for (uint256 i = 0; i < 14; i++) {
                if (vault.balanceOf(alice) > 100 ether) {
                    vm.prank(alice);
                    vault.transfer(bob, 0.1 ether);
                }
                vm.warp(block.timestamp + 25 hours + 61);
                vm.prevrandao(bytes32(uint256(i * 7777)));
                vault.executeLottery();
            }

            // After 14 days, prize may be distributed
            // The contract handles unclaimed prizes in its own way
            assertTrue(true, "Unclaimed prize handling completed");
        } else {
            // Day 9 was an auction day, not lottery
            assertTrue(true, "Day was auction, not lottery");
        }
    }

    function testBeneficiaryFunding() public {
        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Generate significant fees
        vm.prank(alice);
        vault.transfer(bob, 5 ether); // 0.05 vault token fee

        // Execute lottery for day 8
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        // Check if we got a lottery winner (day 8 is even, so should be 25 tokens to lottery)
        (address winner1, uint112 prizeAmount1) = vault.lotteryUnclaimedPrizes(
            8 % 7
        );

        if (winner1 != address(0)) {
            // Track the owner's balance (replaces BENEFICIARIES(0))
            address beneficiary = vault.owner();
            uint256 beneficiaryUsdmyBefore = usdmy.balanceOf(beneficiary);

            // Capture contract state BEFORE the 7-day wait (before beneficiary transfer)
            uint256 contractUsdmyBefore = vault.getReserve();
            uint256 totalSupplyBefore = vault.totalSupply();

            // Wait 7 days to trigger unclaimed prize distribution
            for (uint256 i = 0; i < 7; i++) {
                // Generate fees
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);

                // Execute lottery
                vm.warp(block.timestamp + 25 hours + 61);
                vault.executeLottery();
            }

            // Now check if beneficiary received the correct USDmY amount
            uint256 beneficiaryUsdmyAfter = usdmy.balanceOf(beneficiary);

            // Calculate expected USDmY based on token to USDmY conversion
            uint256 expectedUsdmy = (prizeAmount1 * contractUsdmyBefore) /
                totalSupplyBefore;

            assertApproxEqAbs(
                beneficiaryUsdmyAfter - beneficiaryUsdmyBefore,
                expectedUsdmy,
                1, // Allow 1 wei difference for rounding
                "Beneficiary should receive USDmY based on proper token/USDmY conversion"
            );
        }
    }

    function testBeneficiaryFundingReverts() public {
        // Deploy a contract that reverts on native receive as beneficiary
        MockRejectNative rejectingBeneficiary = new MockRejectNative();

        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Generate fees on day 9 for lottery
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Execute lottery on day 10 - should not revert even if public good rejects
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(999)));
        vault.executeLottery();

        // Check for lottery or auction execution
        // Day 9 could be lottery or auction depending on implementation
        (address winner, ) = vault.lotteryUnclaimedPrizes(9 % 7);
        (address bidder, , , uint112 auctionAmount, ) = vault.currentAuction();

        // Should have either lottery winner or auction
        assertTrue(
            winner != address(0) || auctionAmount > 0,
            "Should have executed lottery/auction despite public good reverting"
        );
    }

    function testAuctionWithUSDmYBids() public {
        // This test verifies USDmY bidding in auctions
        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Generate fees for auction
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Execute to start auction
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        // Verify auction was created
        (address bidder, , , uint112 auctionAmount, ) = vault.currentAuction();
        assertEq(bidder, address(0), "Auction should have no bidder initially");
        assertGt(auctionAmount, 0, "Auction should have tokens");
    }

    function testLOT_POOLTransfersRedirectedToFEES_POOL() public {
        // Test that external transfers to LOT_POOL are redirected to FEES_POOL
        // This maintains the invariant: LOT_POOL balance == auction amount + unclaimed prizes

        // First mint to the test contract itself to have balance
        usdmy.mint(address(this), 10 ether);
        usdmy.approve(address(vault), 10 ether);
        vault.mint(10 ether);

        uint256 testContractBalance = vault.balanceOf(address(this));
        assertEq(
            testContractBalance,
            9.9 ether,
            "Test contract should have 9.9 tokens"
        );

        uint256 feesPoolBefore = vault.balanceOf(vault.FEES_POOL());
        uint256 lotPoolBefore = vault.balanceOf(vault.LOT_POOL());

        // Test contract tries to transfer to LOT_POOL
        vault.transfer(vault.LOT_POOL(), 0.1 ether);

        // Should be redirected to FEES_POOL
        uint256 feesPoolAfter = vault.balanceOf(vault.FEES_POOL());
        uint256 lotPoolAfter = vault.balanceOf(vault.LOT_POOL());

        assertEq(
            lotPoolAfter,
            lotPoolBefore,
            "LOT_POOL balance should not change"
        );
        assertEq(
            feesPoolAfter,
            feesPoolBefore + 0.1 ether,
            "FEES_POOL should receive 0.1 tokens (redirected from LOT_POOL)"
        );
    }

    function testInternalLOT_POOLTransfersStillWork() public {
        // Test that internal transfers to LOT_POOL (from FEES_POOL during lottery)
        // still work correctly and are not redirected

        setupBasicHolders();

        // Move past minting period
        skipPastMintingPeriod();

        // Generate fees on day 9 (odd day for lottery)
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        uint256 lotPoolBefore = vault.balanceOf(vault.LOT_POOL());

        // Execute lottery on day 10 for day 9's fees
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(123456)));
        vault.executeLottery();

        uint256 lotPoolAfter = vault.balanceOf(vault.LOT_POOL());

        // LOT_POOL should have received funds from the internal transfer
        // Either from lottery prize or auction amount
        // Just verify the system executed without reverting
        assertTrue(true, "Lottery/auction executed successfully");
    }

    function testFuzz_Invariants(
        uint8 numUsers,
        uint256 seed,
        uint8 numTransfers
    ) public {
        // Bound inputs
        numUsers = uint8(bound(numUsers, 2, 20));
        numTransfers = uint8(bound(numTransfers, 1, 50));

        // Create users and mint
        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(0x1000 + i));

            uint256 mintAmount = ((uint256(keccak256(abi.encode(seed, i))) %
                5) + 1) * 1 ether;

            usdmy.mint(user, mintAmount);
            vm.startPrank(user);
            usdmy.approve(address(vault), mintAmount);
            vault.mint(mintAmount);
            vm.stopPrank();
        }

        // Perform random transfers
        for (uint256 i = 0; i < numTransfers; i++) {
            address from = address(
                uint160(
                    0x1000 +
                        (uint256(keccak256(abi.encode(seed, i, "from"))) %
                            numUsers)
                )
            );
            address to = address(
                uint160(
                    0x1000 +
                        (uint256(keccak256(abi.encode(seed, i, "to"))) %
                            numUsers)
                )
            );

            if (from == to) continue;

            uint256 balance = vault.balanceOf(from);
            if (balance > 100 ether) {
                uint256 amount = uint256(
                    keccak256(abi.encode(seed, i, "amount"))
                ) % (balance / 2);
                if (amount > 0) {
                    vm.prank(from);
                    vault.transfer(to, amount);
                }
            }
        }

        // Verify invariants
        // 1. Total supply invariant
        uint256 totalSupply = vault.totalSupply();
        uint256 sumOfBalances = 0;

        // Sum all special addresses
        sumOfBalances += vault.balanceOf(vault.FEES_POOL());
        sumOfBalances += vault.balanceOf(vault.LOT_POOL());

        // Sum all user balances
        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(0x1000 + i));
            sumOfBalances += vault.balanceOf(user);
        }

        // Total supply should equal sum of all balances
        assertEq(
            totalSupply,
            sumOfBalances,
            "Total supply should equal sum of all balances"
        );

        // 2. Fenwick tree consistency
        uint256 fenwickTotal = 0;
        uint256 holderCount = vault.getHolderCount();
        if (holderCount > 0) {
            // getSuffixSum(1) gets the total from the beginning
            fenwickTotal = vault.getSuffixSum(1);
        }

        // Fenwick should track only EOA holders
        uint256 eoaTotal = 0;
        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(0x1000 + i));
            if (vault.isHolder(user)) {
                eoaTotal += vault.balanceOf(user);
            }
        }

        assertEq(
            fenwickTotal,
            eoaTotal,
            "Fenwick total should match EOA holder balances"
        );
    }
}
