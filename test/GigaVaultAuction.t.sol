// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GigaVault} from "../src/GigaVault.sol";

// Mock ERC20 USDmY for testing
contract MockUSDmY {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(
            allowance[from][msg.sender] >= amount,
            "Insufficient allowance"
        );

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }
}

contract GigaVaultAuctionTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public david = address(0x4);

    // Event definitions for testing
    event AuctionStarted(uint256 indexed day, uint256 tokenAmount, uint256 minBid);
    event BidPlaced(address indexed bidder, uint256 amount, uint256 day);
    event BidRefunded(address indexed bidder, uint256 amount);
    event AuctionWon(
        address indexed winner,
        uint256 tokenAmount,
        uint256 collateralPaid,
        uint256 indexed day
    );
    event LotteryWon(address indexed winner, uint256 amount, uint256 indexed day);

    function setUp() public {
        usdmy = new MockUSDmY();
        vault = new GigaVault(address(usdmy));

        // Fund test accounts
        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
        usdmy.mint(charlie, 100 ether);
        usdmy.mint(david, 100 ether);
    }

    // Helper functions
    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    function skipPastMintingPeriod() internal {
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);
    }

    function placeBid(address bidder, uint256 bidAmount) internal {
        vm.startPrank(bidder);
        usdmy.approve(address(vault), bidAmount);
        vault.bid(bidAmount);
        vm.stopPrank();
    }

    function testAuctionWithBidding() public {
        // Generate fees during minting period
        mintVault(alice, 10 ether);

        // Fast forward past minting period
        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);

        // Generate fees via transfer (alice has 9.9 tokens from 10 USDmY mint with 1:1 ratio)
        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        vm.prank(alice);
        bool success = vault.transfer(bob, 1 ether); // Transfer 1 token, 0.01 token fee
        assertTrue(success, "Transfer should succeed");
        assertEq(
            vault.balanceOf(alice),
            aliceBalanceBefore - 1 ether,
            "Alice balance should decrease by 1"
        );
        assertEq(
            vault.balanceOf(bob),
            0.99 ether,
            "Bob should receive 0.99 (1 - 0.01 fee)"
        );

        // Execute lottery/auction
        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        // Get auction details
        (, , uint96 minBid, , ) = vault.currentAuction();

        // Alice bids
        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);
        placeBid(alice, minBid);
        assertEq(
            usdmy.balanceOf(alice),
            aliceUsdmyBefore - minBid,
            "Alice should have spent USDmY"
        );

        // Bob outbids
        uint256 newBid = (minBid * 110) / 100;
        placeBid(bob, newBid);

        // Verify Alice got refunded
        assertEq(
            usdmy.balanceOf(alice),
            aliceUsdmyBefore,
            "Alice should be refunded"
        );

        // Verify Bob is current bidder
        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testAuctionFinalization() public {
        // Generate fees
        mintVault(alice, 10 ether);

        // Fast forward past minting period
        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);

        // Generate fees via transfer
        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        vm.prank(alice);
        bool success = vault.transfer(bob, 1 ether);
        assertTrue(success, "Transfer should succeed");

        // Execute lottery/auction
        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        // Place bid
        (, , uint96 minBid, , ) = vault.currentAuction();
        placeBid(alice, minBid);

        uint256 contractUsdmyBefore = vault.getReserve();
        uint256 escrowedBefore = vault.escrowedBid();
        assertEq(escrowedBefore, minBid, "Contract should have escrowed bid");

        // Generate fees on day 8 for day 9's lottery/auction
        vm.prank(bob);
        vault.transfer(alice, 0.5 ether); // Generate 0.005 token fee

        // Finalize auction
        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        // Verify escrowed bid was added to reserve
        uint256 escrowedAfter = vault.escrowedBid();
        assertEq(escrowedAfter, 0, "Escrow should be empty after finalization");

        // Reserve should have increased by bid amount
        uint256 contractUsdmyAfter = vault.getReserve();
        assertGt(
            contractUsdmyAfter,
            contractUsdmyBefore,
            "Reserve should have increased"
        );
    }

    function testBidIncrementRequirement() public {
        // Setup auction
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        // First bid at minimum
        placeBid(alice, minBid);

        // Try to bid with less than 10% increase
        uint256 lowBid = (minBid * 109) / 100; // 9% increase
        vm.startPrank(bob);
        usdmy.approve(address(vault), lowBid);
        vm.expectRevert("Bid too low");
        vault.bid(lowBid);
        vm.stopPrank();

        // Bid with exactly 10% increase should work
        uint256 validBid = (minBid * 110) / 100;
        placeBid(bob, validBid);

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testNoBidAuctionRollover() public {
        // Generate fees
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Day 8 - Start auction but don't bid (distributes day 7's fees)
        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        // Generate more fees on day 8 for day 9's lottery/auction
        vm.prank(bob);
        vault.transfer(alice, 0.5 ether); // Generate 0.005 token fee

        // Get FEES_POOL balance before rollover
        uint256 feesPoolBefore = vault.balanceOf(vault.FEES_POOL());

        // Day 9 - Previous auction ends without bids, new lottery/auction starts
        vm.warp(block.timestamp + 25 hours + 1 minutes);

        vault.executeLottery();

        // After auction rollover, funds should be back in FEES_POOL
        uint256 feesPoolAfter = vault.balanceOf(vault.FEES_POOL());

        // The rolled over amount from the failed auction goes back to FEES_POOL
        assertTrue(
            feesPoolAfter > 0,
            "FEES_POOL should contain rolled over auction amount"
        );
    }

    function test50_50FeeSplitAfterMintingPeriod() public {
        // Generate tokens during minting
        mintVault(alice, 100 ether); // Alice gets 99 tokens after 1% fee

        // After minting period (day 8 = 8 * 25 hours from start)
        vm.warp(block.timestamp + 8 * 25 hours);

        // Transfer 10 tokens (generates 0.1 token fee)
        vm.prank(alice);
        vault.transfer(bob, 10 ether);
        // Bob got 9.9 tokens (10 - 0.1 fee), transfers some back
        vm.prank(bob);
        vault.transfer(alice, 9 ether); // generates 0.09 token fee

        // Check FEES_POOL balance for accumulated fees
        uint256 totalFees = vault.balanceOf(vault.FEES_POOL());
        // We expect accumulated fees: 1 (from minting) + 0.1 + 0.09 = 1.19 ether
        assertEq(
            totalFees,
            1.19 ether,
            "FEES_POOL should have 1.19 tokens in fees"
        );

        // Execute lottery/auction for the day's fees
        vm.warp(block.timestamp + 25 hours + 1 minutes);

        vault.executeLottery();

        // Verify auction has (100 - LOTTERY_PERCENT)% of fees
        (, , , uint112 auctionAmount, ) = vault.currentAuction();
        uint256 expectedAuctionAmount = (totalFees * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");
    }

    function testMinimumBidCalculation() public {
        // Setup: Create known USDmY balance and total supply
        mintVault(alice, 10 ether); // 9.9 VAULT to alice, 0.1 to fees
        mintVault(bob, 5 ether); // 4.95 VAULT to bob, 0.05 to fees

        // Total supply: 9.9 + 0.1 + 4.95 + 0.05 = 15 VAULT
        // USDmY balance: 15 USDmY
        uint256 expectedTotalSupply = 15 ether;
        uint256 usdmyBalance = 15 ether;
        assertEq(
            vault.totalSupply(),
            expectedTotalSupply,
            "Total supply should be 15 VAULT"
        );
        assertEq(
            vault.getReserve(),
            usdmyBalance,
            "Contract should have 15 USDmY"
        );

        // Move past minting period
        skipPastMintingPeriod();

        // Generate specific amount of fees for auction
        vm.prank(alice);
        vault.transfer(bob, 1 ether); // 0.01 VAULT fee

        // Execute to start auction - fees will be split 50/50 between lottery and auction
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        // Get auction details
        (, , uint96 minBid, uint112 auctionAmount, ) = vault.currentAuction();

        // After transfer: 0.01 VAULT fee generated
        // Split based on LOTTERY_PERCENT: lottery gets LOTTERY_PERCENT%, auction gets rest
        uint256 expectedAuctionAmount = (0.01 ether * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");

        // Calculate expected minimum bid with new formula
        // MinBid = (usdmyBalance * auctionAmount) / (2 * totalSupply)
        uint256 expectedMinBid = (usdmyBalance * auctionAmount) /
            (2 * expectedTotalSupply);

        assertEq(
            minBid,
            expectedMinBid,
            "Minimum bid should match calculated value"
        );

        // Verify that bidding exactly the minimum bid works
        placeBid(alice, minBid);

        (address currentBidder, uint96 currentBid, , , ) = vault
            .currentAuction();
        assertEq(currentBidder, alice, "Alice should be current bidder");
        assertEq(currentBid, minBid, "Current bid should equal minimum bid");

        // Verify bidding below minimum fails
        vm.startPrank(bob);
        usdmy.approve(address(vault), minBid);
        vm.expectRevert("Bid too low");
        vault.bid(minBid - 1);
        vm.stopPrank();
    }

    function testMinimumBidWithDifferentBalances() public {
        // Scenario 1: Low USDmY balance, high supply (deflated token)
        mintVault(alice, 100 ether); // 99 VAULT

        // Burn most tokens to simulate deflation
        skipPastMintingPeriod();
        vm.prank(alice);
        vault.redeem(90 ether); // Burns 89.1 VAULT, returns ~89.1 USDmY

        uint256 remainingSupply = vault.totalSupply();
        uint256 remainingUsdmy = vault.getReserve();

        // Generate fees
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        // Start auction
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid1, uint112 auctionAmount1, ) = vault.currentAuction();

        // Verify minimum bid with new formula
        uint256 expectedMin1 = (remainingUsdmy * auctionAmount1) /
            (2 * remainingSupply);
        assertEq(
            minBid1,
            expectedMin1,
            "Min bid should match expected calculation"
        );

        // Scenario 2: High USDmY balance from donations
        // Someone donates USDmY to increase backing
        usdmy.mint(address(this), 50 ether);
        usdmy.transfer(address(vault), 50 ether);

        // Generate new fees
        vm.prank(alice);
        vault.transfer(bob, 0.5 ether);

        // Start new auction
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid2, uint112 auctionAmount2, ) = vault.currentAuction();

        uint256 currentUsdmy = vault.getReserve();
        uint256 currentSupply = vault.totalSupply();
        uint256 expectedMin2 = (currentUsdmy * auctionAmount2) /
            (2 * currentSupply);

        assertEq(
            minBid2,
            expectedMin2,
            "Min bid should reflect increased USDmY backing"
        );

        // The minimum bid should be higher due to the donation increasing the backing value
        assertTrue(
            minBid2 > minBid1,
            "Higher USDmY backing should result in higher min bid"
        );
    }

    function testMinimumBidFormula() public {
        // Using 3 USDmY to create 3 VAULT total supply
        mintVault(alice, 3 ether); // 2.97 VAULT to alice, 0.03 to fees

        skipPastMintingPeriod();

        // Generate an odd fee amount: 0.007 VAULT
        vm.prank(alice);
        vault.transfer(bob, 0.7 ether); // 0.007 VAULT fee

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        (, , uint96 minBid, uint112 auctionAmount, ) = vault.currentAuction();

        uint256 usdmyBalance = vault.getReserve();
        uint256 totalSupply = vault.totalSupply();

        // The auction should have (100 - LOTTERY_PERCENT)% of 0.007 VAULT
        uint256 expectedAuctionAmount = (0.007 ether * (100 - vault.LOTTERY_PERCENT())) / 100;
        assertEq(auctionAmount, expectedAuctionAmount, "Auction should have correct percentage of fees");

        // Calculate with new formula
        uint256 expectedMinBid = (usdmyBalance * auctionAmount) /
            (2 * totalSupply);

        assertEq(
            minBid,
            expectedMinBid,
            "Minimum bid should match contract calculation"
        );

        // The minimum bid is now half of the redemption value
        uint256 redemptionValue = (auctionAmount * usdmyBalance) / totalSupply;
        assertEq(
            minBid,
            redemptionValue / 2,
            "Min bid should be half of redemption value"
        );
    }

    function testBidRefunds() public {
        // Setup auction
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        // Alice bids
        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);
        placeBid(alice, minBid);
        assertEq(
            usdmy.balanceOf(alice),
            aliceUsdmyBefore - minBid,
            "Alice should have spent USDmY"
        );

        // Bob outbids
        uint256 newBid = (minBid * 110) / 100;
        placeBid(bob, newBid);

        // Verify Alice got refunded in USDmY
        assertEq(
            usdmy.balanceOf(alice),
            aliceUsdmyBefore,
            "Alice should receive USDmY refund"
        );

        // Verify Bob is current bidder
        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testMultipleBidsAndRefunds() public {
        // Setup auction
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

        // Alice bids
        placeBid(alice, minBid);

        // Bob outbids
        uint256 bid2 = (minBid * 110) / 100;
        placeBid(bob, bid2);

        // Charlie outbids
        uint256 bid3 = (bid2 * 110) / 100;
        placeBid(charlie, bid3);

        // David outbids
        uint256 bid4 = (bid3 * 110) / 100;
        placeBid(david, bid4);

        // Verify all previous bidders got refunds
        assertEq(
            usdmy.balanceOf(alice),
            aliceUsdmyBefore,
            "Alice should have USDmY refund"
        );
        assertEq(usdmy.balanceOf(bob), bobUsdmyBefore, "Bob should have USDmY refund");
        assertEq(
            usdmy.balanceOf(charlie),
            charlieUsdmyBefore,
            "Charlie should have USDmY refund"
        );

        // Verify David is the winner
        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, david, "David should be current bidder");
    }

    function testBidTooLow() public {
        // Setup auction
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        // Alice tries to bid below minimum
        vm.startPrank(alice);
        usdmy.approve(address(vault), minBid);
        vm.expectRevert("Bid too low");
        vault.bid(minBid - 1);
        vm.stopPrank();

        // Verify no bid was placed
        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, address(0), "Should have no bidder");
    }

    function testAuctionFinalizationWithWinner() public {
        // Setup auction
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, uint112 auctionAmount, ) = vault.currentAuction();

        // Alice bids
        placeBid(alice, minBid);

        uint256 escrowedBefore = vault.escrowedBid();
        assertEq(
            escrowedBefore,
            minBid,
            "Contract should have escrowed Alice's bid"
        );

        // Generate fees for next day
        vm.prank(bob);
        vault.transfer(alice, 0.5 ether);

        // Finalize auction by triggering next day's lottery
        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        // Verify escrowed was cleared
        assertEq(
            vault.escrowedBid(),
            0,
            "Contract should have no escrowed USDmY after finalization"
        );

        // Verify Alice won the auction and has claimable prize (at least the auction amount)
        vm.prank(alice);
        uint256 claimable = vault.getMyClaimableAmount();
        assertGe(
            claimable,
            auctionAmount,
            "Alice should have at least the auction prize claimable"
        );

        // Verify Alice can actually claim her prize
        uint256 aliceBalanceBefore = vault.balanceOf(alice);
        vm.prank(alice);
        vault.claim();
        uint256 aliceBalanceAfter = vault.balanceOf(alice);

        assertEq(
            aliceBalanceAfter - aliceBalanceBefore,
            claimable,
            "Alice should receive her claimable amount"
        );
    }

    function testBidIncrementAfterFirstBid() public {
        // Test that 10% increment rule applies after first bid
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        // Alice bids at minimum
        placeBid(alice, minBid);

        // Bob tries to bid with only 9% increase
        uint256 lowBid = (minBid * 109) / 100;
        vm.startPrank(bob);
        usdmy.approve(address(vault), lowBid);
        vm.expectRevert("Bid too low");
        vault.bid(lowBid);
        vm.stopPrank();

        // Bob bids with exactly 10% increase
        uint256 validBid = (minBid * 110) / 100;
        placeBid(bob, validBid);

        // Verify Bob is now the current bidder
        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, bob, "Bob should be current bidder");
    }

    function testEscrowAccountingCorrectness() public {
        // Test that escrow accounting is correct
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

        // Alice bids
        placeBid(alice, minBid);

        // Reserve should not change (bid goes to escrow, not reserve)
        // Actually the total USDmY balance increases but escrow increases too
        uint256 reserveAfter = vault.getReserve();
        uint256 escrowAfter = vault.escrowedBid();

        assertEq(
            escrowAfter,
            escrowBefore + minBid,
            "Escrow should increase by bid amount"
        );
        assertEq(
            reserveAfter,
            reserveBefore,
            "Reserve should remain unchanged"
        );

        // Verify the bid amount matches escrow
        (, uint96 currentBid, , , ) = vault.currentAuction();
        assertEq(
            escrowAfter,
            currentBid,
            "Escrow should match bid amount"
        );
    }
}

