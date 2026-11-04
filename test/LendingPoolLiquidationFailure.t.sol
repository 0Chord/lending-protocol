// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {LendingPool} from "../src/LendingPool.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {DebtLedger} from "../src/accounting/DebtLedger.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";
import {LiquidationMath} from "../src/libraries/LiquidationMath.sol";
import {LiquidationFailureTestBase} from "./helpers/LiquidationFailureTestBase.sol";
import {RevertingCollateralPriceSource} from "./mocks/RevertingCollateralPriceSource.sol";
import {FailingMockUSDC} from "./mocks/FailingMockUSDC.sol";
import {FailingMockWBTC} from "./mocks/FailingMockWBTC.sol";

/// @title 청산 입력·가격·정확 판정의 거절과 검사 순서
/// @notice 정상 부채와 실제 담보를 사용하며 극소 반올림 사례만 원시 하네스 준비를 명시한다.
contract LendingPoolLiquidationPreflightFailureTest is LiquidationFailureTestBase {
    /// @notice 0 상한은 무부채와 고장 가격보다 먼저 거절한다.
    function test_ZeroMaximumPrecedesNoDebtAndBrokenPrice() public {
        _breakPrice();
        _assertRejected(ALICE, 0, 0, abi.encodeWithSelector(LendingPool.ZeroAmount.selector));
    }

    /// @notice 양수 상한의 무부채는 가격 원천을 호출하지 않고 NoDebt다.
    function test_NoDebtPrecedesBrokenPrice() public {
        _breakPrice();
        _assertRejected(ALICE, 1, 0, abi.encodeWithSelector(LendingPool.NoDebt.selector));
    }

    /// @notice 0 주소도 별도 주소 오류를 추가하지 않고 기존 무부채 규칙으로 거절한다.
    function test_ZeroBorrowerUsesNoDebt() public {
        _breakPrice();
        _assertRejected(address(0), 1, 0, abi.encodeWithSelector(LendingPool.NoDebt.selector));
    }

    /// @notice 상한이 완제액보다 1raw 작으면 가격 장애보다 먼저 정확 상한 오류를 낸다.
    function test_MaximumOneRawBelowQuotePrecedesBrokenPrice() public {
        _breakPrice();
        _assertRejected(
            BOB,
            REPAYMENT - 1,
            0,
            abi.encodeWithSelector(LendingPool.RepaymentLimitExceeded.selector, REPAYMENT, REPAYMENT - 1)
        );
    }

    /// @notice 부채70·가격90은 건강하므로 과도한 최소 수령보다 대상 제외 오류가 먼저다.
    function test_HealthyPositionPrecedesExcessMinimum() public {
        _prepareStandard(false);
        price.setPrice(90e8);
        _assertRejected(BOB, 70e6, type(uint256).max, abi.encodeWithSelector(LendingPool.NotLiquidatable.selector, BOB));
    }

    /// @notice 부채70·담보가치87.5의 정확80%는 경계에 같으므로 청산하지 않는다.
    function test_ExactlyEightyPercentRejectsLiquidation() public {
        _prepareStandard(false);
        price.setPrice(8_750_000_000);
        _assertRejected(BOB, 70e6, 0, abi.encodeWithSelector(LendingPool.NotLiquidatable.selector, BOB));
    }

    /// @notice 계산된 지급량보다 1raw 큰 최소 수령은 두 토큰 이동 전 정확 인수로 거절한다.
    function test_MinimumOneRawAbovePayoutRejects() public {
        _assertRejected(
            BOB,
            74e6,
            PAYOUT + 1,
            abi.encodeWithSelector(LendingPool.InsufficientCollateralOut.selector, PAYOUT, PAYOUT + 1)
        );
    }

    /// @notice 담보 가치72는 원금70도 보상 포함해 전부 갚을 수 없어 최소 수령보다 먼저 거절한다.
    function test_CollateralBelowRewardRequirementPrecedesMinimum() public {
        _prepareStandard(false);
        price.setPrice(72e8);
        _assertRejected(
            BOB,
            70e6,
            type(uint256).max,
            abi.encodeWithSelector(LiquidationMath.InsufficientLiquidationCollateral.selector)
        );
    }

    /// @notice 담보 가치60은 부채70보다도 작으며 자동 면제나 공급자 손실 반영 없이 남는다.
    function test_CollateralBelowPrincipalRejectsWithoutWriteOff() public {
        _prepareStandard(false);
        price.setPrice(60e8);
        _assertRejected(
            BOB, 70e6, 0, abi.encodeWithSelector(LiquidationMath.InsufficientLiquidationCollateral.selector)
        );
    }

    /// @notice 직접 보낸 WBTC가 풀에 충분히 있어도 Bob의 부족한 기록 담보를 보충할 수 없다.
    function test_DirectWBTCSurplusCannotCoverRecordedCollateralShortage() public {
        _prepareStandard(false);
        price.setPrice(72e8);
        address donor = address(0xD0A7);
        wbtc.mint(donor, 25_000_000);
        vm.prank(donor);
        assertTrue(wbtc.transfer(address(pool), 25_000_000));
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 175_000_000);
        assertEq(pool.collateralOf(donor), 0);
        assertEq(pool.shares(donor), 0);
        bytes memory donorBefore = abi.encode(_storedParticipant(donor), _queries(donor));

        _assertRejected(
            BOB, 70e6, 0, abi.encodeWithSelector(LiquidationMath.InsufficientLiquidationCollateral.selector)
        );

        assertEq(abi.encode(_storedParticipant(donor), _queries(donor)), donorBefore);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 175_000_000);
    }

    /// @notice 가격0은 원천 응답 인수 그대로 거절하고 이자 저장·승인 소비를 시작하지 않는다.
    function test_ZeroPriceRejects() public {
        price.setPrice(0);
        _assertRejected(BOB, 74e6, 0, abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, int256(0)));
    }

    /// @notice 음수 가격을 부호 없는 큰 가격으로 해석하지 않고 정확 원시값으로 거절한다.
    function test_NegativePriceRejects() public {
        price.setPrice(-1);
        _assertRejected(BOB, 74e6, 0, abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, int256(-1)));
    }

    /// @notice 갱신시각0은 실행 시각까지 포함한 기존 오류를 유지한다.
    function test_ZeroPriceTimestampRejects() public {
        price.setUpdatedAt(0);
        _assertRejected(
            BOB,
            74e6,
            0,
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, uint256(0), block.timestamp)
        );
    }

    /// @notice 미래 갱신시각은 아직 유효한 가격으로 인정하지 않는다.
    function test_FuturePriceTimestampRejects() public {
        price.setUpdatedAt(block.timestamp + 1);
        _assertRejected(
            BOB,
            74e6,
            0,
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, block.timestamp + 1, block.timestamp)
        );
    }

    /// @notice 갱신 후3601초는 정확 stale 인수로 거절하며 실패 호출이 시각을 저장하지 않는다.
    function test_PriceOlderThanOneHourRejects() public {
        price.setUpdatedAt(block.timestamp - 3601);
        _assertRejected(
            BOB,
            74e6,
            0,
            abi.encodeWithSelector(CollateralMath.StalePrice.selector, block.timestamp - 3601, block.timestamp)
        );
    }

    /// @notice 외부 가격 원천의 원문 오류를 검사 오류로 바꾸지 않는다.
    function test_PriceSourceRevertPropagates() public {
        _breakPrice();
        _assertRejected(
            BOB, 74e6, 0, abi.encodeWithSelector(RevertingCollateralPriceSource.PriceSourceUnavailable.selector)
        );
    }

    /// @notice 실행 전 경과한 이자로 완제액이 기존 상한을 넘으면 새 실행 시점의 견적으로 거절한다.
    function test_ElapsedTimeRequotesRepaymentAgainstMaximum() public {
        vm.warp(block.timestamp + 1);
        price.setUpdatedAt(block.timestamp);
        _assertRejected(
            BOB,
            REPAYMENT,
            0,
            abi.encodeWithSelector(LendingPool.RepaymentLimitExceeded.selector, REPAYMENT + 1, REPAYMENT)
        );
    }

    /// @notice 실행 전 가격 상승으로 지급량이 예전 최소 수령보다 작아지면 새 가격 기준으로 거절한다.
    function test_ExecutionPriceRequotesMinimum() public {
        price.setPrice(81e8);
        _assertRejected(
            BOB,
            74e6,
            PAYOUT,
            abi.encodeWithSelector(LendingPool.InsufficientCollateralOut.selector, uint256(95_277_777), PAYOUT)
        );
    }

    /// @notice raw P1·C1·가격125의 정확80%를 담보 가치 내림으로 청산 가능하게 바꾸지 않는다.
    function test_RawCollateralValueFloorDoesNotCreateLiquidation() public {
        _prepareRaw(1, 0, 1, 12_500_000_000);
        _assertRejected(BOB, 1, 0, abi.encodeWithSelector(LendingPool.NotLiquidatable.selector, BOB));
    }

    /// @notice raw P1·미납1000·C2는 완제액2로 올려도 정확 부채가 건강하므로 청산하지 않는다.
    function test_RawSettlementRoundingDoesNotCreateLiquidation() public {
        _prepareRaw(1, 1000, 2, 10_000_000_000);
        _assertRejected(BOB, 2, 0, abi.encodeWithSelector(LendingPool.NotLiquidatable.selector, BOB));
    }

    /// @notice raw P1·C1·가격100은 지급 내림1만 보면 맞아도 정확 필요담보1.05가 부족하다.
    function test_RawExactCollateralShortageRejectsDespiteRoundedPayoutFit() public {
        _prepareRaw(1, 0, 1, 10_000_000_000);
        _assertRejected(BOB, 1, 0, abi.encodeWithSelector(LiquidationMath.InsufficientLiquidationCollateral.selector));
    }

    /// @notice raw P1·C1·가격110은 대상·담보 충족 뒤 최종 지급0이므로 min0도 거절한다.
    function test_RawZeroPayoutRejectsWithZeroMinimum() public {
        _prepareRaw(1, 0, 1, 11_000_000_000);
        _assertRejected(BOB, 1, 0, abi.encodeWithSelector(LiquidationMath.ZeroCollateralOut.selector));
    }

    /// @notice raw P1·C2·가격55의 양수 지급1도 최소 수령2를 충족하지 못하면 전체 거절한다.
    function test_RawPositiveDustBelowMinimumRejects() public {
        _prepareRaw(1, 0, 2, 5_500_000_000);
        _assertRejected(
            BOB, 1, 2, abi.encodeWithSelector(LendingPool.InsufficientCollateralOut.selector, uint256(1), uint256(2))
        );
    }

    /// @dev 읽기 전용 원천 호출만 고유 오류로 바꿔 앞단 검사와 가격 단계의 순서를 구분한다.
    function _breakPrice() private {
        vm.mockCallRevert(
            address(price),
            abi.encodeCall(ICollateralPriceSource.latestPrice, ()),
            abi.encodeWithSelector(RevertingCollateralPriceSource.PriceSourceUnavailable.selector)
        );
    }
}

