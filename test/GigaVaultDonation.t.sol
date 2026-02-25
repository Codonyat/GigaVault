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

contract GigaVaultDonationTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public donor = address(0x3);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Minted(
        address indexed to,
        uint256 collateralAmount,
        uint256 tokenAmount,
        uint256 fee
    );
    event Redeemed(
        address indexed from,
        uint256 tokenAmount,
        uint256 collateralAmount,
        uint256 fee
    );

    function setUp() public {
        MockUSDmY mockImpl = new MockUSDmY();
        vm.etch(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890, address(mockImpl).code);
        usdmy = MockUSDmY(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890);
        vault = new GigaVault();

        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
        usdmy.mint(donor, 100 ether);
    }

    // Helper to mint vault tokens
    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    // Helper to donate USDmY to the contract
    function donateUsdmy(address from, uint256 amount) internal {
        vm.prank(from);
        usdmy.transfer(address(vault), amount);
    }

    function testDonationIncreasesRedemptionValue() public {
        // Alice mints first
        uint256 mintAmount = 10 ether;
        uint256 expectedTokens = mintAmount * 99 / 100; // 9.9 tokens after 1% fee
        uint256 expectedFee = mintAmount / 100; // 0.1 tokens fee

        mintVault(alice, mintAmount);

        assertEq(
            vault.balanceOf(alice),
            expectedTokens,
            "Alice should receive 9.9 tokens"
        );
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            expectedFee,
            "Fees pool should have 0.1 tokens"
        );

        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 contractBalanceBefore = vault.getReserve();
        assertEq(
            totalSupplyBefore,
            10 ether,
            "Total supply should be 10 tokens"
        );
        assertEq(
            contractBalanceBefore,
            mintAmount,
            "Contract should hold 10 USDmY"
        );

        // Calculate redemption value before donation
        uint256 redeemAmount = 1 ether; // 1 vault token
        uint256 fee = redeemAmount / 100; // 0.01 vault token fee
        uint256 netAmount = redeemAmount - fee; // 0.99 vault token
        uint256 redemptionValueBefore = (netAmount * contractBalanceBefore) /
            totalSupplyBefore;
        assertEq(
            redemptionValueBefore,
            0.99 ether,
            "Redemption value before should be 0.99 USDmY"
        );

        // Donor sends 5 USDmY to the contract (donation)
        uint256 donationAmount = 5 ether;
        donateUsdmy(donor, donationAmount);

        // Check contract balance increased
        assertEq(
            vault.getReserve(),
            contractBalanceBefore + donationAmount,
            "Contract balance should increase by 5 USDmY"
        );

        // Check total supply unchanged
        assertEq(
            vault.totalSupply(),
            totalSupplyBefore,
            "Total supply should remain 10 tokens"
        );

        // Calculate redemption value after donation
        uint256 redemptionValueAfter = (netAmount * vault.getReserve()) /
            vault.totalSupply();
        assertEq(
            redemptionValueAfter,
            1.485 ether,
            "Redemption value after should be 1.485 USDmY"
        );

        // Redemption value should increase by 50%
        assertEq(
            redemptionValueAfter - redemptionValueBefore,
            0.495 ether,
            "Redemption value should increase by 0.495 USDmY"
        );
    }

    function testDonationDoesntAffectMinting() public {
        // Initial mint
        mintVault(alice, 1 ether);
        assertEq(
            vault.balanceOf(alice),
            0.99 ether,
            "Alice should get 0.99 tokens"
        );

        // Donate USDmY
        uint256 donationAmount = 10 ether;
        donateUsdmy(donor, donationAmount);
        assertEq(
            vault.getReserve(),
            11 ether,
            "Contract should have 11 USDmY"
        );

        // Bob mints after donation
        mintVault(bob, 1 ether);

        // Bob should still get the standard amount (0.99 vault tokens after 1% fee)
        assertEq(
            vault.balanceOf(bob),
            0.99 ether,
            "Bob should get 0.99 tokens despite donation"
        );
        assertEq(
            vault.getReserve(),
            12 ether,
            "Contract should have 12 USDmY"
        );
    }

    function testDonationDoesntBreakLottery() public {
        // Setup holders
        mintVault(alice, 10 ether);
        assertEq(
            vault.balanceOf(alice),
            9.9 ether,
            "Alice should have 9.9 tokens"
        );

        mintVault(bob, 10 ether);
        assertEq(
            vault.balanceOf(bob),
            9.9 ether,
            "Bob should have 9.9 tokens"
        );

        // Generate fees on day 0
        uint256 transferAmount = 1 ether;

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0.99 ether); // Bob receives 0.99 after fee

        vm.prank(alice);
        vault.transfer(bob, transferAmount);
        assertEq(
            vault.balanceOf(alice),
            8.9 ether,
            "Alice should have 8.9 tokens"
        );
        assertEq(
            vault.balanceOf(bob),
            10.89 ether,
            "Bob should have 10.89 tokens"
        );
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            0.21 ether,
            "Fees pool should have 0.21 tokens"
        );

        // Donate USDmY
        uint256 donationAmount = 5 ether;
        donateUsdmy(donor, donationAmount);
        assertEq(
            vault.getReserve(),
            25 ether,
            "Contract should have 25 USDmY"
        );

        // Move to day 1
        vm.warp(block.timestamp + 25 hours);

        // Generate fees on day 1
        vm.expectEmit(true, true, true, true);
        emit Transfer(bob, alice, 0.99 ether);

        vm.prank(bob);
        vault.transfer(alice, transferAmount);
        assertEq(
            vault.balanceOf(bob),
            9.89 ether,
            "Bob should have 9.89 tokens"
        );
        assertEq(
            vault.balanceOf(alice),
            9.89 ether,
            "Alice should have 9.89 tokens"
        );
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            0.22 ether,
            "Fees pool should have 0.22 tokens"
        );

        // Move to day 2 and execute lottery
        vm.warp(block.timestamp + 25 hours + 61);

        // Lottery should execute without issues
        vault.executeLottery();

        // Check lottery executed
        assertEq(
            vault.lastLotteryDay(),
            2,
            "Lottery should be executed for day 2"
        );
    }

    function testMultipleDonations() public {
        // Initial setup
        mintVault(alice, 1 ether);

        uint256 initialBalance = vault.getReserve();

        // Multiple donations
        for (uint256 i = 0; i < 5; i++) {
            address currentDonor = address(uint160(0x100 + i));
            usdmy.mint(currentDonor, 10 ether);
            donateUsdmy(currentDonor, 1 ether);
        }

        // Contract should have received all donations
        assertEq(vault.getReserve(), initialBalance + 5 ether);

        // Total supply should be unchanged
        assertEq(vault.totalSupply(), 1 ether); // Only from Alice's mint (1:1 ratio)
    }

    function testDonationAfterMintingPeriod() public {
        // Mint during minting period
        mintVault(alice, 10 ether);

        // Move past minting period
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // Alice redeems to trigger max supply setting
        vm.prank(alice);
        vault.redeem(0.1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertTrue(maxSupply > 0, "Max supply should be set");

        // Donate USDmY after minting period
        donateUsdmy(donor, 5 ether);

        // Max supply should remain unchanged
        assertEq(vault.maxSupplyEver(), maxSupply);

        // Bob can still mint (within capacity)
        usdmy.mint(bob, 10 ether);
        mintVault(bob, 0.09 ether);
    }

    function testRedemptionWithDonation() public {
        // Alice mints
        uint256 mintAmount = 10 ether;
        mintVault(alice, mintAmount);

        uint256 aliceTokens = vault.balanceOf(alice);
        assertEq(aliceTokens, 9.9 ether, "Alice should have 9.9 tokens");

        // Donate 5 USDmY
        uint256 donationAmount = 5 ether;
        donateUsdmy(donor, donationAmount);
        assertEq(
            vault.getReserve(),
            15 ether,
            "Contract should have 15 USDmY"
        );

        // Alice redeems half her tokens
        uint256 redeemAmount = aliceTokens / 2; // 4,950 tokens
        uint256 redeemFee = redeemAmount / 100; // 49.5 tokens fee
        uint256 netRedeemed = redeemAmount - redeemFee; // 4,900.5 tokens
        uint256 expectedCollateral = (netRedeemed * 15 ether) / vault.totalSupply(); // (4900.5 * 15) / 10000 = 7.35075 USDmY

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(alice, redeemAmount, expectedCollateral, redeemFee);

        vm.prank(alice);
        vault.redeem(redeemAmount);

        uint256 aliceUsdmyAfter = usdmy.balanceOf(alice);
        uint256 usdmyReceived = aliceUsdmyAfter - aliceUsdmyBefore;

        // Alice should have received more USDmY due to donation
        assertEq(
            usdmyReceived,
            expectedCollateral,
            "Alice should receive exact USDmY amount"
        );
        assertTrue(
            usdmyReceived > 7.35 ether,
            "Should receive over 7.35 USDmY due to donation"
        );
        assertEq(
            vault.balanceOf(alice),
            4.95 ether,
            "Alice should have 4,950 tokens left"
        );
    }

    function testFuzzDonations(uint256 donationAmount, uint8 numDonors) public {
        // Bound inputs
        donationAmount = bound(donationAmount, 0.001 ether, 10 ether);
        numDonors = uint8(bound(numDonors, 1, 10));

        // Initial mint
        mintVault(alice, 1 ether);

        uint256 totalDonated = 0;
        uint256 initialBalance = vault.getReserve();

        // Make donations
        for (uint256 i = 0; i < numDonors; i++) {
            address currentDonor = address(uint160(0x1000 + i));
            usdmy.mint(currentDonor, donationAmount + 1 ether);
            donateUsdmy(currentDonor, donationAmount);
            totalDonated += donationAmount;
        }

        // Verify accounting
        assertEq(vault.getReserve(), initialBalance + totalDonated);
        assertEq(vault.totalSupply(), 1 ether); // Unchanged
    }
}
