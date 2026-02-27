// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract} from "./helpers/GigaVaultTestBase.sol";
import {GigaVault} from "../src/GigaVault.sol";
import {console} from "forge-std/Test.sol";

// Malicious contract that mints in constructor to bypass exclusion
contract ConstructorMinter {
    GigaVault public vault;

    constructor(GigaVault _vault, address _usdmy, uint256 mintAmount) {
        vault = _vault;
        if (mintAmount > 0) {
            // Approve and mint during constructor (code.length == 0)
            (bool ok,) = _usdmy.call(abi.encodeWithSignature("approve(address,uint256)", address(_vault), mintAmount));
            require(ok, "approve failed");
            _vault.mint(mintAmount);
        }
    }

    function transfer(address to, uint256 amount) external {
        vault.transfer(to, amount);
    }

    function getBalance() external view returns (uint256) {
        return vault.balanceOf(address(this));
    }
}

// Contract for CREATE2 deployment
contract Create2Deployer {
    function deploy(bytes32 salt, bytes memory bytecode) external returns (address) {
        address addr;
        assembly {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        require(addr != address(0), "Create2: Failed on deploy");
        return addr;
    }

    function computeAddress(bytes32 salt, bytes memory bytecode) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode))
        );
        return address(uint160(uint256(hash)));
    }
}

// Helper contract for reentrancy test
contract MaliciousReentrant {
    GigaVault public vault;
    address public usdmyAddr;
    bool public attacked = false;

    constructor(GigaVault _vault, address _usdmy) {
        vault = _vault;
        usdmyAddr = _usdmy;
    }

    function onERC20Received(address, uint256) external returns (bytes4) {
        if (!attacked) {
            attacked = true;
            (bool ok,) = usdmyAddr.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), uint256(1 ether)));
            if (ok) {
                try vault.mint(1 ether) {} catch {}
            }
        }
        return this.onERC20Received.selector;
    }

    receive() external payable {}
}