/// @title 청산의 실제 USDC 수령·WBTC 지급 실패와 재시도
/// @notice 수령 이후 두 번째 토큰에서 실패해도 유한 승인·부채 정산·담보 차감·이자 시각까지 복구한다.
contract LendingPoolLiquidationTransferFailureTest is LiquidationFailureTestBase {
    /// @notice Bob의 충분한74 승인과 별개로 Charlie 승인만1raw 부족하면 지급자 오류로 거절한다.
    function test_LiquidatorAllowanceShortageRestoresAccrualAndRetries() public {
        vm.prank(CHARLIE);
        usdc.approve(address(pool), REPAYMENT - 1);
        bytes memory beforeState = _snapshot();

        vm.recordLogs();
        _expectReceipt();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), REPAYMENT - 1, REPAYMENT
            )
        );
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        _assertRestored(beforeState);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 74e6);
        _assertSuccessfulRetry();
    }

    /// @notice Charlie 잔고가1raw 부족하면 Bob 잔고74를 쓰지 않으며 먼저 소비한 유한 승인도 복구한다.
    function test_LiquidatorBalanceShortageRestoresFiniteAllowanceAndRetries() public {
        deal(address(usdc), CHARLIE, REPAYMENT - 1, true);
        bytes memory beforeState = _snapshot();

        vm.recordLogs();
        _expectReceipt();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, CHARLIE, REPAYMENT - 1, REPAYMENT)
        );
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        _assertRestored(beforeState);
        usdc.mint(CHARLIE, 74e6 - (REPAYMENT - 1));
        _assertSuccessfulRetry();
    }

    /// @notice 실제 USDC 수령·승인 소비 뒤 false면 USDC 주소의 SafeERC20 오류로 전체 복구한다.
    function test_PostReceiptFalseRestoresBothAssetsAndRetries() public {
        _receiptFailure(FailingMockUSDC.FailureMode.ReturnFalse);
    }

    /// @notice 실제 USDC 수령 뒤 원본 revert를 전파하고 미저장 이자와 모든 시각을 복구한다.
    function test_PostReceiptRevertRestoresBothAssetsAndRetries() public {
        _receiptFailure(FailingMockUSDC.FailureMode.Revert);
    }

    /// @notice 실제 WBTC 지급 뒤 false면 앞서 끝난 USDC 수령·부채 정산·담보 차감까지 되돌린다.
    function test_PostPayoutFalseRestoresRepaymentAndRetries() public {
        _payoutFailure(FailingMockWBTC.FailureMode.ReturnFalse);
    }

    /// @notice 실제 WBTC 지급 뒤 원본 revert도 두 토큰·유한 승인·정확 장부를 함께 복구한다.
    function test_PostPayoutRevertRestoresRepaymentAndRetries() public {
        _payoutFailure(FailingMockWBTC.FailureMode.Revert);
    }

    /// @dev 실패 토큰은 super.transferFrom을 먼저 실행하며 충분한 Charlie 자원으로 해당 단계에 도달한다.
    function _receiptFailure(FailingMockUSDC.FailureMode mode) private {
        usdc.setFailureMode(mode);
        bytes memory beforeState = _snapshot();
        bytes memory expected = mode == FailingMockUSDC.FailureMode.ReturnFalse
            ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(usdc))
            : abi.encodeWithSelector(FailingMockUSDC.InjectedTransferFailure.selector);

        vm.recordLogs();
        _expectReceipt();
        vm.mockCallRevert(
            address(wbtc),
            abi.encodeWithSignature("transfer(address,uint256)"),
            abi.encodeWithSignature("UnexpectedWBTCPayout()")
        );
        vm.expectRevert(expected);
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        _assertRestored(beforeState);
        vm.clearMockedCalls();
        usdc.setFailureMode(FailingMockUSDC.FailureMode.None);
        _assertSuccessfulRetry();
    }

    /// @dev WBTC 장애는 실제 transfer 이후 발생하므로 이미 수령한 USDC와 원금·이자 소멸도 복구해야 한다.
    function _payoutFailure(FailingMockWBTC.FailureMode mode) private {
        wbtc.setTransferFailureMode(mode);
        bytes memory beforeState = _snapshot();
        bytes memory expected = mode == FailingMockWBTC.FailureMode.ReturnFalse
            ? abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(wbtc))
            : abi.encodeWithSelector(FailingMockWBTC.InjectedCollateralTransferFailure.selector);

        vm.recordLogs();
        _expectReceipt();
        vm.expectCall(address(wbtc), abi.encodeWithSignature("transfer(address,uint256)", CHARLIE, PAYOUT), uint64(2));
        vm.expectRevert(expected);
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        _assertRestored(beforeState);
        wbtc.setTransferFailureMode(FailingMockWBTC.FailureMode.None);
        _assertSuccessfulRetry();
    }

    /// @dev 실패 시도와 성공 재시도에서 실제 완제73.5 요청에 각각1회, 시험 전체2회 도달해야 한다.
    function _expectReceipt() private {
        vm.expectCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", CHARLIE, address(pool), REPAYMENT),
            uint64(2)
        );
    }

    /// @dev 미리 성공한 approve는 유지하면서 실패한 호출의 이자 저장·시각·토큰·성공 이벤트를 복구한다.
    function _assertRestored(bytes memory beforeState) private view {
        assertEq(_snapshot(), beforeState);
        assertEq(pool.storedAssetsNumerator(), 100e6 * Q);
        assertEq(pool.storedTotalDebt().updatedAt, START);
        assertEq(pool.storedDebt(BOB).updatedAt, START);
        assertEq(pool.storedDebt(DAVE).updatedAt, START);
        _assertNoPoolLogs();
    }

    /// @dev 장애만 해제한 같은 요청은 Bob만 완제하고 Dave·지분·두 토큰 주소의 권리를 유지한다.
    function _assertSuccessfulRetry() private {
        bytes memory daveBefore = abi.encode(_storedParticipant(DAVE), pool.storedDebt(DAVE), _queries(DAVE));
        bytes memory tokenAccountsBefore = abi.encode(
            _storedParticipant(address(usdc)),
            _storedParticipant(address(wbtc)),
            pool.storedDebt(address(usdc)),
            pool.storedDebt(address(wbtc))
        );
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), PAYOUT);
        assertEq(usdc.balanceOf(BOB), 74e6);
        assertEq(usdc.allowance(BOB, address(pool)), 74e6);
        assertEq(pool.collateralOf(BOB), 3_531_250);
        assertEq(wbtc.balanceOf(address(pool)), 53_531_250);
        assertEq(usdc.balanceOf(address(pool)), 93_500_000);
        assertEq(pool.availableLiquidity(), 93_500_000);
        assertEq(pool.totalAssets(), 104e6);
        assertEq(pool.storedAssetsNumerator(), 104e6 * Q);
        assertEq(pool.totalDebt(), 10_500_000);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.debtOf(DAVE), 10_500_000);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 104e6);
        assertEq(pool.storedDebt(BOB).principal, 0);
        assertEq(pool.storedDebt(BOB).interestNumerator, 0);
        assertEq(pool.storedDebt(BOB).updatedAt, block.timestamp);
        assertEq(pool.storedTotalDebt().principal, 10e6);
        assertEq(pool.storedTotalDebt().interestNumerator, 500_000 * Q);
        assertEq(pool.storedTotalDebt().updatedAt, block.timestamp);
        assertEq(abi.encode(_storedParticipant(DAVE), pool.storedDebt(DAVE), _queries(DAVE)), daveBefore);
        assertEq(
            abi.encode(
                _storedParticipant(address(usdc)),
                _storedParticipant(address(wbtc)),
                pool.storedDebt(address(usdc)),
                pool.storedDebt(address(wbtc))
            ),
            tokenAccountsBefore
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 poolEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            ++poolEvents;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Liquidated(address,address,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(CHARLIE))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(BOB))));
            assertEq(logs[i].data, abi.encode(REPAYMENT, PAYOUT));
        }
        assertEq(poolEvents, 1);
    }
}

