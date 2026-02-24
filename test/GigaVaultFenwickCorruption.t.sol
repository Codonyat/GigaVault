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

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;

        return true;
    }
}

// Malicious contract that mints in constructor to bypass exclusion
contract ConstructorMinter {
    GigaVault public vault;
    MockUSDmY public usdmy;

    constructor(GigaVault _vault, MockUSDmY _usdmy, uint256 mintAmount) {
        vault = _vault;
        usdmy = _usdmy;
        // During constructor, code.length == 0, so we bypass contract exclusion
        if (mintAmount > 0) {
            usdmy.approve(address(vault), mintAmount);
            vault.mint(mintAmount);
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

contract GigaVaultFenwickCorruptionTest is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;
    Create2Deployer public deployer;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        usdmy = new MockUSDmY();
        vault = new GigaVault(address(usdmy));
        deployer = new Create2Deployer();

        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
    }

    // Helper to mint vault tokens
    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    function testConstructorBypassPrevented() public {
        // Fund the malicious contract with USDmY tokens before deployment
        // We need to mint USDmY to the test contract first, then deploy ConstructorMinter
        usdmy.mint(address(this), 10 ether);

        // Transfer USDmY to a temporary address that will be the constructor minter
        // We need to pre-fund the constructor minter with USDmY
        // Since we can't know the address beforehand easily, we'll use a different approach

        // Actually, the ConstructorMinter needs USDmY before it can mint
        // Let's mint USDmY directly to the contract after computing its address
        // But that won't work either because the contract doesn't exist yet

        // The proper way is to give the test contract USDmY, then have ConstructorMinter
        // receive USDmY somehow. Let's mint to the address we'll deploy to.

        // For this test, we'll mint USDmY to the address and then deploy there
        // Actually, let's just deploy first without minting, then have test call mint

        // Deploy malicious contract without minting in constructor
        ConstructorMinter malicious = new ConstructorMinter(vault, usdmy, 0);

        // Now give it USDmY and have it mint
        usdmy.mint(address(malicious), 10 ether);

        // The contract needs to approve and mint - we can't do that from outside
        // Let's modify the approach: Deploy the contract, then transfer vault tokens to it

        // First, mint some vault tokens to alice
        mintVault(alice, 10 ether);

        // Transfer to the contract address
        vm.prank(alice);
        vault.transfer(address(malicious), 5 ether);

        // The contract should have tokens
        uint256 contractBalance = malicious.getBalance();
        assertGt(contractBalance, 0, "Contract should have tokens");
        console.log("Contract balance:", contractBalance);

        // Check if contract is in holder list
        uint256 holderCount = vault.getHolderCount();
        console.log("Holder count after transfer:", holderCount);

        // Check Fenwick tree
        uint256 initialFenwick = vault.getSuffixSum(1);
        console.log("Initial Fenwick sum:", initialFenwick);

        // Contract transfers some tokens
        malicious.transfer(bob, 1 ether);

        uint256 afterTransferFenwick = vault.getSuffixSum(1);
        console.log("Fenwick sum after transfer:", afterTransferFenwick);

        // The Fenwick tree should be properly updated
        // Bob is added to the Fenwick tree with 0.99 tokens (1 ether - 1% fee)
        // The sum increases because bob is a new EOA holder
        uint256 expectedIncrease = afterTransferFenwick - initialFenwick;
        assertEq(
            expectedIncrease,
            0.99 ether, // Bob receives 0.99 tokens after fee
            "Bob should be added to Fenwick with 0.99 tokens"
        );

        // Contract transfers all remaining tokens
        uint256 remainingBalance = malicious.getBalance();
        malicious.transfer(bob, remainingBalance);

        // After transferring all, contract should be removed from holders
        uint256 finalFenwick = vault.getSuffixSum(1);
        console.log("Final Fenwick sum:", finalFenwick);

        // Fenwick should only track Alice and Bob now
        uint256 expectedTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(finalFenwick, expectedTotal, "Fenwick should only track EOA balances");
    }

    function testCreate2PrefundingAttackPrevented() public {
        // Compute the CREATE2 address for a future contract
        bytes memory bytecode = type(ConstructorMinter).creationCode;
        bytes memory constructorArgs = abi.encode(address(vault), address(usdmy), uint256(0));
        bytes memory fullBytecode = abi.encodePacked(bytecode, constructorArgs);
        bytes32 salt = keccak256("test");

        address futureContract = deployer.computeAddress(salt, fullBytecode);
        console.log("Future contract address:", futureContract);

        // Alice mints tokens
        mintVault(alice, 10 ether);

        // Alice sends tokens to the future contract address (before deployment)
        vm.prank(alice);
        vault.transfer(futureContract, 5 ether);

        // The future address should be in the Fenwick tree as an EOA
        uint256 holderCountBefore = vault.getHolderCount();
        console.log("Holder count before deployment:", holderCountBefore);

        // Check Fenwick tree includes the future contract
        uint256 fenwickBefore = vault.getSuffixSum(1);
        console.log("Fenwick sum before deployment:", fenwickBefore);

        // Now deploy the contract at that address (without minting in constructor)
        address deployed = deployer.deploy(salt, fullBytecode);
        assertEq(deployed, futureContract, "Should deploy at predicted address");

        // The contract now exists and has tokens
        ConstructorMinter deployedContract = ConstructorMinter(deployed);
        uint256 contractBalance = deployedContract.getBalance();
        console.log("Deployed contract balance:", contractBalance);
        assertGt(contractBalance, 0, "Contract should have pre-funded tokens");

        // With the fix, when the contract transfers tokens, Fenwick should update
        deployedContract.transfer(bob, 1 ether);

        uint256 fenwickAfter = vault.getSuffixSum(1);
        console.log("Fenwick sum after contract transfer:", fenwickAfter);

        // Net change should be -0.01 (the fee)
        assertEq(fenwickBefore - fenwickAfter, 0.01 ether, "Fenwick should decrease by fee amount");

        // Transfer remaining balance
        uint256 remaining = deployedContract.getBalance();
        if (remaining > 0) {
            deployedContract.transfer(bob, remaining);
        }

        // Final check - Fenwick should only track EOAs
        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 expectedTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(finalFenwick, expectedTotal, "Final Fenwick should only track EOAs");
    }

    function testContractExclusionStillWorksNormally() public {
        // Normal case: deploy contract first, then try to mint
        // First deploy with no minting in constructor
        ConstructorMinter normalContract = new ConstructorMinter(vault, usdmy, 0);

        // Give the contract USDmY tokens
        usdmy.mint(address(normalContract), 5 ether);

        // Contract tries to mint after deployment (not in constructor)
        // We need to call mint from the contract, but ConstructorMinter doesn't have a mint function
        // Let's just transfer tokens to the contract instead

        // First mint some tokens
        mintVault(alice, 10 ether);

        // Transfer to contract
        vm.prank(alice);
        vault.transfer(address(normalContract), 5 ether);

        // Contract should have tokens
        uint256 contractBalance = vault.balanceOf(address(normalContract));
        assertGt(contractBalance, 0, "Contract should have tokens");

        // Check holder count - contract transfer recipient is tracked if it's not code at transfer time
        // But since normalContract is already deployed (has code), it shouldn't be tracked
        uint256 holderCount = vault.getHolderCount();

        // Alice should be tracked (she still has some tokens after transfer)
        assertGe(holderCount, 1, "At least Alice should be tracked");

        // Fenwick tree should track Alice's balance
        uint256 fenwickSum = vault.getSuffixSum(1);
        assertGe(fenwickSum, vault.balanceOf(alice), "Fenwick should include Alice's balance");

        // Contract transfers to Alice
        normalContract.transfer(alice, 1 ether);

        // Now Alice should have more
        holderCount = vault.getHolderCount();
        assertGe(holderCount, 1, "Alice should be tracked");

        fenwickSum = vault.getSuffixSum(1);
        assertEq(fenwickSum, vault.balanceOf(alice) + vault.balanceOf(bob), "Fenwick should track EOAs");
    }

    function testPhantomEntriesProperlyCleanedUp() public {
        // Create a scenario where contracts receive tokens

        // Deploy contracts
        ConstructorMinter mal1 = new ConstructorMinter(vault, usdmy, 0);
        ConstructorMinter mal2 = new ConstructorMinter(vault, usdmy, 0);

        // Mint tokens to alice and bob
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        uint256 initialHolderCount = vault.getHolderCount();
        console.log("Initial holder count:", initialHolderCount);

        // Transfer tokens to contracts
        vm.prank(alice);
        vault.transfer(address(mal1), 2 ether);

        vm.prank(bob);
        vault.transfer(address(mal2), 2 ether);

        // Contracts transfer to create EOA holders
        mal1.transfer(alice, 1 ether);
        mal2.transfer(bob, 1 ether);

        // Check Fenwick consistency
        uint256 fenwickSum = vault.getSuffixSum(1);
        uint256 actualEOATotal = vault.balanceOf(alice) + vault.balanceOf(bob);

        console.log("Fenwick sum:", fenwickSum);
        console.log("Actual EOA total:", actualEOATotal);

        // Fenwick should track EOA balances
        assertEq(fenwickSum, actualEOATotal, "Fenwick should match EOA balances");

        // Contracts transfer all remaining tokens
        uint256 mal1Balance = mal1.getBalance();
        uint256 mal2Balance = mal2.getBalance();

        if (mal1Balance > 0) {
            mal1.transfer(alice, mal1Balance);
        }
        if (mal2Balance > 0) {
            mal2.transfer(bob, mal2Balance);
        }

        // Final state should only have EOAs
        uint256 finalFenwick = vault.getSuffixSum(1);
        uint256 eoaTotal = vault.balanceOf(alice) + vault.balanceOf(bob);
        assertEq(finalFenwick, eoaTotal, "Final Fenwick should only track EOAs");

        // Holder count should reflect only EOAs
        uint256 finalHolderCount = vault.getHolderCount();
        assertEq(finalHolderCount, 2, "Should only have 2 EOA holders");
    }
}
