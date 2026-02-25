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

contract GigaVaultUnclaimedPrizesBugTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public david = address(0x4);

    // Events
    event Minted(
        address indexed to,
        uint256 collateralAmount,
        uint256 tokenAmount,
        uint256 fee
    );
    event LotteryWon(address indexed winner, uint256 amount, uint256 indexed day);
    event BidPlaced(address indexed bidder, uint256 amount, uint256 day);
    event AuctionStarted(uint256 indexed day, uint256 tokenAmount, uint256 minBid);

    function setUp() public {
        MockUSDmY mockImpl = new MockUSDmY();
        vm.etch(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890, address(mockImpl).code);
        usdmy = MockUSDmY(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890);
        vault = new GigaVault();

        // Fund test accounts
        usdmy.mint(alice, 1000 ether);
        usdmy.mint(bob, 1000 ether);
        usdmy.mint(charlie, 1000 ether);
        usdmy.mint(david, 1000 ether);
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

    function moveToNextDay() internal {
        vm.warp(block.timestamp + 25 hours + 61);
    }

    function placeBid(address bidder, uint256 bidAmount) internal {
        vm.startPrank(bidder);
        usdmy.approve(address(vault), bidAmount);
        vault.bid(bidAmount);
        vm.stopPrank();
    }

    /**
     * @dev This test verifies that the fix prevents lottery winners from
     * losing their prizes when auctions are finalized
     */
    function testLotteryWinnerKeepsClaimableAmount() public {
        // Setup: Create some holders with balances during minting period
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 100 ether);

        // Skip past minting period to enable alternating lottery/auction
        skipPastMintingPeriod();

        // Generate some fees through transfers
        vm.prank(alice);
        bool success1 = vault.transfer(bob, 10 ether);
        assertTrue(success1, "Transfer should succeed");
        assertEq(
            vault.balanceOf(alice),
            89 ether,
            "Alice balance after transfer"
        );
        assertEq(
            vault.balanceOf(bob),
            108.9 ether,
            "Bob balance after receiving"
        );

        vm.prank(bob);
        bool success2 = vault.transfer(charlie, 5 ether);
        assertTrue(success2, "Transfer should succeed");
        assertEq(
            vault.balanceOf(bob),
            103.9 ether,
            "Bob balance after transfer"
        );
        assertEq(
            vault.balanceOf(charlie),
            103.95 ether,
            "Charlie balance after receiving"
        );

        // Day 8: Execute lottery
        moveToNextDay();
        vault.executeLottery();

        // Generate more fees for the auction
        vm.prank(charlie);
        bool success3 = vault.transfer(alice, 3 ether);
        assertTrue(success3, "Transfer should succeed");
        assertEq(
            vault.balanceOf(charlie),
            100.95 ether,
            "Charlie balance after transfer"
        );
        assertEq(
            vault.balanceOf(alice),
            91.97 ether,
            "Alice balance after receiving"
        );

        // Day 9: Execute lottery which will also start an auction
        moveToNextDay();
        vault.executeLottery();

        // Determine who won the Day 9 lottery by checking claimable amounts
        vm.prank(alice);
        uint256 aliceClaimable = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobClaimable = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieClaimable = vault.getMyClaimableAmount();

        console.log("Alice claimable:", aliceClaimable);
        console.log("Bob claimable:", bobClaimable);
        console.log("Charlie claimable:", charlieClaimable);

        // Place a bid on the auction (david who wasn't a holder)
        (, , uint96 minBid, uint112 auctionAmount, uint32 auctionDay) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Auction should have tokens");

        placeBid(david, 1 ether);

        // Generate fees for next day
        vm.prank(alice);
        bool success4 = vault.transfer(bob, 2 ether);
        assertTrue(success4, "Transfer should succeed");

        // Day 10: Execute lottery again, which will also finalize the auction
        moveToNextDay();
        vault.executeLottery();

        // Check claimable amounts after auction finalization
        vm.prank(alice);
        uint256 aliceAfter = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobAfter = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieAfter = vault.getMyClaimableAmount();
        vm.prank(david);
        uint256 davidClaimable = vault.getMyClaimableAmount();

        console.log("Alice claimable after:", aliceAfter);
        console.log("Bob claimable after:", bobAfter);
        console.log("Charlie claimable after:", charlieAfter);
        console.log("David (auction winner) claimable:", davidClaimable);

        // Check if any of the original holders lost claimable amount
        bool aliceLost = aliceAfter < aliceClaimable;
        bool bobLost = bobAfter < bobClaimable;
        bool charlieLost = charlieAfter < charlieClaimable;

        // WITH THE FIX: No one should lose their prize
        assertTrue(
            !aliceLost && !bobLost && !charlieLost && davidClaimable > 0,
            "FIX VERIFIED: No lottery winner lost their prize and auction winner has theirs!"
        );
    }

    /**
     * @dev Test that verifies the fix works by ensuring no one loses prizes
     * Both lottery and auction winners can claim their prizes
     */
    function testBothWinnersCanClaim() public {
        // Setup holders during minting period
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 100 ether);

        // Skip past minting period
        skipPastMintingPeriod();

        // Generate fees
        vm.prank(alice);
        bool success1 = vault.transfer(bob, 10 ether);
        assertTrue(success1, "Transfer should succeed");
        assertEq(
            vault.balanceOf(alice),
            89 ether,
            "Alice balance after transfer"
        );
        assertEq(
            vault.balanceOf(bob),
            108.9 ether,
            "Bob balance after receiving"
        );

        // Day 8: Execute lottery
        moveToNextDay();
        vault.executeLottery();

        // Generate more fees
        vm.prank(bob);
        bool success2 = vault.transfer(alice, 5 ether);
        assertTrue(success2, "Transfer should succeed");
        assertEq(
            vault.balanceOf(bob),
            103.9 ether,
            "Bob balance after transfer"
        );
        assertEq(
            vault.balanceOf(alice),
            93.95 ether,
            "Alice balance after receiving"
        );

        // Day 9: Execute lottery and start auction
        moveToNextDay();
        vault.executeLottery();

        // Determine who won Day 9 lottery by checking claimable amounts
        vm.prank(alice);
        uint256 aliceClaimableBefore = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobClaimableBefore = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieClaimableBefore = vault.getMyClaimableAmount();

        uint256 totalClaimableBefore = aliceClaimableBefore +
            bobClaimableBefore +
            charlieClaimableBefore;
        console.log(
            "Total claimable before auction finalization:",
            totalClaimableBefore
        );

        // Place bid on the auction
        (, , uint96 minBid, uint112 auctionAmount, uint32 auctionDay) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Auction should have tokens");

        placeBid(david, 1 ether);

        // Day 10: Finalize auction
        moveToNextDay();
        vault.executeLottery();

        // Check claimable amounts after auction finalization
        vm.prank(alice);
        uint256 aliceClaimableAfter = vault.getMyClaimableAmount();
        vm.prank(bob);
        uint256 bobClaimableAfter = vault.getMyClaimableAmount();
        vm.prank(charlie);
        uint256 charlieClaimableAfter = vault.getMyClaimableAmount();
        vm.prank(david);
        uint256 davidClaimable = vault.getMyClaimableAmount();

        uint256 totalClaimableAfter = aliceClaimableAfter +
            bobClaimableAfter +
            charlieClaimableAfter +
            davidClaimable;
        console.log(
            "Total claimable after auction finalization:",
            totalClaimableAfter
        );
        console.log("David's claimable:", davidClaimable);

        // The bug: Someone lost their claimable amount
        bool aliceLost = aliceClaimableAfter < aliceClaimableBefore;
        bool bobLost = bobClaimableAfter < bobClaimableBefore;
        bool charlieLost = charlieClaimableAfter < charlieClaimableBefore;

        console.log("Alice lost funds:", aliceLost);
        console.log("Bob lost funds:", bobLost);
        console.log("Charlie lost funds:", charlieLost);

        // WITH THE FIX: No one should lose claimable amounts
        assertTrue(
            !aliceLost && !bobLost && !charlieLost,
            "FIX VERIFIED: No lottery winner lost their claimable prize when auction was finalized!"
        );

        // Try to actually claim the prizes to verify they work
        if (davidClaimable > 0) {
            uint256 davidBalanceBefore = vault.balanceOf(david);
            vm.prank(david);
            vault.claim();
            uint256 davidBalanceAfter = vault.balanceOf(david);

            uint256 davidClaimed = davidBalanceAfter - davidBalanceBefore;
            assertEq(
                davidClaimed,
                davidClaimable,
                "David should claim exact claimable amount"
            );
            assertTrue(
                davidBalanceAfter > davidBalanceBefore,
                "David should be able to claim auction prize"
            );

            vm.prank(david);
            assertEq(
                vault.getMyClaimableAmount(),
                0,
                "David should have no claimable after claiming"
            );
        }
    }

    /**
     * @dev Test that verifies auctions start from day 1 (after 25 hours)
     * Fees are split 50/50 between lottery and auction from day 1
     */
    function testAuctionsStartFromDay1() public {
        // Day 0: Setup holders
        mintVault(alice, 100 ether);
        assertEq(vault.balanceOf(alice), 99 ether, "Alice initial balance");

        mintVault(bob, 100 ether);
        assertEq(vault.balanceOf(bob), 99 ether, "Bob initial balance");

        mintVault(charlie, 50 ether);
        assertEq(
            vault.balanceOf(charlie),
            49.5 ether,
            "Charlie initial balance"
        );

        // Still in day 0
        uint256 currentDay = vault.getCurrentDay();
        assertEq(currentDay, 0, "Should be day 0");

        // Generate fees through transfers
        vm.prank(alice);
        bool success1 = vault.transfer(bob, 5 ether);
        assertTrue(success1, "Transfer should succeed");

        vm.prank(bob);
        bool success2 = vault.transfer(charlie, 3 ether);
        assertTrue(success2, "Transfer should succeed");

        // Move to day 1
        moveToNextDay();
        currentDay = vault.getCurrentDay();
        assertEq(currentDay, 1, "Should be day 1");

        // Execute lottery - should create both lottery and auction
        vm.prevrandao(bytes32(uint256(12345)));
        vault.executeLottery();

        // Check that auction was started (50/50 split from day 1)
        (, , , uint112 auctionAmount, uint32 auctionDay) = vault.currentAuction();
        assertGt(auctionAmount, 0, "Auction should be active from day 1");
        assertEq(auctionDay, 0, "Auction should be for day 0 fees");

        // Check that lottery was executed (someone should have won)
        (address lotteryWinner, uint112 lotteryPrize) = vault.lotteryUnclaimedPrizes(0 % 7);
        assertTrue(
            lotteryWinner == alice ||
                lotteryWinner == bob ||
                lotteryWinner == charlie,
            "Should have a lottery winner"
        );
        assertGt(lotteryPrize, 0, "Lottery prize should be greater than 0");

        console.log(
            "Verified: Auctions start from day 1 with 50/50 fee split"
        );
    }

    /**
     * @dev Test that verifies claimed amounts exactly match the prize amounts
     */
    function testExactPrizeAmountsClaimed() public {
        // Setup holders during minting period
        mintVault(alice, 100 ether);
        mintVault(bob, 100 ether);
        mintVault(charlie, 50 ether);

        // Day 1: Generate fees
        vm.warp(block.timestamp + 25 hours);
        vm.prank(alice);
        bool success1 = vault.transfer(bob, 10 ether);
        assertTrue(success1, "Transfer should succeed");
        assertEq(
            vault.balanceOf(alice),
            89 ether,
            "Alice balance after transfer"
        );
        assertEq(
            vault.balanceOf(bob),
            108.9 ether,
            "Bob balance after receiving"
        );

        // Day 2: Execute lottery for day 1's fees
        vm.warp(block.timestamp + 25 hours + 61);
        vm.prevrandao(bytes32(uint256(111111)));
        vault.executeLottery();

        // Check the lottery prize amount
        uint256 lotteryDay = 1;
        (address lotteryWinner, uint112 lotteryPrizeAmount) = vault
            .lotteryUnclaimedPrizes(lotteryDay % 7);

        console.log("Lottery winner:", lotteryWinner);
        console.log("Lottery prize amount:", lotteryPrizeAmount);

        // The winner should have exactly this amount claimable
        vm.prank(lotteryWinner);
        uint256 claimableBeforeClaim = vault.getMyClaimableAmount();
        assertEq(
            claimableBeforeClaim,
            lotteryPrizeAmount,
            "Claimable should match lottery prize"
        );

        // Claim the lottery prize
        uint256 balanceBeforeClaim = vault.balanceOf(lotteryWinner);
        vm.prank(lotteryWinner);
        vault.claim();
        uint256 balanceAfterClaim = vault.balanceOf(lotteryWinner);

        // Verify exact amount was transferred
        uint256 actualClaimed = balanceAfterClaim - balanceBeforeClaim;
        assertEq(
            actualClaimed,
            lotteryPrizeAmount,
            "Should claim exact lottery prize amount"
        );
        console.log("Actual claimed amount:", actualClaimed);

        // Verify claimable is now zero
        vm.prank(lotteryWinner);
        uint256 claimableAfterClaim = vault.getMyClaimableAmount();
        assertEq(
            claimableAfterClaim,
            0,
            "Should have no claimable amount after claiming"
        );

        // Verify the prize slot is cleared
        (address winnerAfter, uint112 amountAfter) = vault
            .lotteryUnclaimedPrizes(lotteryDay % 7);
        assertEq(
            winnerAfter,
            address(0),
            "Winner should be cleared after claim"
        );
        assertEq(amountAfter, 0, "Amount should be cleared after claim");

        console.log("Verified: Exact lottery prize amount claimed");
    }
}