/// @title 청산 사전 검사를 통과한 뒤의 산술·시각 실패 위치
/// @notice 극한 장부는 하네스에만 주입하고 실제 Charlie 수령과 WBTC 지급의 도달 여부를 구분한다.
contract LendingPoolLiquidationPrecisionFailureTest is LiquidationFailureTestBase {
    /// @notice P2·C1·가격315에서 수령3 뒤 정산 올림 자산만 넘치면 실제 수령과 유한 승인도 복구한다.
    function test_SettlementOverflowAfterReceiptRestoresAllAndRetries() public {
        _prepareNumeratorBoundary();
        vm.warp(START + 1);
        assertEq(pool.debtOf(BOB), 3);
        assertEq(pool.totalAssets(), type(uint256).max / Q);
        bytes memory beforeState = _snapshot();

        vm.recordLogs();
        vm.expectCall(
            address(usdc),
            abi.encodeWithSignature("transferFrom(address,address,uint256)", CHARLIE, address(pool), 3),
            uint64(2)
        );
        _rejectPayout();
        vm.expectRevert(_overflow());
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 3, 1);

        assertEq(_snapshot(), beforeState);
        _assertNumeratorBoundaryRestored();
        vm.clearMockedCalls();
        _assertBoundaryRetry();
    }

    /// @notice 같은 초기 장부의2초 누적은 USDC 수령 전에 넘치며 토큰 고유 오류와 구분한다.
    function test_AccrualOverflowBeforeReceiptRestoresAllAndRetries() public {
        _prepareNumeratorBoundary();
        vm.warp(START + 2);
        assertEq(pool.debtOf(BOB), 3);
        assertEq(pool.totalDebt(), 2);
        bytes memory beforeState = _storedSnapshot();
        _rejectTransfers();

        vm.recordLogs();
        vm.expectRevert(_overflow());
        pool.totalAssets();
        vm.expectRevert(_overflow());
        pool.availableLiquidity();
        vm.expectRevert(_overflow());
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 3, 1);

        assertEq(_storedSnapshot(), beforeState);
        _assertNumeratorBoundaryRestored();
        vm.clearMockedCalls();
        _assertBoundaryRetry();
    }

    /// @notice 미래 개인 시각은 상한·가격 검사보다 앞선 snapshot의 정확 장부 오류로 거절한다.
    function test_PersonalPastTimestampPrecedesLimitAndPriceAndRestores() public {
        pool.setDebtPositionForTest(BOB, 70e6, 0, block.timestamp + 1);
        bytes memory beforeState = _storedSnapshot();
        _rejectTransfers();
        vm.mockCallRevert(
            address(price),
            abi.encodeCall(ICollateralPriceSource.latestPrice, ()),
            abi.encodeWithSelector(RevertingCollateralPriceSource.PriceSourceUnavailable.selector)
        );

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, block.timestamp + 1, block.timestamp));
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 1, 0);

        assertEq(_storedSnapshot(), beforeState);
        _assertNoPoolLogs();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, block.timestamp + 1, block.timestamp));
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);
        assertEq(_storedSnapshot(), beforeState);
        _assertNoPoolLogs();
        vm.clearMockedCalls();
        pool.setDebtPositionForTest(BOB, 70e6, 0, START);
        _assertNormalRetry();
    }

    /// @notice 개인 견적·가격·담보 검사를 통과해도 미래 전역 시각은 수령 전 정확 장부 오류로 거절한다.
    function test_GlobalPastTimestampAfterPreflightRestoresAndRetries() public {
        pool.setTotalDebtForTest(80e6, 4e6 * Q, block.timestamp + 1);
        bytes memory beforeState = _storedSnapshot();
        _rejectTransfers();

        vm.recordLogs();
        vm.expectCall(address(price), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), uint64(2));
        vm.expectRevert(abi.encodeWithSelector(DebtLedger.PastTimestamp.selector, block.timestamp + 1, block.timestamp));
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);

        assertEq(_storedSnapshot(), beforeState);
        _assertNoPoolLogs();
        vm.clearMockedCalls();
        pool.setTotalDebtForTest(80e6, 0, START);
        _assertNormalRetry();
    }

    /// @dev 실제1raw 공급 지분·담보1과 A=M−2000·D=2Q+r−2000·현금=floor(M/Q)−2를 맞춘다.
    function _prepareNumeratorBoundary() private {
        uint256 maximum = type(uint256).max;
        uint256 remainder = maximum % Q;
        _prepareRaw(2, remainder - 2000, 1, 31_500_000_000);
        pool.setAccountedAssetsNumeratorForTest(maximum - 2000);
        uint256 cash = maximum / Q - 2;
        deal(address(usdc), address(pool), cash, true);
        assertEq(remainder, 168_649_639_935);
        assertEq(pool.storedAssetsNumerator() - 2 * Q - (remainder - 2000), cash * Q);
        assertEq(pool.availableLiquidity(), cash);
        assertEq(pool.totalShares(), 1);
        assertEq(pool.shares(ALICE), 1);
        assertEq(pool.collateralOf(BOB), 1);
        assertEq(wbtc.balanceOf(address(pool)), 1);
        assertEq(usdc.balanceOf(CHARLIE), 3);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 3);
    }

    /// @dev 공개 조회가 넘치더라도 저장 분자·시각·담보와 Charlie의 실제 자금이 모두 원복돼야 한다.
    function _assertNumeratorBoundaryRestored() private view {
        assertEq(pool.storedAssetsNumerator(), type(uint256).max - 2000);
        assertEq(pool.storedDebt(BOB).principal, 2);
        assertEq(pool.storedDebt(BOB).interestNumerator, type(uint256).max % Q - 2000);
        assertEq(pool.storedDebt(BOB).updatedAt, START);
        assertEq(abi.encode(pool.storedTotalDebt()), abi.encode(pool.storedDebt(BOB)));
        assertEq(pool.collateralOf(BOB), 1);
        assertEq(wbtc.balanceOf(address(pool)), 1);
        assertEq(wbtc.balanceOf(CHARLIE), 0);
        assertEq(usdc.balanceOf(CHARLIE), 3);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 3);
        _assertNoPoolLogs();
    }

    /// @dev 하네스 자산만1raw 낮춰 산술 여유를 만들며 남은 실제 현금1raw는 직접 잉여로 보존한다.
    function _assertBoundaryRetry() private {
        uint256 maximum = type(uint256).max;
        pool.setAccountedAssetsNumeratorForTest(maximum - 2000 - Q);
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 3, 1);

        assertEq(usdc.balanceOf(CHARLIE), 0);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 0);
        assertEq(usdc.balanceOf(address(pool)), maximum / Q + 1);
        assertEq(wbtc.balanceOf(CHARLIE), 1);
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.storedDebt(BOB).updatedAt, block.timestamp);
        assertEq(pool.storedTotalDebt().updatedAt, block.timestamp);
        assertEq(pool.storedAssetsNumerator(), maximum - maximum % Q);
        assertEq(pool.totalAssets(), maximum / Q);
        assertEq(pool.availableLiquidity(), maximum / Q);
        assertEq(pool.shares(ALICE), 1);
        assertEq(pool.deposits(ALICE), maximum / Q);
        _assertOneLiquidation(3, 1);
    }

    /// @dev 손상 시각만 복구한 정상 재시도는 미저장 이자를1회 반영하고 Bob만 완제한다.
    function _assertNormalRetry() private {
        bytes memory daveBefore = abi.encode(_storedParticipant(DAVE), pool.storedDebt(DAVE));
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.liquidate(BOB, 74e6, 96_000_000);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), 3_531_250);
        assertEq(pool.storedAssetsNumerator(), 104e6 * Q);
        assertEq(pool.storedTotalDebt().updatedAt, block.timestamp);
        assertEq(pool.debtOf(DAVE), 10_500_000);
        assertEq(abi.encode(_storedParticipant(DAVE), pool.storedDebt(DAVE)), daveBefore);
        assertEq(usdc.balanceOf(CHARLIE), 500_000);
        assertEq(usdc.allowance(CHARLIE, address(pool)), 500_000);
        assertEq(wbtc.balanceOf(CHARLIE), PAYOUT);
        _assertOneLiquidation(REPAYMENT, PAYOUT);
    }

    /// @dev 수령 후 정산 실패가 담보 지급까지 넘어가면 원래 산술 오류와 구분되는 고유 오류를 낸다.
    function _rejectPayout() private {
        vm.mockCallRevert(
            address(wbtc),
            abi.encodeWithSignature("transfer(address,uint256)"),
            abi.encodeWithSignature("UnexpectedWBTCPayout()")
        );
    }

    /// @dev 재시도는 이중 정산이나 다른 풀 이벤트 없이 정확히1회 성공해야 한다.
    function _assertOneLiquidation(uint256 repaid, uint256 collateralOut) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            ++count;
            assertEq(logs[i].topics.length, 3);
            assertEq(logs[i].topics[0], keccak256("Liquidated(address,address,uint256,uint256)"));
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(CHARLIE))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(BOB))));
            assertEq(logs[i].data, abi.encode(repaid, collateralOut));
        }
        assertEq(count, 1);
    }

    /// @dev 다른 장부·토큰 실패를 허용하지 않도록 정확한 산술 Panic(0x11)을 기대한다.
    function _overflow() private pure returns (bytes memory) {
        return abi.encodeWithSignature("Panic(uint256)", uint256(0x11));
    }
}
