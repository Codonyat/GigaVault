// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GigaVault} from "../src/GigaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

contract GigaVaultForkTest is Test {
    GigaVault public vault;

    address constant USDMY = 0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890;
    address constant USDM = 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public david = address(0x4);

    function setUp() public {
        vm.createFork("mega_mainnet");
        vm.selectFork(0);

        // Deploy fresh GigaVault on fork (constructor validates USDMY.asset() == USDM)
        vault = new GigaVault();

        // Fund test accounts with ETH for gas
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(david, 100 ether);

        // Deal USDm to each user
        deal(USDM, alice, 200e18);
        deal(USDM, bob, 200e18);
        deal(USDM, charlie, 200e18);
        deal(USDM, david, 200e18);

        // Verify deal worked
        assertEq(IERC20(USDM).balanceOf(alice), 200e18, "deal failed for alice");
        assertEq(IERC20(USDM).balanceOf(bob), 200e18, "deal failed for bob");
        assertEq(IERC20(USDM).balanceOf(charlie), 200e18, "deal failed for charlie");
        assertEq(IERC20(USDM).balanceOf(david), 200e18, "deal failed for david");

        // Deposit USDm into real USDmY for each user (~100e18 each)
        _acquireUSDmY(alice, 100e18);
        _acquireUSDmY(bob, 100e18);
        _acquireUSDmY(charlie, 100e18);
        _acquireUSDmY(david, 100e18);
    }

    // ── Helpers ──

    function _acquireUSDmY(address user, uint256 usdmAmount) internal {
        vm.startPrank(user);
        IERC20(USDM).approve(USDMY, usdmAmount);
        IERC4626(USDMY).deposit(usdmAmount, user);
        vm.stopPrank();
    }

    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        IERC20(USDMY).approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    function mintVaultWithUSDm(address user, uint256 usdmAmount) internal {
        vm.startPrank(user);
        IERC20(USDM).approve(address(vault), usdmAmount);
        vault.mintWithUSDm(usdmAmount);
        vm.stopPrank();
    }

    function placeBid(address bidder, uint256 bidAmount) internal {
        vm.startPrank(bidder);
        IERC20(USDMY).approve(address(vault), bidAmount);
        vault.bid(bidAmount);
        vm.stopPrank();
    }

    function skipPastMintingPeriod() internal {
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);
    }

    function moveToNextDay() internal {
        vm.warp(block.timestamp + 25 hours + 61);
    }

    function setupAuction() internal {
        mintVault(alice, 10e18);
        mintVault(bob, 10e18);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 1e18);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();
    }

    // ═══════════════════════════════════════════════════
    //  ERC4626 deposit path — mintWithUSDm / bidWithUSDm
    // ═══════════════════════════════════════════════════

    function testFork_MintWithUSDm() public {
        uint256 usdmAmount = 10e18;

        // Compute expected shares BEFORE the call
        uint256 expectedShares = IERC4626(USDMY).previewDeposit(usdmAmount);

        uint256 reserveBefore = vault.getReserve();
        assertEq(reserveBefore, 0, "Reserve should be 0 before first mint");

        mintVaultWithUSDm(alice, usdmAmount);

        uint256 reserveAfter = vault.getReserve();

        // Reserve should match the real shares received (< usdmAmount due to exchange rate)
        assertApproxEqAbs(reserveAfter, expectedShares, 1, "Reserve should equal previewDeposit result");

        // Alice's USDmore should be calculated from real shares, not raw USDm amount
        // During day 1: tokensToMint = collateralAmount (which is sharesReceived)
        // fee = tokensToMint * 1/100, net = tokensToMint - fee
        uint256 expectedFee = (expectedShares * 100) / 10_000;
        uint256 expectedNet = expectedShares - expectedFee;
        assertApproxEqAbs(vault.balanceOf(alice), expectedNet, 1, "Alice USDmore should be based on real shares");

        // Reserve identity
        assertEq(vault.getReserve(), IERC20(USDMY).balanceOf(address(vault)) - vault.escrowedBid(), "Reserve identity");
    }

    function testFork_MintWithUSDm_MatchesManualConversion() public {
        uint256 usdmAmount = 10e18;

        // Alice: mintWithUSDm
        mintVaultWithUSDm(alice, usdmAmount);

        // Bob: manually deposit USDm → USDmY, then mint with shares
        vm.startPrank(bob);
        IERC20(USDM).approve(USDMY, usdmAmount);
        uint256 sharesReceived = IERC4626(USDMY).deposit(usdmAmount, bob);
        IERC20(USDMY).approve(address(vault), sharesReceived);
        vault.mint(sharesReceived);
        vm.stopPrank();

        // Both should have the same USDmore balance — proves contract uses sharesReceived
        assertEq(
            vault.balanceOf(alice),
            vault.balanceOf(bob),
            "mintWithUSDm should match manual deposit+mint"
        );
    }

    function testFork_BidWithUSDm() public {
        setupAuction();

        (, , uint96 minBid, , ) = vault.currentAuction();
        require(minBid > 0, "minBid should be > 0");

        // Compute USDm amount that yields enough shares to exceed minBid
        // Use 2x minBid worth of USDm to be safe
        uint256 usdmForBid = uint256(minBid) * 2;

        uint256 expectedShares = IERC4626(USDMY).previewDeposit(usdmForBid);
        require(expectedShares >= minBid, "Expected shares should exceed minBid");

        vm.startPrank(charlie);
        IERC20(USDM).approve(address(vault), usdmForBid);
        vault.bidWithUSDm(usdmForBid);
        vm.stopPrank();

        // Stored bid should be the real shares, not the USDm amount
        (, uint96 currentBid, , , ) = vault.currentAuction();
        assertApproxEqAbs(uint256(currentBid), expectedShares, 1, "Bid should be previewDeposit result");

        // David outbids with USDmY — charlie gets USDmY refund
        uint256 outbidAmount = (uint256(currentBid) * 110) / 100 + 1;
        uint256 charlieUsdmYBeforeRefund = IERC20(USDMY).balanceOf(charlie);

        placeBid(david, outbidAmount);

        uint256 charlieUsdmYAfterRefund = IERC20(USDMY).balanceOf(charlie);
        // Charlie should get back the real shares that were deposited
        assertApproxEqAbs(
            charlieUsdmYAfterRefund - charlieUsdmYBeforeRefund,
            expectedShares,
            1,
            "Charlie should get USDmY refund equal to deposited shares"
        );
    }

    // ═══════════════════════════════════════════════════
    //  ERC4626 redeem path — redeemToUSDm
    // ═══════════════════════════════════════════════════

    function testFork_RedeemToUSDm() public {
        // Mint with USDmY first
        uint256 usdmyAmount = 10e18;
        mintVault(alice, usdmyAmount);

        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 aliceUsdmBefore = IERC20(USDM).balanceOf(alice);
        uint256 aliceUsdmYBefore = IERC20(USDMY).balanceOf(alice);

        // Compute expected collateral to return
        uint256 fee = (aliceBalance * 100) / 10_000;
        uint256 netTokens = aliceBalance - fee;
        uint256 collateralToReturn = (netTokens * vault.getReserve()) / vault.totalSupply();

        // Compute expected USDm from redeeming that collateral
        uint256 expectedUsdm = IERC4626(USDMY).previewRedeem(collateralToReturn);

        vm.startPrank(alice);
        vault.redeemToUSDm(aliceBalance);
        vm.stopPrank();

        uint256 aliceUsdmAfter = IERC20(USDM).balanceOf(alice);
        uint256 aliceUsdmYAfter = IERC20(USDMY).balanceOf(alice);

        // Alice should have received USDm
        assertApproxEqAbs(
            aliceUsdmAfter - aliceUsdmBefore,
            expectedUsdm,
            1,
            "USDm received should match previewRedeem"
        );

        // Alice's USDmY should be unchanged (she got USDm, not USDmY)
        assertEq(aliceUsdmYAfter, aliceUsdmYBefore, "Alice USDmY should be unchanged");
    }

    function testFork_MintRedeemRoundTrip() public {
        uint256 startUsdm = 50e18;

        uint256 aliceUsdmBefore = IERC20(USDM).balanceOf(alice);

        // Step 1: mintWithUSDm
        mintVaultWithUSDm(alice, startUsdm);

        uint256 aliceUsdmore = vault.balanceOf(alice);

        // Step 2: redeemToUSDm with full balance
        uint256 redeemFee = (aliceUsdmore * 100) / 10_000;
        uint256 netRedeem = aliceUsdmore - redeemFee;
        uint256 collateral = (netRedeem * vault.getReserve()) / vault.totalSupply();
        uint256 expectedUsdmBack = IERC4626(USDMY).previewRedeem(collateral);

        vm.startPrank(alice);
        vault.redeemToUSDm(aliceUsdmore);
        vm.stopPrank();

        uint256 aliceUsdmAfter = IERC20(USDM).balanceOf(alice);
        uint256 actualUsdmReceived = aliceUsdmAfter - (aliceUsdmBefore - startUsdm);

        // Round-trip: USDm → USDmY → USDmore → USDmY → USDm with two 1% fees + exchange rate
        assertApproxEqRel(
            actualUsdmReceived,
            expectedUsdmBack,
            0.0001e18, // 0.01% tolerance
            "Round-trip USDm should match formula expectation"
        );

        // Sanity: should get back less than started due to fees
        assertLt(actualUsdmReceived, startUsdm, "Round-trip should lose to fees");
    }

    // ═══════════════════════════════════════════════════
    //  Beneficiary payout
    // ═══════════════════════════════════════════════════

    function testFork_LotteryBeneficiaryReceivesUSDmY() public {
        // Mint to generate holders and fees
        mintVault(alice, 50e18);
        mintVault(bob, 50e18);

        skipPastMintingPeriod();

        // Generate fees via transfer
        vm.prank(alice);
        vault.transfer(bob, 5e18);

        // Trigger lottery — this creates an unclaimed prize in a slot
        moveToNextDay();
        vault.executeLottery();

        // Generate more fees each day for 7 days to cycle through all slots
        // and force an overwrite of the first unclaimed prize
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(alice);
            vault.transfer(bob, 1e18);
            moveToNextDay();
            vault.executeLottery();
        }

        // After cycling through 7+ days, at least one unclaimed lottery prize should
        // have been sent to the beneficiary (owner) as USDmY
        address beneficiary = vault.owner();
        uint256 beneficiaryUsdmY = IERC20(USDMY).balanceOf(beneficiary);

        // The beneficiary should have received some USDmY from expired prizes
        assertGt(beneficiaryUsdmY, 0, "Beneficiary should have received USDmY from expired lottery prize");
    }

    function testFork_AuctionBeneficiaryReceivesUSDmY() public {
        // Mint to generate holders
        mintVault(alice, 50e18);
        mintVault(bob, 50e18);

        skipPastMintingPeriod();

        // Generate fees and trigger lottery/auction
        vm.prank(alice);
        vault.transfer(bob, 5e18);

        moveToNextDay();
        vault.executeLottery();

        // Place a bid so the auction has a winner (david)
        (, , uint96 minBid, , ) = vault.currentAuction();
        placeBid(david, uint256(minBid));

        // David does NOT claim. Advance 7 days to overwrite david's auction slot.
        for (uint256 i = 0; i < 7; i++) {
            vm.prank(alice);
            vault.transfer(bob, 1e18);
            moveToNextDay();
            vault.executeLottery();

            // Place bids so each auction has a winner
            (, , uint96 mb, , ) = vault.currentAuction();
            if (mb > 0) {
                placeBid(charlie, uint256(mb));
            }
        }

        // After 7 days, david's unclaimed auction prize should have been sent to beneficiary
        address beneficiary = vault.owner();
        uint256 beneficiaryUsdmY = IERC20(USDMY).balanceOf(beneficiary);

        assertGt(beneficiaryUsdmY, 0, "Beneficiary should have received USDmY from expired auction prize");
    }

    // ═══════════════════════════════════════════════════
    //  Max supply with real USDm deposits
    // ═══════════════════════════════════════════════════

    function testFork_MaxSupplyWithUSDmDeposits() public {
        uint256 usdmAmount = 100e18;

        // Mint during minting period with USDm
        mintVaultWithUSDm(alice, usdmAmount);

        uint256 totalBefore = vault.totalSupply();
        // maxSupply is based on real shares, which is < 100e18 USDmore
        assertLt(totalBefore, usdmAmount, "Total supply should be less than USDm deposited due to exchange rate");

        // Skip past minting period — maxSupply gets locked
        skipPastMintingPeriod();

        // Force maxSupply to be set by calling a state-changing function
        vm.prank(alice);
        vault.transfer(bob, 1e18);

        uint256 maxSupply = vault.maxSupplyEver();
        assertGt(maxSupply, 0, "maxSupply should be set");
        assertEq(maxSupply, uint112(totalBefore), "maxSupply should equal total supply at end of minting period");

        // Redeem some to create capacity
        uint256 redeemAmount = vault.balanceOf(alice) / 2;
        vm.startPrank(alice);
        vault.redeem(redeemAmount);
        vm.stopPrank();

        uint256 capacity = maxSupply - vault.totalSupply();
        assertGt(capacity, 0, "Should have capacity after redemption");

        // Mint up to capacity — should succeed
        // Need to acquire more USDmY for minting
        _acquireUSDmY(bob, 50e18);
        vm.startPrank(bob);
        IERC20(USDMY).approve(address(vault), capacity);
        vault.mint(capacity);
        vm.stopPrank();

        // Mint 1 more wei — should revert
        vm.startPrank(bob);
        IERC20(USDMY).approve(address(vault), 1e18);
        vm.expectRevert("Max supply reached");
        vault.mint(1e18);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════
    //  Edge cases with real ERC4626
    // ═══════════════════════════════════════════════════

    function testFork_TinyDepositRevertsZeroShares() public {
        // 1 wei USDm — real ERC4626 may return 0 shares
        vm.startPrank(alice);
        IERC20(USDM).approve(address(vault), 1);
        vm.expectRevert(); // Either "Zero shares received" or ERC4626 reverts
        vault.mintWithUSDm(1);
        vm.stopPrank();

        // Same for bidWithUSDm — set up an auction first
        setupAuction();

        vm.startPrank(charlie);
        IERC20(USDM).approve(address(vault), 1);
        vm.expectRevert(); // Either "Zero shares received" or ERC4626 reverts
        vault.bidWithUSDm(1);
        vm.stopPrank();
    }

    function testFork_BidWithUSDm_TooLowAfterConversion() public {
        setupAuction();

        (, , uint96 minBid, , ) = vault.currentAuction();
        require(minBid > 0, "minBid should be > 0");

        // Find a USDm amount where previewDeposit(amount) < minBid
        // Start from minBid value and reduce until it's just under
        uint256 usdmAmount = uint256(minBid); // 1:~1 ratio, so this should give shares ≈ minBid
        // Due to exchange rate, shares < assets, so previewDeposit(minBid) < minBid
        uint256 sharesExpected = IERC4626(USDMY).previewDeposit(usdmAmount);

        // If the exchange rate doesn't make it drop below, reduce the amount
        if (sharesExpected >= minBid) {
            // Binary search for the right amount
            uint256 lo = 1;
            uint256 hi = usdmAmount;
            while (lo < hi) {
                uint256 mid = (lo + hi + 1) / 2;
                if (IERC4626(USDMY).previewDeposit(mid) < minBid) {
                    lo = mid;
                } else {
                    hi = mid - 1;
                }
            }
            usdmAmount = lo;
            sharesExpected = IERC4626(USDMY).previewDeposit(usdmAmount);
        }

        require(sharesExpected < minBid, "Test setup: need shares < minBid");

        uint256 charlieUsdmBefore = IERC20(USDM).balanceOf(charlie);
        uint256 vaultUsdmYBefore = IERC20(USDMY).balanceOf(address(vault));

        vm.startPrank(charlie);
        IERC20(USDM).approve(address(vault), usdmAmount);
        vm.expectRevert("Bid too low");
        vault.bidWithUSDm(usdmAmount);
        vm.stopPrank();

        // Verify atomic rollback — no USDm consumed, no USDmY stuck
        assertEq(IERC20(USDM).balanceOf(charlie), charlieUsdmBefore, "No USDm should be consumed on revert");
        assertEq(IERC20(USDMY).balanceOf(address(vault)), vaultUsdmYBefore, "No USDmY should be stuck in vault");
    }
}
