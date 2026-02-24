// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title USDmYAddresses
/// @notice Centralized USDmY address lookup for all chains
library USDmYAddresses {
    // MegaETH USDmY addresses
    address public constant USDMY_MAINNET =
        0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890;

    /// @dev Returns the appropriate USDmY address for the current chain
    /// @return The USDmY address, or address(0) for unsupported chains (local testing)
    function getUSDmYAddress() internal view returns (address) {
        uint256 chainId = block.chainid;

        // MegaETH Mainnet chain ID
        if (chainId == 4326) {
            return USDMY_MAINNET;
        }
        // Local testing (Foundry default is 31337) or unsupported
        else {
            return address(0);
        }
    }

    /// @dev Returns the USDmY address or reverts for unsupported chains (for deployment)
    function getUSDmYAddressStrict() internal view returns (address) {
        address usdmy = getUSDmYAddress();
        require(usdmy != address(0), "Not a supported chain.");
        return usdmy;
    }
}
