// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {GigaVaultTestBase, MockContract} from "./helpers/GigaVaultTestBase.sol";

contract GigaVaultMintingTest is GigaVaultTestBase {
    function testMintingWithFee() public {
        uint256 usdmyAmount = 1 ether;
        uint256 expectedTokens = (usdmyAmount * 99) / 100;
        uint256 expectedFee = usdmyAmount / 100;

        mintVault(alice, usdmyAmount);

        assertEq(vault.balanceOf(alice), expectedTokens);
        assertEq(vault.balanceOf(vault.FEES_POOL()), expectedFee);
        assertEq(vault.getReserve(), usdmyAmount);
    }

    function testRedeemWithFee() public {
        mintVault(alice, 10 ether);

        uint256 initialBalance = vault.balanceOf(alice);
        uint256 redeemAmount = 1 ether;
        uint256 expectedFee = 0.01 ether;
        uint256 netRedeemed = redeemAmount - expectedFee;
        uint256 expectedUsdmy = netRedeemed;

        uint256 aliceUsdmyBefore = usdmy.balanceOf(alice);

        vm.expectEmit(true, true, true, true);
        emit Redeemed(alice, redeemAmount, expectedUsdmy, expectedFee);

        vm.prank(alice);
        vault.redeem(redeemAmount);

        assertEq(vault.balanceOf(alice), initialBalance - redeemAmount);
        assertEq(usdmy.balanceOf(alice) - aliceUsdmyBefore, expectedUsdmy);
    }

    function testMintingPeriodEnforcement() public {
        mintVault(alice, 1 ether);
        assertGt(vault.balanceOf(alice), 0);

        skipPastMintingPeriod();

        vm.startPrank(bob);
        usdmy.approve(address(vault), 1 ether);
        vm.expectRevert("Max supply reached");
        vault.mint(1 ether);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(0.1 ether);

        mintVault(bob, 0.09 ether);
        assertGt(vault.balanceOf(bob), 0);
    }

    function testCannotMintAfterPeriodWithoutCapacity() public {
        mintVault(alice, 10 ether);

        skipPastMintingPeriod();

        vm.startPrank(bob);
        usdmy.approve(address(vault), 1 ether);
        vm.expectRevert("Max supply reached");
        vault.mint(1 ether);
        vm.stopPrank();

        vm.prank(alice);
        vault.redeem(1 ether);

        mintVault(bob, 0.9 ether);
        assertGt(vault.balanceOf(bob), 0);
    }

    function testRedeemingAllTokensDepletesContractUsdmy() public {
        mintVault(alice, 10 ether);
        mintVault(bob, 10 ether);

        uint256 aliceBalance = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceBalance);

        uint256 bobBalance = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(bobBalance);

        assertTrue(vault.getReserve() < 1 ether);
    }

    function testMaxSupplyNeverExceededWithBeneficiaryDonations() public {
        address beneficiary1 = address(0x1001);
        address beneficiary2 = address(0x1002);
        address[] memory beneficiaries = new address[](2);
        beneficiaries[0] = beneficiary1;
        beneficiaries[1] = beneficiary2;

        usdmy.mint(beneficiary1, 100 ether);
        usdmy.mint(beneficiary2, 100 ether);

        mintVault(alice, 100 ether);

        vm.warp(block.timestamp + 8 days);

        vm.prank(alice);
        vault.redeem(1 ether);

        uint256 maxSupply = vault.maxSupplyEver();
        assertEq(maxSupply, 100 ether);

        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            vault.transfer(bob, 1 ether);

            vm.warp(block.timestamp + 25 hours + 61);
            vault.executeLottery();
        }

        mintVault(bob, 0.9 ether);

        uint256 totalSupply = vault.totalSupply();
        assertLe(totalSupply, maxSupply, "Total supply should not exceed max");
    }

    function testUsdmyDonations() public {
        uint256 initialContractBalance = vault.getReserve();

        uint256 donationAmount = 5 ether;

        vm.prank(alice);
        usdmy.transfer(address(vault), donationAmount);

        assertEq(
            vault.getReserve(),
            initialContractBalance + donationAmount,
            "Contract balance should increase by donation amount"
        );

        assertEq(
            vault.balanceOf(alice),
            0,
            "No tokens should be minted for donations"
        );
        assertEq(
            vault.totalSupply(),
            0,
            "Total supply should remain unchanged"
        );
    }

    function testContractsCanTransferTokens() public {
        MockContract mockContract = new MockContract(usdmy);
        usdmy.mint(address(mockContract), 10 ether);

        mockContract.mintVault(vault, 1 ether);
        assertEq(vault.balanceOf(address(mockContract)), 0.99 ether);

        assertFalse(vault.isHolder(address(mockContract)));

        address testAlice = address(0x1234);
        mockContract.transferVault(vault, testAlice, 0.1 ether);

        assertEq(
            vault.balanceOf(testAlice),
            0.099 ether,
            "Alice should receive 0.099 after 1% fee"
        );
        assertEq(
            vault.balanceOf(address(mockContract)),
            0.89 ether,
            "Contract should have 0.89 left"
        );

        assertTrue(vault.isHolder(testAlice), "testAlice should be tracked as holder");

        MockContract secondContract = new MockContract(usdmy);
        mockContract.transferVault(
            vault,
            address(secondContract),
            0.2 ether
        );

        assertEq(
            vault.balanceOf(address(secondContract)),
            0.198 ether,
            "Second contract should receive 0.198 after fee"
        );
        assertEq(
            vault.balanceOf(address(mockContract)),
            0.69 ether,
            "First contract should have 0.69 left"
        );

        assertFalse(
            vault.isHolder(address(secondContract)),
            "Second contract should not be tracked"
        );

        mockContract.approveVault(
            vault,
            address(secondContract),
            0.3 ether
        );
        assertEq(
            vault.allowance(address(mockContract), address(secondContract)),
            0.3 ether
        );

        secondContract.transferFromVault(
            vault,
            address(mockContract),
            testAlice,
            0.3 ether
        );

        assertEq(
            vault.balanceOf(testAlice),
            0.099 ether + 0.297 ether,
            "testAlice should have original 0.099 + 0.297 from transferFrom"
        );
        assertEq(
            vault.balanceOf(address(mockContract)),
            0.39 ether,
            "First contract should have 0.39 left"
        );

        assertEq(
            vault.getHolderCount(),
            1,
            "Only testAlice should be counted as holder"
        );

        vm.warp(block.timestamp + 8 days);

        mockContract.transferVault(vault, testAlice, 0.1 ether);

        vm.warp(block.timestamp + 25 hours + 61);
        vault.executeLottery();

        uint256 currentDay = vault.getCurrentDay();
        (address winner, ) = vault.lotteryUnclaimedPrizes(
            (currentDay - 1) % 7
        );
        if (winner != address(0)) {
            assertEq(
                winner,
                testAlice,
                "Winner must be testAlice, the only EOA holder"
            );
        }
    }

    function testMinimumMintAmountAfterMintingPeriod() public {
        mintVault(alice, 1 ether);
        mintVault(bob, 1 ether);

        skipPastMintingPeriod();

        vm.prank(alice);
        vault.transfer(bob, 0.01 ether);

        assertEq(
            vault.maxSupplyEver(),
            2 ether,
            "Max supply should be 2 USDmore"
        );

        vm.prank(alice);
        vault.redeem(0.5 ether);

        usdmy.mint(address(this), 10000 ether);
        usdmy.transfer(address(vault), 10000 ether);

        vm.startPrank(charlie);
        usdmy.approve(address(vault), 1 wei);
        vm.expectRevert("Minimum mint amount is 100 wei");
        vault.mint(1 wei);
        vm.stopPrank();

        vm.startPrank(charlie);
        usdmy.approve(address(vault), 658000 wei);
        vm.expectRevert("Minimum mint amount is 100 wei");
        vault.mint(658000 wei);
        vm.stopPrank();

        vm.startPrank(charlie);
        usdmy.approve(address(vault), 665000 wei);
        vault.mint(665000 wei);
        vm.stopPrank();

        uint256 charlieBalance = vault.balanceOf(charlie);
        assertEq(
            charlieBalance,
            99,
            "Charlie should have exactly 99 wei after fee"
        );
    }
}
