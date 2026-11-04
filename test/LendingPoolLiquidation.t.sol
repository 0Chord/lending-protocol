// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";

/// @title 청산자의 USDC로 위험 부채를 완제하고 차입자의 WBTC 담보를 지급하는 검사
contract LendingPoolLiquidationTest is InterestTestBase {
    uint256 private constant Q = InterestMath.DENOMINATOR;

    /// @notice Charlie는 상한74 중73.5만 내고 WBTC0.96468750을 받으며 Bob의 잔여 담보를 보존한다.
    /// @dev 실제 공급·담보 입금·차입으로 준비하고 조회 이자와 저장 장부, 지분·현금·이벤트를 구분한다.
    function test_FullLiquidationUsesLiquidatorFundsAndPreservesSupplierRights() public {
        uint256 t0 = block.timestamp;
        assertEq(t0, 10_000);
        vm.prank(BOB);
        pool.borrow(70e6);
        uint256 executionTime = t0 + HALF_YEAR;
        vm.warp(executionTime);
        price.setPrice(80e8);
        price.setUpdatedAt(executionTime);
        usdc.mint(CHARLIE, 74e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 74e6);

        assertEq(usdc.balanceOf(CHARLIE), 74e6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 74e6);
        assertEq(wbtc.balanceOf(CHARLIE), 0);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.balanceOf(BOB), 0);
        assertEq(pool.debtOf(BOB), 73_500_000);
        assertEq(pool.totalDebt(), 73_500_000);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        assertEq(usdc.balanceOf(address(pool)), 30e6);
        assertEq(pool.availableLiquidity(), 30e6);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 103_500_000);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(usdc.totalSupply(), 174e6);
        assertEq(wbtc.totalSupply(), 1e8);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        _assertPosition(interestPool.storedDebt(BOB), 70e6, 0, t0);
        _assertPosition(interestPool.storedTotalDebt(), 70e6, 0, t0);
        _assertPosition(interestPool.storedDebt(CHARLIE), 0, 0, 0);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), 96_468_750);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.balanceOf(BOB), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.collateralOf(BOB), 3_531_250);
        assertEq(wbtc.balanceOf(address(pool)), 3_531_250);
        assertEq(usdc.balanceOf(address(pool)), 103_500_000);
        assertEq(pool.availableLiquidity(), 103_500_000);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 103_500_000);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(usdc.totalSupply(), 174e6);
        assertEq(wbtc.totalSupply(), 1e8);
        assertEq(interestPool.storedAssetsNumerator(), 103_500_000 * Q);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, executionTime);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, executionTime);
        _assertPosition(interestPool.storedDebt(CHARLIE), 0, 0, 0);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 73_500_000, 96_468_750);
    }

    /// @notice 실제 완제액70과 지급 담보0.91875가 max·min에 각각 같아도 전액 청산한다.
    function test_ExactRepaymentCapAndMinimumCollateralAreAllowed() public {
        _prepareNoInterestLiquidation(80e8);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 70e6, 91_875_000);

        _assertNoInterestCompletion(91_875_000, 8_125_000);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 70e6, 91_875_000);
    }

    /// @notice 최소 수령0도 양수 WBTC 지급을 허용하며 별도0요청 오류로 취급하지 않는다.
    function test_ZeroMinimumAllowsPositiveCollateralPayment() public {
        _prepareNoInterestLiquidation(80e8);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 70e6, 0);

        _assertNoInterestCompletion(91_875_000, 8_125_000);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 70e6, 91_875_000);
    }

    /// @notice 정확히 필요한 담보1을 모두 지급하고3600초 가격의 단일 외부 응답만 사용한다.
    function test_ExactCollateralCoverageUsesOnePriceAtMaximumAge() public {
        _prepareNoInterestLiquidation(7_350_000_000);
        price.setUpdatedAt(block.timestamp - 3600);
        vm.expectCall(address(price), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), uint64(1));

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 70e6, 1e8);

        _assertNoInterestCompletion(1e8, 0);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 70e6, 1e8);
    }

    /// @notice 이전 견적70·가격80 대신 실행 시점의 부채73.5·가격85로90_794_117만 지급한다.
    function test_ExecutionRecalculatesDebtAndPriceWithinCallersLimits() public {
        uint256 t0 = block.timestamp;
        vm.prank(BOB);
        pool.borrow(70e6);
        price.setPrice(80e8);
        assertEq(pool.debtOf(BOB), 70e6);
        (int256 previousPrice,) = price.latestPrice();
        assertEq(previousPrice, 80e8);
        vm.warp(t0 + HALF_YEAR);
        price.setPrice(85e8);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 74e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 74e6);
        _assertPosition(interestPool.storedDebt(BOB), 70e6, 0, t0);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 90_000_000);

        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), 90_794_117);
        assertEq(pool.collateralOf(BOB), 9_205_883);
        assertEq(wbtc.balanceOf(address(pool)), 9_205_883);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 103_500_000 * Q);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(pool.deposits(ALICE), 103_500_000);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 103_500_000);
        assertEq(pool.availableLiquidity(), 103_500_000);
        assertEq(usdc.totalSupply(), 174e6);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 73_500_000, 90_794_117);
    }

    /// @notice 청산으로 남은 Bob 담보는 가격 원천 장애 중에도 기존 담보 반환으로 따로 회수한다.
    function test_RemainingCollateralCanBeWithdrawnDuringPriceOutage() public {
        _prepareNoInterestLiquidation(80e8);
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 70e6, 91_875_000);
        _assertNoInterestCompletion(91_875_000, 8_125_000);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 70e6, 91_875_000);
        vm.mockCallRevert(
            address(price),
            abi.encodeCall(ICollateralPriceSource.latestPrice, ()),
            abi.encodeWithSignature("PriceUnavailable()")
        );

        vm.recordLogs();
        vm.prank(BOB);
        pool.withdrawCollateral(8_125_000);

        assertEq(pool.collateralOf(BOB), 0);
        assertEq(wbtc.balanceOf(BOB), 8_125_000);
        assertEq(wbtc.balanceOf(CHARLIE), 91_875_000);
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(pool.debtOf(BOB), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(usdc.totalSupply(), 170e6);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertEvent(vm.getRecordedLogs(), "CollateralWithdrawn(address,uint256)", BOB, 8_125_000);
    }

    /// @notice Bob도 자기 USDC70을 실제로 내고 담보 보상분을 받으며 잔여 담보 권리를 남긴다.
    function test_BorrowerCanLiquidateOwnPositionWithoutNetting() public {
        vm.prank(BOB);
        pool.borrow(70e6);
        price.setPrice(80e8);
        vm.prank(BOB);
        usdc.approve(address(pool), 70e6);

        vm.recordLogs();
        vm.prank(BOB);
        pool.liquidate(BOB, 70e6, 91_875_000);

        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.balanceOf(BOB), 91_875_000);
        assertEq(pool.collateralOf(BOB), 8_125_000);
        assertEq(wbtc.balanceOf(address(pool)), 8_125_000);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.shares(BOB), 0);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(wbtc.balanceOf(CHARLIE), 0);
        assertEq(usdc.totalSupply(), 100e6);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), BOB, BOB, 70e6, 91_875_000);
    }

    /// @notice 공급자 Alice도 별도로 준비한 USDC70을 내며 지분100과 환산 권리100을 보존한다.
    function test_SupplierCanLiquidateWithoutSpendingSupplyShares() public {
        vm.prank(BOB);
        pool.borrow(70e6);
        price.setPrice(80e8);
        usdc.mint(ALICE, 70e6);
        vm.prank(ALICE);
        usdc.approve(address(pool), 70e6);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.liquidate(BOB, 70e6, 91_875_000);

        assertEq(usdc.balanceOf(ALICE), 0);
        assertEq(usdc.allowance(ALICE, address(pool)), 0);
        assertEq(wbtc.balanceOf(ALICE), 91_875_000);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(pool.debtOf(ALICE), 0);
        _assertPosition(interestPool.storedDebt(ALICE), 0, 0, 0);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.balanceOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), 8_125_000);
        assertEq(wbtc.balanceOf(address(pool)), 8_125_000);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(usdc.totalSupply(), 170e6);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), ALICE, BOB, 70e6, 91_875_000);
    }

    /// @notice 공급자·차입자·청산자가 Alice 한 명이어도 실제 상환과 담보 지급을 하고 Bob 담보를 보존한다.
    function test_OneAddressCanBeSupplierBorrowerAndLiquidator() public {
        _depositFor(ALICE, 1e8);
        vm.prank(ALICE);
        pool.borrow(70e6);
        price.setPrice(80e8);
        vm.prank(ALICE);
        usdc.approve(address(pool), 70e6);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.liquidate(ALICE, 70e6, 91_875_000);

        assertEq(usdc.balanceOf(ALICE), 0);
        assertEq(usdc.allowance(ALICE, address(pool)), 0);
        assertEq(wbtc.balanceOf(ALICE), 91_875_000);
        assertEq(pool.collateralOf(ALICE), 8_125_000);
        assertEq(pool.debtOf(ALICE), 0);
        _assertPosition(interestPool.storedDebt(ALICE), 0, 0, block.timestamp);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(BOB), 0);
        assertEq(usdc.balanceOf(BOB), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, 0);
        assertEq(wbtc.balanceOf(address(pool)), 108_125_000);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(usdc.totalSupply(), 100e6);
        assertEq(wbtc.totalSupply(), 2e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), ALICE, ALICE, 70e6, 91_875_000);
    }

    /// @notice Charlie가 Bob의42를 내도 자기 원금20·현재 부채21·담보1과 Alice의 이자 권리를 보존한다.
    function test_LiquidatorKeepsOwnDebtAndCollateralInMultipleBorrowerPool() public {
        uint256 t0 = block.timestamp;
        _depositFor(CHARLIE, 1e8);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.prank(CHARLIE);
        pool.borrow(20e6);
        vm.warp(t0 + HALF_YEAR);
        price.setPrice(45e8);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 22e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 42e6);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.debtOf(CHARLIE), 21e6);
        assertEq(pool.totalDebt(), 63e6);
        assertEq(pool.totalAssets(), 103e6);
        assertEq(pool.availableLiquidity(), 40e6);
        _assertPosition(interestPool.storedDebt(CHARLIE), 20e6, 0, t0);
        _assertPosition(interestPool.storedTotalDebt(), 60e6, 0, t0);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 42e6, 98_000_000);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(wbtc.balanceOf(CHARLIE), 98_000_000);
        assertEq(pool.collateralOf(CHARLIE), 1e8);
        assertEq(pool.debtOf(CHARLIE), 21e6);
        _assertPosition(interestPool.storedDebt(CHARLIE), 20e6, 0, t0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), 2_000_000);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        assertEq(wbtc.balanceOf(address(pool)), 102_000_000);
        assertEq(pool.totalDebt(), 21e6);
        _assertPosition(interestPool.storedTotalDebt(), 20e6, 1e6 * Q, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 103e6 * Q);
        assertEq(pool.totalAssets(), 103e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 103e6);
        assertEq(usdc.balanceOf(address(pool)), 82e6);
        assertEq(pool.availableLiquidity(), 82e6);
        assertEq(usdc.totalSupply(), 122e6);
        assertEq(wbtc.totalSupply(), 2e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 42e6, 98_000_000);
    }

    /// @notice 직접 보낸 USDC20·WBTC0.25는 청산 뒤에도 공급자 수익·차입자 담보로 인정하지 않는다.
    function test_DirectTokenSurplusDoesNotBecomeSupplyRightsOrBorrowerCollateral() public {
        _prepareNoInterestLiquidation(80e8);
        address donor = address(0xD0A0);
        usdc.mint(donor, 20e6);
        wbtc.mint(donor, 25_000_000);
        vm.startPrank(donor);
        assertTrue(usdc.transfer(address(pool), 20e6));
        assertTrue(wbtc.transfer(address(pool), 25_000_000));
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(pool)), 50e6);
        assertEq(pool.availableLiquidity(), 30e6);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(wbtc.balanceOf(address(pool)), 125_000_000);
        assertEq(pool.collateralOf(BOB), 1e8);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 70e6, 91_875_000);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(wbtc.balanceOf(CHARLIE), 91_875_000);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 8_125_000);
        assertEq(wbtc.balanceOf(address(pool)), 33_125_000);
        assertEq(usdc.balanceOf(address(pool)), 120e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(usdc.balanceOf(donor), 0);
        assertEq(wbtc.balanceOf(donor), 0);
        assertEq(pool.shares(donor), 0);
        assertEq(pool.deposits(donor), 0);
        assertEq(pool.collateralOf(donor), 0);
        assertEq(pool.debtOf(donor), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(usdc.totalSupply(), 190e6);
        assertEq(wbtc.totalSupply(), 125_000_000);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 70e6, 91_875_000);
    }

    /// @notice 실제1초 이자875/3942raw를1raw로 완제하며 정확 이자와 올림 차이를 자산에 한 번만 반영한다.
    function test_FractionalInterestRoundingIsCreditedOnceBeforeSameTimeWithdrawal() public {
        uint256 t0 = block.timestamp;
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.warp(t0 + 1);
        price.setPrice(80e8);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 70_000_001);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 70_000_001);
        assertEq(pool.debtOf(BOB), 70_000_001);
        assertEq(pool.totalDebt(), 70e6);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        _assertPosition(interestPool.storedDebt(BOB), 70e6, 0, t0);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 70_000_001, 91_875_001);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(wbtc.balanceOf(CHARLIE), 91_875_001);
        assertEq(pool.collateralOf(BOB), 8_124_999);
        assertEq(wbtc.balanceOf(address(pool)), 8_124_999);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 100_000_001 * Q);
        assertEq(pool.totalAssets(), 100_000_001);
        assertEq(pool.deposits(ALICE), 100_000_001);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100_000_001);
        assertEq(pool.availableLiquidity(), 100_000_001);
        assertEq(usdc.totalSupply(), 170_000_001);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 70_000_001, 91_875_001);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(1);

        assertEq(usdc.balanceOf(ALICE), 1);
        assertEq(pool.shares(ALICE), 99_999_999);
        assertEq(pool.totalShares(), 99_999_999);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        _assertEvent(vm.getRecordedLogs(), "Withdrawn(address,uint256)", ALICE, 1);
    }

    /// @notice 정상 차입으로 만든1raw 부채·2raw 담보는 가격55에서 WBTC1raw를 실제 지급한다.
    function test_PositiveDustCollateralPaymentAllowsExactOneRawMinimum() public {
        vm.startPrank(BOB);
        pool.withdrawCollateral(1e8);
        wbtc.approve(address(pool), 2);
        pool.depositCollateral(2);
        pool.borrow(1);
        vm.stopPrank();
        price.setPrice(55e8);
        usdc.mint(CHARLIE, 1);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 1);
        assertEq(pool.debtOf(BOB), 1);
        assertEq(pool.collateralOf(BOB), 2);
        assertEq(usdc.balanceOf(address(pool)), 99_999_999);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 1, 1);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(wbtc.balanceOf(CHARLIE), 1);
        assertEq(usdc.balanceOf(BOB), 1);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.balanceOf(BOB), 99_999_998);
        assertEq(pool.collateralOf(BOB), 1);
        assertEq(wbtc.balanceOf(address(pool)), 1);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(usdc.totalSupply(), 100_000_001);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 1, 1);
    }

    /// @notice 전역 이자를 먼저 저장한 뒤 같은T 청산은 개인의 늦은 이자3.5를 자산에 다시 더하지 않는다.
    function test_GlobalCheckpointBeforeLiquidationDoesNotCreditInterestTwice() public {
        uint256 t0 = block.timestamp;
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.warp(t0 + HALF_YEAR);
        usdc.mint(ALICE, 103_500_000);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 103_500_000);
        pool.supply(103_500_000);
        vm.stopPrank();
        _assertPosition(interestPool.storedTotalDebt(), 70e6, 3_500_000 * Q, block.timestamp);
        _assertPosition(interestPool.storedDebt(BOB), 70e6, 0, t0);
        assertEq(interestPool.storedAssetsNumerator(), 207e6 * Q);
        assertEq(pool.shares(ALICE), 200e6);
        assertEq(pool.totalShares(), 200e6);
        assertEq(pool.deposits(ALICE), 207e6);
        assertEq(usdc.balanceOf(address(pool)), 133_500_000);
        assertEq(pool.availableLiquidity(), 133_500_000);
        price.setPrice(80e8);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 74e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 74e6);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_468_750);

        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), 96_468_750);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(pool.collateralOf(BOB), 3_531_250);
        assertEq(wbtc.balanceOf(address(pool)), 3_531_250);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 207e6 * Q);
        assertEq(pool.totalAssets(), 207e6);
        assertEq(pool.shares(ALICE), 200e6);
        assertEq(pool.totalShares(), 200e6);
        assertEq(pool.deposits(ALICE), 207e6);
        assertEq(usdc.balanceOf(address(pool)), 207e6);
        assertEq(pool.availableLiquidity(), 207e6);
        assertEq(usdc.totalSupply(), 277_500_000);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 73_500_000, 96_468_750);

        bytes memory afterLiquidation = _interestSnapshot();
        vm.record();
        assertEq(pool.totalAssets(), 207e6);
        assertEq(pool.deposits(ALICE), 207e6);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.availableLiquidity(), 207e6);
        (, bytes32[] memory writes) = vm.accesses(address(pool));
        assertEq(writes.length, 0);
        assertEq(_interestSnapshot(), afterLiquidation);
    }

    /// @notice 개인 이자2.5를 이미 저장한 다음 반년의3.5만 더해76을 받고 공급자 자산107을 남긴다.
    function test_PersonalCheckpointBeforeLaterLiquidationPreservesEarlierInterest() public {
        uint256 t0 = block.timestamp;
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.warp(t0 + HALF_YEAR);
        vm.startPrank(BOB);
        usdc.approve(address(pool), 1e6);
        pool.repay(1e6);
        vm.stopPrank();
        _assertPosition(interestPool.storedDebt(BOB), 70e6, 2_500_000 * Q, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 70e6, 2_500_000 * Q, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 103_500_000 * Q);
        assertEq(usdc.balanceOf(address(pool)), 31e6);
        vm.warp(t0 + 365 days);
        price.setPrice(80e8);
        price.setUpdatedAt(block.timestamp);
        usdc.mint(CHARLIE, 76e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 76e6);
        assertEq(pool.debtOf(BOB), 76e6);
        assertEq(pool.totalDebt(), 76e6);
        assertEq(pool.totalAssets(), 107e6);
        assertEq(interestPool.storedAssetsNumerator(), 103_500_000 * Q);

        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 76e6, 99_750_000);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(wbtc.balanceOf(CHARLIE), 99_750_000);
        assertEq(usdc.balanceOf(BOB), 69e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 250_000);
        assertEq(wbtc.balanceOf(address(pool)), 250_000);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 107e6 * Q);
        assertEq(pool.totalAssets(), 107e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 107e6);
        assertEq(usdc.balanceOf(address(pool)), 107e6);
        assertEq(pool.availableLiquidity(), 107e6);
        assertEq(usdc.totalSupply(), 176e6);
        assertEq(wbtc.totalSupply(), 1e8);
        _assertLiquidationEvent(vm.getRecordedLogs(), CHARLIE, BOB, 76e6, 99_750_000);
    }

    /// @notice 시간 경과 없이 실제70차입 뒤 Charlie의 유한 승인과 지정 가격을 준비한다.
    function _prepareNoInterestLiquidation(int256 executionPrice) private {
        vm.prank(BOB);
        pool.borrow(70e6);
        price.setPrice(executionPrice);
        usdc.mint(CHARLIE, 70e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 70e6);
    }

    /// @notice 이자 없는 완제의 토큰 이동·저장 부채·담보와 공급자 권리를 고정값으로 대조한다.
    function _assertNoInterestCompletion(uint256 paidCollateral, uint256 remainingCollateral) private view {
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(wbtc.balanceOf(CHARLIE), paidCollateral);
        assertEq(usdc.balanceOf(BOB), 70e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.balanceOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), remainingCollateral);
        assertEq(wbtc.balanceOf(address(pool)), remainingCollateral);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.availableLiquidity(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        _assertPosition(interestPool.storedDebt(CHARLIE), 0, 0, 0);
        assertEq(usdc.totalSupply(), 170e6);
        assertEq(wbtc.totalSupply(), 1e8);
    }

    /// @notice 현재 조회의 반올림 값과 별개로 원금·정확 미납 분자·저장 시각을 모두 확인한다.
    function _assertPosition(
        DebtLedger.Position memory position,
        uint256 principal,
        uint256 interestNumerator,
        uint256 updatedAt
    ) private pure {
        assertEq(position.principal, principal);
        assertEq(position.interestNumerator, interestNumerator);
        assertEq(position.updatedAt, updatedAt);
    }

    /// @notice 풀은 정확한 Liquidated1회만 내며 Repaid·CollateralWithdrawn 등 다른 성공 로그는 내지 않는다.
    function _assertLiquidationEvent(
        Vm.Log[] memory logs,
        address liquidator,
        address borrower,
        uint256 expectedRepaid,
        uint256 expectedCollateral
    ) private view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Liquidated(address,address,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(liquidator))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(borrower))));
            (uint256 repaid, uint256 collateralOut) = abi.decode(logs[i].data, (uint256, uint256));
            assertEq(repaid, expectedRepaid);
            assertEq(collateralOut, expectedCollateral);
            ++count;
        }
        assertEq(count, 1);
    }
}
