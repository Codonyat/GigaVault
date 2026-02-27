// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GigaVault} from "../.././src/GigaVault.sol";

abstract contract GigaVaultTestBase is Test {
    GigaVault public vault;
    MockUSDmY public usdmy;
    MockUSDm public usdm;

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
        // Deploy and etch MockUSDm FIRST (at the hardcoded USDM address)
        MockUSDm mockUsdmImpl = new MockUSDm();
        vm.etch(0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7, address(mockUsdmImpl).code);
        usdm = MockUSDm(0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7);

        // Deploy and etch MockUSDmY SECOND (at the hardcoded USDMY address)
        // Must be after MockUSDm since MockUSDmY.asset() references USDM address
        MockUSDmY mockImpl = new MockUSDmY();
        vm.etch(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890, address(mockImpl).code);
        usdmy = MockUSDmY(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890);

        // Deploy GigaVault (uses hardcoded USDmY and USDM constants)
        vault = new GigaVault();

        // Fund test accounts with ETH (for gas) and both USDm and USDmY tokens
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

        // Give each test account USDm tokens
        usdm.mint(alice, 100 ether);
        usdm.mint(bob, 100 ether);
        usdm.mint(charlie, 100 ether);
        usdm.mint(david, 100 ether);
        usdm.mint(eve, 100 ether);

        // Fund the MockUSDmY contract with USDm backing so redeem() works
        usdm.mint(address(usdmy), 1000 ether);
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

    // Helper to approve USDm and mint vault tokens via mintWithUSDm
    function mintVaultWithUSDm(address user, uint256 usdmAmount) internal {
        vm.startPrank(user);
        usdm.approve(address(vault), usdmAmount);
        vault.mintWithUSDm(usdmAmount);
        vm.stopPrank();
    }

    // Helper function to set up basic holders
    function setupBasicHolders() internal {
        mintVault(alice, 10 ether);
        mintVault(bob, 5 ether);
        mintVault(charlie, 2 ether);
    }

    // Helper to place a USDmY bid in the current auction
    function placeBid(address bidder, uint256 bidAmount) internal {
        vm.startPrank(bidder);
        usdmy.approve(address(vault), bidAmount);
        vault.bid(bidAmount);
        vm.stopPrank();
    }

    // Helper to donate USDmY directly to the vault (increases reserve without minting)
    function donateUsdmy(address donor, uint256 amount) internal {
        vm.prank(donor);
        usdmy.transfer(address(vault), amount);
    }

    // Helper to set up an auction: mint, skip minting period, generate fees, trigger lottery/auction
    function setupAuction() internal {
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 1 ether);

        vm.warp(block.timestamp + 25 hours + 1 minutes);
        vault.executeLottery();
    }
}

// MockUSDm is a simple ERC20 token for testing (the underlying stablecoin)
contract MockUSDm {
    string public name = "Mock USDm";
    string public symbol = "USDm";
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

// MockUSDmY is an ERC20 token with ERC4626 vault functions for testing
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

    // ── ERC4626 functions ──

    /// @dev Returns the underlying asset (USDm) address
    function asset() external pure returns (address) {
        return 0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;
    }

    /// @dev Deposit USDm assets and mint USDmY shares 1:1
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        // Transfer USDm from caller to this contract
        MockUSDm usdm = MockUSDm(0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7);
        require(usdm.allowance(msg.sender, address(this)) >= assets, "Insufficient USDm allowance");
        require(usdm.balanceOf(msg.sender) >= assets, "Insufficient USDm balance");

        // Use transferFrom to move USDm from caller
        usdm.transferFrom(msg.sender, address(this), assets);

        // Mint USDmY shares 1:1
        shares = assets;
        balanceOf[receiver] += shares;
        totalSupply += shares;
        emit Transfer(address(0), receiver, shares);
    }

    /// @dev Redeem USDmY shares for USDm assets 1:1
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        require(balanceOf[owner] >= shares, "Insufficient USDmY balance");

        if (owner != msg.sender) {
            require(allowance[owner][msg.sender] >= shares, "Insufficient allowance");
            allowance[owner][msg.sender] -= shares;
        }

        // Burn USDmY shares
        balanceOf[owner] -= shares;
        totalSupply -= shares;
        emit Transfer(owner, address(0), shares);

        // Transfer USDm assets 1:1 to receiver
        assets = shares;
        MockUSDm usdm = MockUSDm(0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7);
        usdm.transfer(receiver, assets);
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
