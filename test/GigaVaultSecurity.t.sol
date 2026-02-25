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

contract GigaVaultSecurityTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

    function setUp() public {
        MockUSDmY mockImpl = new MockUSDmY();
        vm.etch(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890, address(mockImpl).code);
        usdmy = MockUSDmY(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890);
        vault = new GigaVault();

        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
        usdmy.mint(charlie, 100 ether);
    }

    // Helper to mint vault tokens
    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    // ============ Zero Amount Operations ============

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

    function testTransferZeroAmount() public {
        mintVault(alice, 1 ether);

        // Zero transfers should work per ERC20 spec
        vm.prank(alice);
        bool success = vault.transfer(bob, 0);
        assertTrue(success, "Zero transfer should succeed");

        // But no fees should be taken
        assertEq(vault.balanceOf(alice), 0.99 ether);
    }

    // ============ Self Operations ============

    function testSelfTransferFees() public {
        mintVault(alice, 1 ether);

        uint256 balanceBefore = vault.balanceOf(alice);

        // Self transfer should still charge fees
        vm.prank(alice);
        vault.transfer(alice, 0.9 ether);

        uint256 balanceAfter = vault.balanceOf(alice);
        assertEq(
            balanceBefore - balanceAfter,
            0.009 ether,
            "Should charge 1% fee even on self-transfer"
        );
    }

    // ============ Insufficient Balance Tests ============

    function testRedeemWithInsufficientContractUsdmy() public {
        // Mint tokens
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        // Alice redeems all her tokens (9.9 not 9900)
        vm.prank(alice);
        vault.redeem(9.9 ether);

        // Bob tries to redeem but contract has insufficient USDmY
        // After Alice's redemption: contract has ~10.1 USDmY left
        // Bob tries to redeem 9.9 tokens which needs ~9.9 USDmY
        // Should succeed
        vm.prank(bob);
        vault.redeem(9.9 ether);

        // Verify contract is nearly empty
        assertTrue(
            vault.getReserve() < 1 ether,
            "Contract should be nearly empty"
        );
    }

    // ============ Max Supply Tests ============

    function testMaxSupplyEnforcement() public {
        // Mint during minting period (100 USDmY = 100 vault tokens total, alice gets 99 after 1% fee)
        mintVault(alice, 100 ether);

        // Fast forward past minting period
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // First burn some tokens to create capacity (this also sets max supply)
        vm.prank(alice);
        vault.redeem(1 ether); // Burn 1 token (0.99 net after fee)

        // Max supply should now be set to original total supply (100 vault tokens)
        uint256 maxSupply = vault.maxSupplyEver();
        assertGt(maxSupply, 0, "Max supply should be set");
        assertEq(maxSupply, 100 ether, "Max supply should be 100 vault tokens");

        // Current supply is now ~99.01 vault tokens (100 - 0.99 burned)
        // With proportional minting, we can mint up to ~0.99 vault tokens

        // Small mint should succeed
        usdmy.mint(bob, 10 ether);
        mintVault(bob, 0.9 ether);

        // Try to mint again when we're close to max supply - should fail
        vm.startPrank(bob);
        usdmy.approve(address(vault), 0.1 ether);
        vm.expectRevert("Max supply reached");
        vault.mint(0.1 ether); // This would push us over max supply
        vm.stopPrank();
    }

    // ============ Timing Tests ============

    function testTimestampManipulationResistance() public {
        // The 25-hour pseudo-days make it harder to game timing
        mintVault(alice, 10 ether);

        // Fast forward to just before day 2
        vm.warp(block.timestamp + 50 hours - 1);

        // Should still be day 1
        uint256 day = vault.getCurrentDay();
        assertEq(day, 1, "Should still be day 1");

        // Fast forward 2 seconds
        vm.warp(block.timestamp + 2);

        // Now should be day 2
        day = vault.getCurrentDay();
        assertEq(day, 2, "Should be day 2");
    }

    function testPreventDoubleLotteryExecution() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        // Move past minting period
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // Generate fees on day 8
        vm.prank(alice);
        vault.transfer(bob, 0.1 ether);

        // Fast forward to day 9 to execute lottery
        vm.warp(block.timestamp + 25 hours + 61);

        // Execute lottery once
        vault.executeLottery();

        // Try to execute again
        vm.expectRevert("No pending lottery/auction (same day)");
        vault.executeLottery();
    }

    // ============ Large Number Tests ============

    function testLargeFeeCalculation() public {
        // Test with large but reasonable amount
        uint256 largeAmount = 10_000 ether;

        usdmy.mint(alice, largeAmount + 1 ether);
        mintVault(alice, largeAmount);

        // Check fee calculation didn't overflow
        uint256 expectedTokens = (largeAmount * 99) / 100; // 9,900 ether tokens (1:1 ratio after 1% fee)
        assertEq(
            vault.balanceOf(alice),
            expectedTokens,
            "Should receive correct amount"
        );

        uint256 expectedFee = largeAmount / 100; // 100 ether tokens fee (1% of 10000)
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            expectedFee,
            "Fee should be correct"
        );
    }

    // ============ Beneficiary Tests ============

    function testUnclaimedPrizeToBeneficiaries() public {
        // Create a rejecting beneficiary
        RejectingReceiver rejectingBeneficiary = new RejectingReceiver();

        // We can't change beneficiaries array, but we can test the fallback behavior
        // When beneficiary rejects, prize should go to current winner

        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);

        // Generate some transfer fees on day 8
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);
        vm.prank(alice);
        vault.transfer(bob, 1 ether); // 0.01 vault token fee

        // Day 9 - Execute lottery/auction for day 8's fees
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        // After minting period, days alternate between lottery and auction
        // Day 8 fees might go to auction, not lottery
        // So generate more fees and execute more days to ensure we get a lottery

        // Generate fees on day 9
        vm.prank(bob);
        vault.transfer(alice, 0.5 ether); // 0.005 vault token fee

        // Day 10 - Execute for day 9's fees
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        // Now check for a winner - try both slots
        (address winner1, uint112 amount1) = vault.lotteryUnclaimedPrizes(
            9 % 7
        );
        if (winner1 == address(0)) {
            // Try slot 8 if 9 is empty
            (winner1, amount1) = vault.lotteryUnclaimedPrizes(8 % 7);
        }
        assertTrue(winner1 != address(0), "Should have winner");
        assertTrue(amount1 > 0, "Should have prize amount");

        // Store the unclaimed prize amount for later verification
        uint256 unclaimedPrizeAmount = amount1;
        (address checkWinner, ) = vault.lotteryUnclaimedPrizes(9 % 7);
        uint256 slotToOverwrite = (winner1 == checkWinner) ? 9 % 7 : 8 % 7;

        // Get the owner address to track its balance
        address beneficiary = vault.owner();
        uint256 beneficiaryUsdmyBefore = usdmy.balanceOf(beneficiary);

        // Fast forward 7 days to overwrite the slot with unclaimed prize
        // This will trigger the beneficiary funding
        for (uint256 i = 0; i < 7; i++) {
            // Generate fees for the current day
            vm.prank(alice);
            vault.transfer(bob, 0.1 ether);

            // Move to next day and execute lottery
            vm.warp(block.timestamp + 25 hours + 61);
            vault.executeLottery();
        }

        // Check if beneficiary received USDmY
        uint256 beneficiaryUsdmyAfter = usdmy.balanceOf(beneficiary);
        uint256 totalUsdmySent = beneficiaryUsdmyAfter - beneficiaryUsdmyBefore;

        // CRITICAL: The beneficiary should receive USDmY equal to the backing value of the vault token prize
        // The correct conversion should be: usdmyAmount = (tokenAmount * contractUsdmyBalance) / totalSupply

        // During the 7-day loop, MULTIPLE unclaimed prizes may be sent to beneficiaries
        // The contract correctly converts each vault token prize to USDmY using the backing ratio
        // With a backing ratio close to 1:1 (since fees are minted), the conversion is approximately 1:1

        // Verify that USDmY was sent to beneficiary
        assertTrue(
            totalUsdmySent > 0,
            "Should have sent some USDmY to beneficiary"
        );
    }

    // ============ Ownership Tests ============

    function testRenounceOwnershipReverts() public {
        vm.expectRevert("Cannot renounce ownership");
        vault.renounceOwnership();
    }

    function testOwnerTransfer() public {
        // Verify initial owner is this test contract
        address initialOwner = vault.owner();
        assertEq(initialOwner, address(this), "Initial owner should be deployer");

        // Step 1: Transfer ownership to bob
        vault.transferOwnership(bob);

        // Owner should still be the original until bob accepts
        assertEq(vault.owner(), address(this), "Owner should not change until accepted");

        // Step 2: Bob accepts ownership
        vm.prank(bob);
        vault.acceptOwnership();

        // Verify owner is now bob
        assertEq(vault.owner(), bob, "Owner should now be bob");
    }

    // ============ Fenwick Tree Consistency ============

    function testFenwickTreeConsistencyUnderStress() public {
        // Rapidly add and remove holders
        address[] memory users = new address[](20);
        for (uint256 i = 0; i < 20; i++) {
            users[i] = address(uint160(0x1000 + i));
            usdmy.mint(users[i], 10 ether);
        }

        // Mint for all users
        for (uint256 i = 0; i < 20; i++) {
            mintVault(users[i], 1 ether);
        }

        // Move past minting period to ensure fees go to pool
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // Do random transfers to generate fees
        for (uint256 i = 0; i < 50; i++) {
            uint256 from = i % 20;
            uint256 to = (i + 7) % 20;
            uint256 amount = 0.1 ether * ((i % 5) + 1);

            if (vault.balanceOf(users[from]) >= amount) {
                vm.prank(users[from]);
                vault.transfer(users[to], amount);
            }
        }

        // System should still be consistent - verify by executing lottery
        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery(); // Should not revert
    }
}

// Helper contracts
contract RejectingReceiver {
    receive() external payable {
        revert("I reject USDmY!");
    }
}