contract GigaVaultFenwickTest is GigaVaultTestBase {
    Create2Deployer public deployer;

    function setUp() public override {
        super.setUp();
        deployer = new Create2Deployer();
    }

    // ============ Core Fenwick Tree Tests (4) ============

    function testFenwickTreeCumulativeSums() public {
        mintVault(alice, 1 ether); // 0.99 tokens
        mintVault(bob, 2 ether); // 1.98 tokens
        mintVault(charlie, 3 ether); // 2.97 tokens

        uint256 cumSum1 = vault.getSuffixSum(1);
        uint256 cumSum2 = vault.getSuffixSum(2);
        uint256 cumSum3 = vault.getSuffixSum(3);

        assertEq(cumSum1, 5.94 ether, "Suffix sum from index 1 should be total (5.94)");
        assertEq(cumSum2, 1.98 ether + 2.97 ether, "Suffix sum from index 2 should be 4.95");
        assertEq(cumSum3, 2.97 ether, "Suffix sum from index 3 should be 2.97");
    }

    function testFenwickTreeConsistencyAfterOperations() public {
        mintVault(alice, 5 ether);
        mintVault(bob, 3 ether);

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.prank(bob);
        vault.transfer(charlie, 0.5 ether);

        mintVault(david, 2 ether);

        uint256 totalFromFenwick = vault.getSuffixSum(1);
        uint256 expectedHolderTotal = vault.balanceOf(alice) + vault.balanceOf(bob)
            + vault.balanceOf(charlie) + vault.balanceOf(david);

        assertEq(totalFromFenwick, expectedHolderTotal, "Fenwick total should match sum of holder balances");
    }

    function testHolderTracking() public {
        assertEq(vault.getHolderCount(), 0);

        mintVault(alice, 1 ether);
        assertEq(vault.getHolderCount(), 1);
        assertTrue(vault.isHolder(alice));

        mintVault(bob, 1 ether);
        assertEq(vault.getHolderCount(), 2);
        assertTrue(vault.isHolder(bob));

        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        vault.transfer(bob, aliceBalance);

        assertFalse(vault.isHolder(alice));
        assertTrue(vault.isHolder(bob));
    }

    function testPackedStorageOptimization() public {
        uint256 numHolders = 50;

        for (uint256 i = 0; i < numHolders; i++) {
            address holder = address(uint160(0x1000 + i));
            usdmy.mint(holder, 1 ether);
            vm.startPrank(holder);
            usdmy.approve(address(vault), 0.1 ether);
            vault.mint(0.1 ether);
            vm.stopPrank();
        }

        assertEq(vault.getHolderCount(), numHolders);

        for (uint256 i = 1; i <= numHolders; i++) {
            (address holder, uint256 balance) = vault.getHolderByIndex(i);
            assertEq(holder, address(uint160(0x1000 + i - 1)));
            assertEq(balance, 0.099 ether);
        }
    }

    // ============ Fenwick Corruption Prevention Tests (4) ============

    function testConstructorBypassPrevented() public {
        // Deploy malicious contract without minting in constructor
        ConstructorMinter malicious = new ConstructorMinter(vault, address(usdmy), 0);

        // Give it USDmY
        usdmy.mint(address(malicious), 10 ether);

        // Mint vault tokens to alice
        mintVault(alice, 10 ether);

        // Transfer to the contract
        vm.prank(alice);
        vault.transfer(address(malicious), 5 ether);

        uint256 contractBalance = malicious.getBalance();
        assertGt(contractBalance, 0, "Contract should have tokens");

        uint256 initialFenwick = vault.getSuffixSum(1);

        // Contract transfers some tokens to bob
        malicious.transfer(bob, 1 ether);

        uint256 afterTransferFenwick = vault.getSuffixSum(1);

        // Bob is added to the Fenwick tree with 0.99 tokens
        uint256 expectedIncrease = afterTransferFenwick - initialFenwick;
        assertEq(expectedIncrease, 0.99 ether, "Bob should be added to Fenwick with 0.99 tokens");

        // Contract transfers all remaining tokens
        uint256 remainingBalance = malicious.getBalance();
        malicious.transfer(bob, remainingBalance);

        // Fenwick should only track Alice and Bob now
        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 expectedTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(finalFenwick, expectedTotal, "Fenwick should only track EOA balances");
    }

    function testCreate2PrefundingAttackPrevented() public {
        // Compute CREATE2 address for a future contract
        bytes memory bytecode = type(ConstructorMinter).creationCode;
        bytes memory constructorArgs = abi.encode(address(vault), address(usdmy), uint256(0));
        bytes memory fullBytecode = abi.encodePacked(bytecode, constructorArgs);
        bytes32 salt = keccak256("test");

        address futureContract = deployer.computeAddress(salt, fullBytecode);

        mintVault(alice, 10 ether);

        // Send tokens to the future contract address (before deployment)
        vm.prank(alice);
        vault.transfer(futureContract, 5 ether);

        uint256 fenwickBefore = vault.getSuffixSum(1);

        // Deploy the contract at that address
        address deployed = deployer.deploy(salt, fullBytecode);
        assertEq(deployed, futureContract, "Should deploy at predicted address");

        ConstructorMinter deployedContract = ConstructorMinter(deployed);
        assertGt(deployedContract.getBalance(), 0, "Contract should have pre-funded tokens");

        // Contract transfers tokens — Fenwick should update
        deployedContract.transfer(bob, 1 ether);

        uint256 fenwickAfter = vault.getSuffixSum(1);
        assertEq(fenwickBefore - fenwickAfter, 0.01 ether, "Fenwick should decrease by fee amount");

        // Transfer remaining balance
        uint256 remaining = deployedContract.getBalance();
        if (remaining > 0) {
            deployedContract.transfer(bob, remaining);
        }

        // Fenwick should only track EOAs
        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 expectedTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(finalFenwick, expectedTotal, "Final Fenwick should only track EOAs");
    }

    function testContractExclusionStillWorksNormally() public {
        // Deploy contract first, then try to interact
        ConstructorMinter normalContract = new ConstructorMinter(vault, address(usdmy), 0);
        usdmy.mint(address(normalContract), 5 ether);

        mintVault(alice, 10 ether);

        // Transfer to contract (already deployed, has code)
        vm.prank(alice);
        vault.transfer(address(normalContract), 5 ether);

        uint256 contractBalance = vault.balanceOf(address(normalContract));
        assertGt(contractBalance, 0, "Contract should have tokens");

        uint256 holderCount = vault.getHolderCount();
        assertGe(holderCount, 1, "At least Alice should be tracked");

        uint256 fenwickSum = vault.getSuffixSum(1);
        assertGe(fenwickSum, vault.balanceOf(alice), "Fenwick should include Alice's balance");

        // Contract transfers to Alice
        normalContract.transfer(alice, 1 ether);

        fenwickSum = vault.getSuffixSum(1);
        assertEq(fenwickSum, vault.balanceOf(alice) + vault.balanceOf(bob), "Fenwick should track EOAs");
    }

    function testPhantomEntriesProperlyCleanedUp() public {
        ConstructorMinter mal1 = new ConstructorMinter(vault, address(usdmy), 0);
        ConstructorMinter mal2 = new ConstructorMinter(vault, address(usdmy), 0);

        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        // Transfer tokens to contracts
        vm.prank(alice);
        vault.transfer(address(mal1), 2 ether);
        vm.prank(bob);
        vault.transfer(address(mal2), 2 ether);

        // Contracts transfer back to EOAs
        mal1.transfer(alice, 1 ether);
        mal2.transfer(bob, 1 ether);

        uint256 fenwickSum = vault.getSuffixSum(1);
        uint256 actualEOATotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(fenwickSum, actualEOATotal, "Fenwick should match EOA balances");

        // Contracts transfer all remaining tokens
        uint256 mal1Balance = mal1.getBalance();
        uint256 mal2Balance = mal2.getBalance();
        if (mal1Balance > 0) mal1.transfer(alice, mal1Balance);
        if (mal2Balance > 0) mal2.transfer(bob, mal2Balance);

        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 eoaTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(finalFenwick, eoaTotal, "Final Fenwick should only track EOAs");

        uint256 finalHolderCount = vault.getHolderCount();
        assertEq(finalHolderCount, 2, "Should only have 2 EOA holders");
    }

    // ============ Atomicity Tests (5) ============

    function testFenwickTreeAtomicityDuringTransfers() public {
        mintVault(alice, 10 ether);
        assertEq(vault.balanceOf(alice), 9.9 ether, "Alice should have 9.9 tokens");

        mintVault(bob, 5 ether);
        assertEq(vault.balanceOf(bob), 4.95 ether, "Bob should have 4.95 tokens");

        mintVault(charlie, 3 ether);
        assertEq(vault.balanceOf(charlie), 2.97 ether, "Charlie should have 2.97 tokens");

        uint256 initialSuffix1 = vault.getSuffixSum(1);
        uint256 expectedInitialTotal = 9.9 ether + 4.95 ether + 2.97 ether;
        assertEq(initialSuffix1, expectedInitialTotal, "Initial Fenwick sum should be 17.82 tokens");

        vm.startPrank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, bob, 0.099 ether);
        vault.transfer(bob, 0.1 ether);
        assertEq(vault.balanceOf(alice), 9.8 ether, "Alice should have 9.8 tokens after first transfer");
        assertEq(vault.balanceOf(bob), 5.049 ether, "Bob should have 5.049 tokens");

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, charlie, 0.198 ether);
        vault.transfer(charlie, 0.2 ether);
        assertEq(vault.balanceOf(alice), 9.6 ether, "Alice should have 9.6 tokens after second transfer");
        assertEq(vault.balanceOf(charlie), 3.168 ether, "Charlie should have 3.168 tokens");
        vm.stopPrank();

        uint256 afterSuffix1 = vault.getSuffixSum(1);
        uint256 expectedAfterTotal = 9.6 ether + 5.049 ether + 3.168 ether;
        assertEq(afterSuffix1, expectedAfterTotal, "Fenwick sum should be 17.817 tokens after transfers");
    }

    function testFenwickTreeAtomicityDuringMintAndBurn() public {
        mintVault(alice, 10 ether);
        assertEq(vault.balanceOf(alice), 9.9 ether, "Alice should have 9.9 tokens");

        uint256 suffix1AfterMint = vault.getSuffixSum(1);
        assertEq(suffix1AfterMint, 9.9 ether, "Fenwick should be 9.9 after mint");

        // Move past minting period
        vm.warp(block.timestamp + vault.MINTING_PERIOD() + 1 days);

        uint256 redeemAmount = 0.1 ether;
        uint256 redeemFee = 0.001 ether;
        uint256 netRedeemed = 0.099 ether;

        vm.expectEmit(true, true, true, true);
        emit Redeemed(alice, redeemAmount, netRedeemed, redeemFee);
        vm.prank(alice);
        vault.redeem(redeemAmount);
        assertEq(vault.balanceOf(alice), 9.8 ether, "Alice should have 9.8 tokens after redeem");

        uint256 suffix1AfterRedeem = vault.getSuffixSum(1);
        assertEq(suffix1AfterRedeem, 9.8 ether, "Fenwick should be 9.8 after redeem");

        // Add another holder after minting period
        uint256 mintAmount = 0.0001 ether;
        uint256 expectedTokens = (mintAmount * vault.totalSupply()) / vault.getReserve();
        uint256 expectedFee = expectedTokens / 100;
        uint256 expectedNet = expectedTokens - expectedFee;

        mintVault(bob, mintAmount);
        assertEq(vault.balanceOf(bob), expectedNet, "Bob should have expected tokens");

        uint256 finalSuffix1 = vault.getSuffixSum(1);
        uint256 expectedFinal = 9.8 ether + expectedNet;
        assertEq(finalSuffix1, expectedFinal, "Fenwick should be correct with both holders");
    }

    function testFenwickTreeAtomicityDuringComplexOperations() public {
        address[10] memory users;
        for (uint256 i = 0; i < 10; i++) {
            users[i] = address(uint160(0x100 + i));
            usdmy.mint(users[i], 10 ether);
            vm.startPrank(users[i]);
            usdmy.approve(address(vault), 1 ether);
            vault.mint(1 ether);
            vm.stopPrank();
        }

        uint256 totalSupply = vault.totalSupply();
        uint256 fenwickTotal = vault.getSuffixSum(1);
        assertTrue(fenwickTotal <= totalSupply, "Fenwick should not exceed total supply");

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

        uint256 expectedTotal = 0;
        for (uint256 i = 0; i < 10; i++) {
            expectedTotal += vault.balanceOf(users[i]);
        }

        uint256 finalFenwickTotal = vault.getSuffixSum(1);
        assertEq(finalFenwickTotal, expectedTotal, "Fenwick tree inconsistent after complex operations");
    }

    function testAtomicityWithReentrancy() public {
        MaliciousReentrant malicious = new MaliciousReentrant(vault, address(usdmy));
        usdmy.mint(address(malicious), 10 ether);

        mintVault(alice, 10 ether);

        uint256 initialFenwick = vault.getSuffixSum(1);
        assertEq(initialFenwick, vault.balanceOf(alice), "Initial Fenwick incorrect");

        uint256 transferAmount = 0.1 ether;
        uint256 netTransferred = 0.099 ether;

        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, address(malicious), netTransferred);
        vm.prank(alice);
        vault.transfer(address(malicious), transferAmount);

        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 maliciousBalance = vault.balanceOf(address(malicious));

        assertEq(finalFenwick, aliceBalance, "Fenwick should only track Alice (EOA)");
        assertEq(aliceBalance, 9.8 ether, "Alice should have exactly 9.8 tokens");
        assertEq(maliciousBalance, netTransferred, "Malicious contract should have exactly 0.099 tokens");
        assertEq(vault.balanceOf(vault.FEES_POOL()), 0.101 ether, "Fees pool should have 0.101 tokens total");
    }

    function testFenwickTreeWithZeroBalanceTransitions() public {
        mintVault(alice, 1 ether);

        uint256 aliceBalance = vault.balanceOf(alice);
        uint256 fenwick1 = vault.getSuffixSum(1);
        assertEq(fenwick1, aliceBalance, "Initial Fenwick incorrect");

        // Alice transfers entire balance to Bob (Alice goes to 0)
        vm.prank(alice);
        vault.transfer(bob, aliceBalance);

        uint256 fenwick2 = vault.getSuffixSum(1);
        assertEq(fenwick2, vault.balanceOf(bob), "Fenwick should only track Bob");

        // Alice mints again (goes from 0 to positive)
        mintVault(alice, 2 ether);

        uint256 fenwick3 = vault.getSuffixSum(1);
        uint256 expectedTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(fenwick3, expectedTotal, "Fenwick should track both holders");
    }
}
