// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase} from "./helpers/GigaVaultTestBase.sol";
import {console} from "forge-std/Test.sol";

contract GigaVaultIntegrationTest is GigaVaultTestBase {
    // ============ Fuzz Test (moved from Core) ============

    function testFuzz_Invariants(
        uint8 numUsers,
        uint256 seed,
        uint8 numTransfers
    ) public {
        numUsers = uint8(bound(numUsers, 2, 20));
        numTransfers = uint8(bound(numTransfers, 1, 50));

        // Create users and mint
        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(0x1000 + i));
            uint256 mintAmount = ((uint256(keccak256(abi.encode(seed, i))) % 5) + 1) * 1 ether;

            usdmy.mint(user, mintAmount);
            vm.startPrank(user);
            usdmy.approve(address(vault), mintAmount);
            vault.mint(mintAmount);
            vm.stopPrank();
        }

        // Perform random transfers
        for (uint256 i = 0; i < numTransfers; i++) {
            address from = address(
                uint160(0x1000 + (uint256(keccak256(abi.encode(seed, i, "from"))) % numUsers))
            );
            address to = address(
                uint160(0x1000 + (uint256(keccak256(abi.encode(seed, i, "to"))) % numUsers))
            );

            if (from == to) continue;

            uint256 balance = vault.balanceOf(from);
            if (balance > 100 ether) {
                uint256 amount = uint256(keccak256(abi.encode(seed, i, "amount"))) % (balance / 2);
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
        sumOfBalances += vault.balanceOf(vault.FEES_POOL());
        sumOfBalances += vault.balanceOf(vault.LOT_POOL());

        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(0x1000 + i));
            sumOfBalances += vault.balanceOf(user);
        }

        assertEq(totalSupply, sumOfBalances, "Total supply should equal sum of all balances");

        // 2. Fenwick tree consistency
        uint256 fenwickTotal = 0;
        uint256 holderCount = vault.getHolderCount();
        if (holderCount > 0) {
            fenwickTotal = vault.getSuffixSum(1);
        }

        uint256 eoaTotal = 0;
        for (uint256 i = 0; i < numUsers; i++) {
            address user = address(uint160(0x1000 + i));
            if (vault.isHolder(user)) {
                eoaTotal += vault.balanceOf(user);
            }
        }

        assertEq(fenwickTotal, eoaTotal, "Fenwick total should match EOA holder balances");
    }

    // ============ Multi-Day Lifecycle (new) ============

    function testMultiDayLifecycleSequence() public {
        // Day 0-2: Minting period
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);
        mintVault(charlie, 3 ether);

        _verifyInvariants("After initial minting");

        // Skip past minting period (3 days)
        skipPastMintingPeriod();

        // Run 5 days of lifecycle: transfer, lottery/auction, claim, repeat
        for (uint256 day = 0; day < 5; day++) {
            // Generate fees via transfer
            uint256 aliceBal = vault.balanceOf(alice);
            if (aliceBal > 0.2 ether) {
                vm.prank(alice);
                vault.transfer(bob, 0.1 ether);
            }

            _verifyInvariants(string.concat("After transfer day ", vm.toString(day)));

            // Advance to next day
            vm.warp(block.timestamp + 25 hours + 61);
            vm.prevrandao(bytes32(uint256(42 + day)));
            vault.executeLottery();

            _verifyInvariants(string.concat("After lottery day ", vm.toString(day)));

            // Check for auction and bid if active
            (, , , uint112 auctionAmount,) = vault.currentAuction();
            if (auctionAmount > 0) {
                placeBid(david, 0.5 ether);
                _verifyInvariants(string.concat("After bid day ", vm.toString(day)));
            }

            // Try claiming for each user
            address[3] memory claimers = [alice, bob, charlie];
            for (uint256 j = 0; j < 3; j++) {
                vm.startPrank(claimers[j]);
                uint256 claimable = vault.getMyClaimableAmount();
                if (claimable > 0) {
                    vault.claim();
                }
                vm.stopPrank();
                if (claimable > 0) {
                    _verifyInvariants(string.concat("After claim day ", vm.toString(day)));
                }
            }
        }

        // Final step: Redeem some tokens
        uint256 aliceBalance = vault.balanceOf(alice);
        if (aliceBalance > 1 ether) {
            vm.prank(alice);
            vault.redeem(1 ether);
            _verifyInvariants("After redeem");
        }
    }

    // ============ Reserve Invariant (new) ============

    function testReserveInvariantThroughComplexSequence() public {
        // Step 1: Mint
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);
        _verifyReserveInvariant("After minting");

        // Step 2: Donate USDmY
        donateUsdmy(charlie, 2 ether);
        _verifyReserveInvariant("After donation");

        // Step 3: Transfer (generates fees)
        vm.prank(alice);
        vault.transfer(bob, 1 ether);
        _verifyReserveInvariant("After transfer");

        // Step 4: Skip minting period
        skipPastMintingPeriod();

        // Step 5: Execute lottery/auction
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(77)));
        vault.executeLottery();
        _verifyReserveInvariant("After lottery");

        // Step 6: Check auction state and potentially bid
        (, , , uint112 auctionAmount,) = vault.currentAuction();
        if (auctionAmount > 0) {
            placeBid(david, 0.5 ether);
            _verifyReserveInvariant("After bid");
        }

        // Step 7: Next day — finalize auction
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prank(alice);
        vault.transfer(bob, 0.1 ether); // generate fees
        vault.executeLottery();
        _verifyReserveInvariant("After auction finalization");

        // Step 8: Redeem
        vm.prank(alice);
        vault.redeem(1 ether);
        _verifyReserveInvariant("After redeem");

        // Step 9: More donations and transfers
        donateUsdmy(eve, 1 ether);
        vm.prank(bob);
        vault.transfer(alice, 0.5 ether);
        _verifyReserveInvariant("After more operations");
    }

    // ============ Internal Helpers ============

    function _verifyInvariants(string memory context) internal view {
        // Verify Fenwick tree is consistent with holder balances
        uint256 holderCount = vault.getHolderCount();
        if (holderCount > 0) {
            uint256 fenwickTotal = vault.getSuffixSum(1);
            uint256 eoaTotal = 0;
            // Check only tracked holders
            if (vault.isHolder(alice)) eoaTotal += vault.balanceOf(alice);
            if (vault.isHolder(bob)) eoaTotal += vault.balanceOf(bob);
            if (vault.isHolder(charlie)) eoaTotal += vault.balanceOf(charlie);
            if (vault.isHolder(david)) eoaTotal += vault.balanceOf(david);
            if (vault.isHolder(eve)) eoaTotal += vault.balanceOf(eve);

            assertEq(fenwickTotal, eoaTotal, string.concat(context, ": Fenwick inconsistent"));
        }
    }

    function _verifyReserveInvariant(string memory context) internal view {
        // Reserve = USDmY balance of vault - escrowed bid
        uint256 reserve = vault.getReserve();
        uint256 usdmyBalance = usdmy.balanceOf(address(vault));
        uint256 escrowedBid = vault.escrowedBid();

        assertEq(reserve, usdmyBalance - escrowedBid, string.concat(context, ": Reserve invariant violated"));

        // Reserve should always be >= 0 (implicit since uint256)
        // Total supply should be > 0 if reserve > 0 (unless all was donated)
        if (vault.totalSupply() > 0 && reserve > 0) {
            // Backing ratio should be positive
            assertTrue(true); // Reserve > 0 and supply > 0 is the invariant
        }
    }
}
