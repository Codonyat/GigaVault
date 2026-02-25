// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVault} from "../.././src/GigaVault.sol";

// MockUSDmY is a simple ERC20 token for testing
// It has a mint function that anyone can call to get tokens
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

    // Mint tokens to the caller (for testing)
    function mint(uint256 amount) external {
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        emit Transfer(address(0), msg.sender, amount);
    }

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

    // Accept ETH and convert to USDmY tokens (simulates buying USDmY)
    // This is useful for tests that use vm.deal to give users ETH
    receive() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Transfer(address(0), msg.sender, msg.value);
    }
}

import {Test} from "forge-std/Test.sol";

abstract contract USDmYTestBase is Test {
    MockUSDmY public usdmy;

    function setupUSDmY() internal {
        // Deploy mock USDmY and etch its code to the hardcoded constant address
        MockUSDmY mockImpl = new MockUSDmY();
        vm.etch(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890, address(mockImpl).code);
        usdmy = MockUSDmY(payable(0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890));
    }

    function getUSDmYAndApprove(
        address user,
        address spender,
        uint256 amount
    ) internal {
        vm.startPrank(user);
        // Send ETH to MockUSDmY to get tokens (uses receive function)
        (bool success, ) = address(usdmy).call{value: amount}("");
        require(success, "Failed to get USDmY");
        usdmy.approve(spender, amount);
        vm.stopPrank();
    }

    // Helper function to skip past the minting period
    function skipPastMintingPeriod(GigaVault vault) internal {
        uint256 mintingPeriod = vault.MINTING_PERIOD();
        vm.warp(block.timestamp + mintingPeriod + 1 days);
    }
}