// Test specifically for DoS prevention
contract MaliciousBidder {
    receive() external payable {
        revert("I always revert!");
    }

    fallback() external payable {
        revert("I always revert!");
    }
}

contract GigaVaultAuctionSecurityTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;
    address public alice = address(0x1);
    address public maliciousBidder;

    function setUp() public {
        usdmy = new MockUSDmY();
        vault = new GigaVault(address(usdmy));

        usdmy.mint(alice, 100 ether);

        MaliciousBidder malicious = new MaliciousBidder();
        maliciousBidder = address(malicious);
        usdmy.mint(maliciousBidder, 100 ether);
    }

    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    function skipPastMintingPeriod() internal {
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);
    }

    function testRefundDoSPrevention() public {
        // Setup auction
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        vault.transfer(address(0x99), 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();

        (, , uint96 minBid, , ) = vault.currentAuction();

        // Malicious bidder places bid
        vm.startPrank(maliciousBidder);
        usdmy.approve(address(vault), minBid);
        vault.bid(minBid);
        vm.stopPrank();

        // Alice can still outbid - refund goes as ERC20 transfer which works fine
        uint256 newBid = (minBid * 110) / 100;
        vm.startPrank(alice);
        usdmy.approve(address(vault), newBid);
        vault.bid(newBid); // This should succeed
        vm.stopPrank();

        // Verify malicious bidder got USDmY refund (ERC20 transfer doesn't use receive())
        assertEq(
            usdmy.balanceOf(maliciousBidder),
            100 ether,
            "Should receive USDmY refund"
        );

        (address currentBidder, , , , ) = vault.currentAuction();
        assertEq(currentBidder, alice, "Alice should be current bidder");
    }
}
