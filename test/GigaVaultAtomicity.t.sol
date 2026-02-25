// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GigaVault} from "../src/GigaVault.sol";

// Mock USDmY ERC20 for this standalone test
contract MockUSDmYLocal {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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

contract GigaVaultAtomicityTest is Test {
    GigaVault public vault;
    MockUSDmYLocal public usdmy;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);

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
        MockUSDmYLocal mockImpl = new MockUSDmYLocal();
        vm.etch(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890, address(mockImpl).code);
        usdmy = MockUSDmYLocal(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890);
        vault = new GigaVault();

        // Fund accounts with USDmY tokens
        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
        usdmy.mint(charlie, 100 ether);
    }

    // Helper to approve and mint
    function mintVault(address user, uint256 amount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), amount);
        vault.mint(amount);
        vm.stopPrank();
    }

    function testFenwickTreeAtomicityDuringTransfers() public {
        // Setup: Create holders with exact amounts
        mintVault(alice, 10 ether);
        assertEq(
            vault.balanceOf(alice),
            9.9 ether,
            "Alice should have 9,900 tokens"
        );

        mintVault(bob, 5 ether);
        assertEq(
            vault.balanceOf(bob),
            4.95 ether,
            "Bob should have 4,950 tokens"
        );

        mintVault(charlie, 3 ether);
        assertEq(
            vault.balanceOf(charlie),
            2.97 ether,
            "Charlie should have 2,970 tokens"
        );

        // Verify initial Fenwick tree state
        uint256 initialSuffix1 = vault.getSuffixSum(1);
        uint256 expectedInitialTotal = 9.9 ether + 4.95 ether + 2.97 ether; // 17.82 tokens
        assertEq(
            initialSuffix1,
            expectedInitialTotal,
            "Initial Fenwick sum should be 17,820 tokens"
        );

        // Perform multiple transfers in same transaction
        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0.099 ether); // 0.1 - 1% fee = 0.099
        vault.transfer(bob, 0.1 ether);
        assertEq(
            vault.balanceOf(alice),
            9.8 ether,
            "Alice should have 9.8 tokens after first transfer"
        );
        assertEq(
            vault.balanceOf(bob),
            5.049 ether,
            "Bob should have 5.049 tokens"
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, charlie, 0.198 ether); // 0.2 - 1% fee = 0.198
        vault.transfer(charlie, 0.2 ether);
        assertEq(
            vault.balanceOf(alice),
            9.6 ether,
            "Alice should have 9.6 tokens after second transfer"
        );
        assertEq(
            vault.balanceOf(charlie),
            3.168 ether,
            "Charlie should have 3.168 tokens"
        );
        vm.stopPrank();

        // Verify Fenwick tree is still consistent
        uint256 afterSuffix1 = vault.getSuffixSum(1);
        uint256 expectedAfterTotal = 9.6 ether + 5.049 ether + 3.168 ether; // 17.817 tokens (0.003 tokens to fees)
        assertEq(
            afterSuffix1,
            expectedAfterTotal,
            "Fenwick sum should be 17.817 tokens after transfers"
        );
    }

    function testFenwickTreeAtomicityDuringMintAndBurn() public {
        // Initial mint
        mintVault(alice, 10 ether);
        assertEq(
            vault.balanceOf(alice),
            9.9 ether,
            "Alice should have 9,900 tokens"
        );

        // Check Fenwick consistency after mint
        uint256 suffix1AfterMint = vault.getSuffixSum(1);
        assertEq(
            suffix1AfterMint,
            9.9 ether,
            "Fenwick should be 9,900 after mint"
        );

        // Move past minting period to enable redemption
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        // Trigger max supply setting
        uint256 redeemAmount = 0.1 ether;
        uint256 redeemFee = 0.001 ether; // 1% of 0.1
        uint256 netRedeemed = 0.099 ether;
        uint256 collateralReturned = netRedeemed; // 0.099 USDmY (1:1 ratio)

        vm.expectEmit(true, true, true, true);
        emit Redeemed(alice, redeemAmount, collateralReturned, redeemFee);
        vm.prank(alice);
        vault.redeem(redeemAmount);
        assertEq(
            vault.balanceOf(alice),
            9.8 ether,
            "Alice should have 9.8 tokens after redeem"
        );

        // Check Fenwick consistency after redemption
        uint256 suffix1AfterRedeem = vault.getSuffixSum(1);
        assertEq(
            suffix1AfterRedeem,
            9.8 ether,
            "Fenwick should be 9.8 after redeem"
        );

        // Add another holder - mint slightly more to meet minimum requirement
        uint256 mintAmount = 0.0001 ether;
        uint256 expectedTokens = (mintAmount * vault.totalSupply()) /
            vault.getReserve();
        uint256 expectedFee = expectedTokens / 100;
        uint256 expectedNet = expectedTokens - expectedFee;

        mintVault(bob, mintAmount);
        assertEq(
            vault.balanceOf(bob),
            expectedNet,
            "Bob should have expected tokens"
        );

        // Verify both holders are tracked correctly
        uint256 finalSuffix1 = vault.getSuffixSum(1);
        uint256 expectedFinal = 9.8 ether + expectedNet;
        assertEq(
            finalSuffix1,
            expectedFinal,
            "Fenwick should be correct with both holders"
        );
    }

    function testFenwickTreeAtomicityDuringComplexOperations() public {
        // Create initial holders
        address[10] memory users;
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0x100 + i));
            usdmy.mint(users[i], 10 ether);
            vm.startPrank(users[i]);
            usdmy.approve(address(vault), 1 ether);
            vault.mint(1 ether);
            vm.stopPrank();
        }

        // Verify initial state
        uint256 totalSupply = vault.totalSupply();
        uint256 fenwickTotal = vault.getSuffixSum(1);

        // Fenwick only tracks user holders, not pools
        assertTrue(
            fenwickTotal <= totalSupply,
            "Fenwick should not exceed total supply"
        );

        // Perform random transfers
        for (uint256 round = 0; round < 20; round++) {
            uint256 from = round % 10;
            uint256 to = (round + 3) % 10;
            uint256 amount = 0.05 ether + (round * 0.01 ether);

            if (vault.balanceOf(users[from]) >= amount) {
                vm.prank(users[from]);
                vault.transfer(users[to], amount);
            }
        }

        // Calculate expected total from individual balances
        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < 10; i++) {
            expectedTotal += vault.balanceOf(users[i]);
        }

        // Verify Fenwick tree still consistent
        uint256 finalFenwickTotal = vault.getSuffixSum(1);
        assertEq(
            finalFenwickTotal,
            expectedTotal,
            "Fenwick tree inconsistent after complex operations"
        );
    }

    function testAtomicityWithReentrancy() public {
        // This test ensures that even with potential reentrancy,
        // the Fenwick tree remains consistent due to atomic updates

        // Create a malicious contract that tries to reenter
        MaliciousReentrant malicious = new MaliciousReentrant(vault, usdmy);
        usdmy.mint(address(malicious), 10 ether);

        // Initial state
        mintVault(alice, 10 ether);

        uint256 initialFenwick = vault.getSuffixSum(1);
        assertEq(
            initialFenwick,
            vault.balanceOf(alice),
            "Initial Fenwick incorrect"
        );

        // Try to transfer to malicious contract
        // The reentrancy guard should prevent any issues
        uint256 transferAmount = 0.1 ether;
        uint256 netTransferred = 0.099 ether;

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(malicious), netTransferred);
        vm.prank(alice);
        vault.transfer(address(malicious), transferAmount);

        // Verify Fenwick tree is still consistent
        // Note: Smart contracts are excluded from Fenwick tree (only EOAs are tracked)
        // So the malicious contract balance won't be in the Fenwick sum
        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 maliciousBalance = vault.balanceOf(address(malicious));

        // Only Alice's balance should be in the Fenwick tree
        assertEq(
            finalFenwick,
            aliceBalance,
            "Fenwick should only track Alice (EOA)"
        );

        // Verify the transfer happened correctly with exact amounts
        assertEq(
            aliceBalance,
            9.8 ether,
            "Alice should have exactly 9.8 tokens"
        );
        assertEq(
            maliciousBalance,
            netTransferred,
            "Malicious contract should have exactly 0.099 tokens"
        );
        assertEq(
            vault.balanceOf(vault.FEES_POOL()),
            0.101 ether,
            "Fees pool should have 0.101 tokens total"
        );
    }

    function testFenwickTreeWithZeroBalanceTransitions() public {
        // Test that Fenwick tree correctly handles accounts going to/from zero balance

        // Alice mints
        mintVault(alice, 1 ether);

        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 fenwick1 = vault.getSuffixSum(1);
        assertEq(fenwick1, aliceBalance, "Initial Fenwick incorrect");

        // Alice transfers entire balance to Bob (Alice goes to 0)
        vm.prank(alice);
        vault.transfer(bob, aliceBalance);

        // Alice should be removed from holders
        uint256 fenwick2 = vault.getSuffixSum(1);
        assertEq(
            fenwick2,
            vault.balanceOf(bob),
            "Fenwick should only track Bob"
        );

        // Alice mints again (goes from 0 to positive)
        mintVault(alice, 2 ether);

        // Both should be tracked now
        uint256 fenwick3 = vault.getSuffixSum(1);
        uint256 expectedTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(fenwick3, expectedTotal, "Fenwick should track both holders");
    }
}

// Helper contract for reentrancy test
contract MaliciousReentrant {
    GigaVault public vault;
    MockUSDmYLocal public usdmy;
    bool public attacked = false;

    constructor(GigaVault _vault, MockUSDmYLocal _usdmy) {
        vault = _vault;
        usdmy = _usdmy;
    }

    // Try to reenter when receiving tokens
    function onERC20Received(address, uint256) external returns (bytes4) {
        if (!attacked) {
            attacked = true;
            // Try to mint during a transfer (should fail due to reentrancy guard)
            usdmy.approve(address(vault), 1 ether);
            try vault.mint(1 ether) {
                // Should not reach here
            } catch {
                // Expected to fail
            }
        }
        return this.onERC20Received.selector;
    }

    receive() external payable {}
}
