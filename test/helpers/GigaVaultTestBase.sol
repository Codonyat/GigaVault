// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GigaVault} from "../.././src/GigaVault.sol";

abstract contract GigaVaultTestBase is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;

    // Common test addresses
    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public david = address(0x4);
    address public eve = address(0x5);

    // Events for testing
    event Minted(
        address indexed user,
        uint256 usdmyAmount,
        uint256 userTokens,
        uint256 feeTokens
    );
    event Redeemed(
        address indexed user,
        uint256 tokenAmount,
        uint256 usdmyAmount,
        uint256 fee
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event LotteryWon(address indexed winner, uint256 amount, uint256 indexed day);
    event AuctionWon(
        address indexed winner,
        uint256 tokenAmount,
        uint256 collateralPaid,
        uint256 indexed day
    );
    event BeneficiaryFunded(
        address indexed beneficiary,
        uint256 amount,
        address originalWinner
    );

    function setUp() public virtual {
        // Deploy mock USDmY token
        usdmy = new MockUSDmY();

        // Deploy GigaVault with USDmY token address
        vault = new GigaVault(address(usdmy));

        // Fund test accounts with ETH (for gas) and USDmY tokens
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(charlie, 100 ether);
        vm.deal(david, 100 ether);
        vm.deal(eve, 100 ether);

        // Give each test account USDmY tokens
        usdmy.mint(alice, 100 ether);
        usdmy.mint(bob, 100 ether);
        usdmy.mint(charlie, 100 ether);
        usdmy.mint(david, 100 ether);
        usdmy.mint(eve, 100 ether);
    }

    // Helper function to move time forward by days
    function skipDays(uint256 numDays) internal {
        vm.warp(block.timestamp + numDays * 25 hours);
    }

    // Helper function to move to next day and past the 1-minute mark
    function moveToNextDay() internal {
        vm.warp(block.timestamp + 25 hours + 61);
    }

    // Helper function to skip past the minting period
    function skipPastMintingPeriod() internal {
        uint256 mintingPeriod = vault.MINTING_PERIOD();
        vm.warp(block.timestamp + mintingPeriod + 1 days);
    }

    // Helper to approve USDmY and mint vault tokens
    function mintVault(address user, uint256 usdmyAmount) internal {
        vm.startPrank(user);
        usdmy.approve(address(vault), usdmyAmount);
        vault.mint(usdmyAmount);
        vm.stopPrank();
    }

    // Helper function to set up basic holders
    function setupBasicHolders() internal {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);
        mintVault(charlie, 2 ether);
    }
}

// MockUSDmY is a simple ERC20 token for testing
contract MockUSDmY {
    string public name = "Mock USDmY";
    string public symbol = "USDmY";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    // Mint tokens to a specific address (for testing)
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
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

        emit Transfer(from, to, amount);
        return true;
    }
}

// Common mock contracts used across tests
contract MockContract {
    MockUSDmY public usdmy;

    constructor(MockUSDmY _usdmy) {
        usdmy = _usdmy;
    }

    function mintVault(GigaVault _vault, uint256 amount) external {
        usdmy.approve(address(_vault), amount);
        _vault.mint(amount);
    }

    function transferVault(
        GigaVault _vault,
        address to,
        uint256 amount
    ) external {
        _vault.transfer(to, amount);
    }

    function approveVault(
        GigaVault _vault,
        address spender,
        uint256 amount
    ) external {
        _vault.approve(spender, amount);
    }

    function transferFromVault(
        GigaVault _vault,
        address from,
        address to,
        uint256 amount
    ) external {
        _vault.transferFrom(from, to, amount);
    }

    receive() external payable {}
}

// Contract that rejects native transfers
contract MockRejectNative {
    // No receive or fallback function - will reject native transfers
}

// Attack contract for reentrancy tests
contract ReentrancyAttacker {
    GigaVault public target;
    MockUSDmY public usdmy;
    uint256 public attackCount;
    bool public attacking;

    constructor(GigaVault _target, MockUSDmY _usdmy) {
        target = _target;
        usdmy = _usdmy;
    }

    function attack(uint256 amount) external {
        attacking = true;
        usdmy.approve(address(target), amount);
        target.mint(amount);
    }

    receive() external payable {
        if (attacking && attackCount < 1) {
            attackCount++;
            // Try to mint again during the callback
            uint256 balance = usdmy.balanceOf(address(this));
            if (balance >= 1 ether) {
                usdmy.approve(address(target), 1 ether);
                target.mint(1 ether);
            }
        }
    }
}
