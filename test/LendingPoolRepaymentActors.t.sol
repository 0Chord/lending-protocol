// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";
import {InterestMath} from "../src/libraries/InterestMath.sol";

/// @title 상환 지급자의 자금과 지정 차입자의 부채를 분리하는 내부 경로 검사
contract LendingPoolRepaymentActorsTest is InterestTestBase {
    uint256 private constant Q = InterestMath.DENOMINATOR;

    /// @notice Charlie의12만 받아 Bob의 이자2·원금10을 갚고 지갑·담보·공급자 권리를 보존한다.
    /// @dev 시험용 진입점은 Repaid를 내보내지 않으며 조회 이자와 실제 저장 장부를 구분한다.
    function test_ThirdPartyPaymentUsesPayerFundsAndSettlesBorrowerDebt() public {
        uint256 t0 = block.timestamp;
        assertEq(t0, 10_000);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.warp(t0 + HALF_YEAR);
        usdc.mint(CHARLIE, 12e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 12e6);

        assertEq(usdc.balanceOf(CHARLIE), 12e6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 12e6);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), 60e6);
        assertEq(usdc.totalSupply(), 112e6);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.totalDebt(), 42e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 60e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        assertEq(wbtc.totalSupply(), 1e8);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * InterestMath.DENOMINATOR);
        assertEq(interestPool.storedDebt(BOB).principal, 40e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(interestPool.storedDebt(BOB).updatedAt, t0);
        assertEq(interestPool.storedTotalDebt().principal, 40e6);
        assertEq(interestPool.storedTotalDebt().interestNumerator, 0);
        assertEq(interestPool.storedTotalDebt().updatedAt, t0);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(usdc.totalSupply(), 112e6);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.totalDebt(), 30e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        assertEq(wbtc.totalSupply(), 1e8);
        assertEq(pool.debtOf(CHARLIE), 0);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(pool.collateralOf(CHARLIE), 0);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * InterestMath.DENOMINATOR);
        assertEq(interestPool.storedDebt(BOB).principal, 30e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(interestPool.storedDebt(BOB).updatedAt, block.timestamp);
        assertEq(interestPool.storedTotalDebt().principal, 30e6);
        assertEq(interestPool.storedTotalDebt().interestNumerator, 0);
        assertEq(interestPool.storedTotalDebt().updatedAt, block.timestamp);

        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 기존 정액 상환은 Bob의12만 받아 같은 부채30을 남기고 본인 상환 이벤트를1회 낸다.
    function test_PublicRepayKeepsSelfFundedFlowAndEmitsOnce() public {
        _borrowAndWait(40e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 12e6);

        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(12e6);

        assertEq(usdc.balanceOf(BOB), 28e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(usdc.totalSupply(), 100e6);
        _assertPosition(interestPool.storedDebt(BOB), 30e6, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 30e6, 0, block.timestamp);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.totalDebt(), 30e6);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 12e6);
    }

    /// @notice 기존 완제는 상한50 중 견적42만 받고 남은 승인8과 Repaid(Bob,42)1회를 유지한다.
    function test_PublicRepayAllTakesOnlyQuoteAndEmitsOnce() public {
        _borrowAndWait(40e6);
        usdc.mint(BOB, 2e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 50e6);

        vm.recordLogs();
        vm.prank(BOB);
        pool.repayAll(50e6);

        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 8e6);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), 102e6);
        assertEq(usdc.totalSupply(), 102e6);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 102e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 42e6);
    }

    /// @notice Charlie 자신의 부채21과 직접 기부20을 보존하고 Bob의12만 정산한다.
    function test_ThirdPartyPaymentPreservesPayersDebtAndDirectSurplus() public {
        uint256 t0 = block.timestamp;
        address donor = address(0xD0A0);
        _depositFor(CHARLIE, 1e8);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.prank(CHARLIE);
        pool.borrow(20e6);
        usdc.mint(donor, 20e6);
        vm.prank(donor);
        assertTrue(usdc.transfer(address(pool), 20e6));
        vm.warp(t0 + HALF_YEAR);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 12e6);

        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.debtOf(CHARLIE), 21e6);
        assertEq(pool.totalDebt(), 63e6);
        assertEq(pool.totalAssets(), 103e6);
        assertEq(usdc.balanceOf(address(pool)), 60e6);
        assertEq(pool.availableLiquidity(), 40e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 103e6);
        assertEq(usdc.balanceOf(CHARLIE), 20e6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 12e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        _assertPosition(interestPool.storedDebt(BOB), 40e6, 0, t0);
        _assertPosition(interestPool.storedTotalDebt(), 60e6, 0, t0);
        DebtLedger.Position memory payerDebt = interestPool.storedDebt(CHARLIE);
        _assertPosition(payerDebt, 20e6, 0, t0);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.debtOf(CHARLIE), 21e6);
        assertEq(pool.totalDebt(), 51e6);
        _assertPosition(interestPool.storedDebt(BOB), 30e6, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 50e6, 1e6 * Q, block.timestamp);
        assertEq(abi.encode(interestPool.storedDebt(CHARLIE)), abi.encode(payerDebt));
        assertEq(interestPool.storedAssetsNumerator(), 103e6 * Q);
        assertEq(pool.totalAssets(), 103e6);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(pool.availableLiquidity(), 52e6);
        assertEq(usdc.balanceOf(address(pool)) - pool.availableLiquidity(), 20e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.deposits(ALICE), 103e6);
        assertEq(usdc.balanceOf(CHARLIE), 8e6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(donor), 0);
        assertEq(usdc.allowance(donor, address(pool)), 0);
        assertEq(usdc.totalSupply(), 120e6);
        assertEq(pool.shares(CHARLIE), 0);
        assertEq(pool.deposits(CHARLIE), 0);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(pool.collateralOf(CHARLIE), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 2e8);
        assertEq(wbtc.totalSupply(), 2e8);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 가격과 세 계약의 decimals가 모두 실패해도 Charlie의 정상 상환은 이를 조회하지 않는다.
    function test_ThirdPartyPaymentSucceedsWithPriceAndMetadataOutage() public {
        _borrowAndWait(40e6);
        _fundPayer(12e6, 12e6);
        bytes memory outage = abi.encodeWithSignature("PriceAndMetadataUnavailable()");
        bytes memory metadataCall = abi.encodeCall(ICollateralPriceSource.decimals, ());
        vm.mockCallRevert(address(price), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), outage);
        vm.mockCallRevert(address(price), metadataCall, outage);
        vm.mockCallRevert(address(usdc), metadataCall, outage);
        vm.mockCallRevert(address(wbtc), metadataCall, outage);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);

        _assertPosition(interestPool.storedDebt(BOB), 30e6, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 30e6, 0, block.timestamp);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 50 raw 원금의 반년 이자2.5 중1만 갚으면 원금50·미납1.5와 정확 자산을 보존한다.
    function test_FractionalInterestOnlyPaymentKeepsUnpaidNumerator() public {
        _borrowAndWait(50);
        _fundPayer(1, 1);
        assertEq(pool.debtOf(BOB), 53);
        assertEq(pool.totalDebt(), 52);
        assertEq(pool.totalAssets(), 100e6 + 2);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 1);

        _assertPosition(interestPool.storedDebt(BOB), 50, 3 * Q / 2, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 50, 3 * Q / 2, block.timestamp);
        assertEq(pool.debtOf(BOB), 52);
        assertEq(pool.totalDebt(), 51);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q + 5 * Q / 2);
        assertEq(pool.totalAssets(), 100e6 + 2);
        assertEq(pool.deposits(ALICE), 100e6 + 2);
        assertEq(usdc.balanceOf(address(pool)), 100e6 - 49);
        assertEq(pool.availableLiquidity(), 100e6 - 49);
        assertEq(usdc.balanceOf(BOB), 50);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.totalSupply(), 100e6 + 1);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 이자0.4가 있는8 raw 부채의 부분 상환은 올림 차이0.6만 수익화하고 같은 시각 완제에 반복하지 않는다.
    function test_FractionalPartialThenFullPaymentAddsRoundingSurplusOnce() public {
        _borrowAndWait(8);
        _fundPayer(9, 9);
        assertEq(pool.debtOf(BOB), 9);
        assertEq(pool.totalDebt(), 8);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);
        uint256 settledAt = block.timestamp;

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 3);

        _assertPosition(interestPool.storedDebt(BOB), 6, 0, settledAt);
        _assertPosition(interestPool.storedTotalDebt(), 6, 0, settledAt);
        assertEq(interestPool.storedAssetsNumerator(), (100e6 + 1) * Q);
        assertEq(interestPool.storedAssetsNumerator() - (100e6 * Q + 2 * Q / 5), 3 * Q / 5);
        assertEq(pool.totalAssets(), 100e6 + 1);
        assertEq(pool.deposits(ALICE), 100e6 + 1);
        assertEq(pool.debtOf(BOB), 6);
        assertEq(pool.totalDebt(), 6);
        assertEq(usdc.balanceOf(address(pool)), 100e6 - 5);
        assertEq(pool.availableLiquidity(), 100e6 - 5);
        assertEq(usdc.balanceOf(CHARLIE), 6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 6);
        _assertNoPoolEvents(vm.getRecordedLogs());

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 6);

        assertEq(block.timestamp, settledAt);
        _assertPosition(interestPool.storedDebt(BOB), 0, 0, settledAt);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, settledAt);
        assertEq(interestPool.storedAssetsNumerator(), (100e6 + 1) * Q);
        assertEq(pool.totalAssets(), 100e6 + 1);
        assertEq(pool.deposits(ALICE), 100e6 + 1);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(usdc.balanceOf(address(pool)), 100e6 + 1);
        assertEq(pool.availableLiquidity(), 100e6 + 1);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 8);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.totalSupply(), 100e6 + 9);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 정확 부채8.4의 완제액9는 올림 차이0.6만 더해 자산과 현금을 같은 정수로 맞춘다.
    function test_FractionalFullPaymentRecognizesOnlyRoundingSurplus() public {
        _borrowAndWait(8);
        _fundPayer(9, 9);
        assertEq(pool.debtOf(BOB), 9);
        assertEq(pool.totalDebt(), 8);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(interestPool.storedAssetsNumerator(), 100e6 * Q);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 9);

        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(interestPool.storedAssetsNumerator(), (100e6 + 1) * Q);
        assertEq(interestPool.storedAssetsNumerator() - (100e6 * Q + 2 * Q / 5), 3 * Q / 5);
        assertEq(pool.totalAssets(), 100e6 + 1);
        assertEq(pool.deposits(ALICE), 100e6 + 1);
        assertEq(usdc.balanceOf(address(pool)), 100e6 + 1);
        assertEq(pool.availableLiquidity(), 100e6 + 1);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 8);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.totalSupply(), 100e6 + 9);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 제3자의42 수령은 Bob 지갑40과 담보1을 유지한 채 원리금을 전부 없앤다.
    function test_ThirdPartyFullPaymentClearsBorrowerWithoutUsingBorrowerFunds() public {
        _borrowAndWait(40e6);
        _fundPayer(42e6, 42e6);

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 42e6);

        _assertPosition(interestPool.storedDebt(BOB), 0, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 0, 0, block.timestamp);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), 102e6);
        assertEq(usdc.totalSupply(), 142e6);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 102e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 같은 시각의12·10 지급은 이자2를 한 번만 인식하고 Charlie의 무한 승인을 소비하지 않는다.
    function test_RepeatedPaymentsKeepInfiniteAllowanceAndRecognizeInterestOnce() public {
        _borrowAndWait(40e6);
        _fundPayer(22e6, type(uint256).max);
        uint256 settledAt = block.timestamp;

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 12e6);
        _assertPosition(interestPool.storedDebt(BOB), 30e6, 0, settledAt);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(usdc.balanceOf(CHARLIE), 10e6);
        assertEq(usdc.allowance(CHARLIE, address(pool)), type(uint256).max);
        _assertNoPoolEvents(vm.getRecordedLogs());

        vm.recordLogs();
        vm.prank(CHARLIE);
        interestPool.repayForTest(BOB, 10e6);

        assertEq(block.timestamp, settledAt);
        _assertPosition(interestPool.storedDebt(BOB), 20e6, 0, settledAt);
        _assertPosition(interestPool.storedTotalDebt(), 20e6, 0, settledAt);
        assertEq(pool.debtOf(BOB), 20e6);
        assertEq(pool.totalDebt(), 20e6);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(usdc.balanceOf(address(pool)), 82e6);
        assertEq(pool.availableLiquidity(), 82e6);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), type(uint256).max);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.totalSupply(), 122e6);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @notice 시험용 진입점도 지급자와 차입자가 같으면 본인 자금으로 정산하되 풀 이벤트는 내지 않는다.
    function test_HarnessSelfPaymentSettlesOwnDebtWithoutPoolEvent() public {
        _borrowAndWait(40e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 12e6);

        vm.recordLogs();
        vm.prank(BOB);
        interestPool.repayForTest(BOB, 12e6);

        _assertPosition(interestPool.storedDebt(BOB), 30e6, 0, block.timestamp);
        _assertPosition(interestPool.storedTotalDebt(), 30e6, 0, block.timestamp);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(usdc.balanceOf(BOB), 28e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(interestPool.storedAssetsNumerator(), 102e6 * Q);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.deposits(ALICE), 102e6);
        _assertNoPoolEvents(vm.getRecordedLogs());
    }

    /// @dev 실제 차입과 시간 경과만으로 이자를 만들며 담보·가격 준비는 기존 기본값을 사용한다.
    function _borrowAndWait(uint256 amount) private {
        vm.prank(BOB);
        pool.borrow(amount);
        vm.warp(block.timestamp + HALF_YEAR);
    }

    /// @dev Charlie의 지급액과 유한·무한 승인을 각각 준비하며 Bob의 토큰은 건드리지 않는다.
    function _fundPayer(uint256 amount, uint256 allowance) private {
        usdc.mint(CHARLIE, amount);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), allowance);
    }

    /// @dev 공개 반올림값 외에 원금·미납 분자·저장 시각을 고정 기대값과 비교한다.
    function _assertPosition(
        DebtLedger.Position memory position,
        uint256 principal,
        uint256 interest,
        uint256 updatedAt
    ) private pure {
        assertEq(position.principal, principal);
        assertEq(position.interestNumerator, interest);
        assertEq(position.updatedAt, updatedAt);
    }

    /// @dev Transfer 등 토큰 로그를 허용하되 하네스가 풀 성공 이벤트를 새로 만들지 못하게 한다.
    function _assertNoPoolEvents(Vm.Log[] memory logs) private view {
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }
}
