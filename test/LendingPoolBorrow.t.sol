// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BorrowTestBase} from "./helpers/BorrowTestBase.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";
import {RevertingCollateralPriceSource} from "./mocks/RevertingCollateralPriceSource.sol";

/// @title 본인 담보를 기준으로 한 이자 없는 원금 대출
contract LendingPoolBorrowTest is BorrowTestBase {
    /// @notice 공급100에서 대출40은 현금60·부채40이며 공급 권리100을 유지한다.
    function test_BorrowFortyMovesCashAndRecordsOnlyDebt() public {
        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(40e6);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.balanceOf(address(pool)), 60e6);
        assertEq(pool.debtOf(BOB), 40e6);
        assertEq(pool.totalDebt(), 40e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 40e6);
    }

    /// @notice 담보1·가격100의 70% 경계까지 빌려도 공급자의 지분과 담보는 유지된다.
    function test_BorrowExactlySeventyPercentLimit() public {
        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(70e6);
        _assertBobDebtAndCash(70e6, 30e6);
        assertEq(pool.availableLiquidity(), 30e6);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 70e6);
    }

    /// @notice 총부채 한도를 USDC 최소단위 하나 넘는 첫 차입은 전체 거절한다.
    function test_BorrowOneRawAboveLimitReverts() public {
        _expectBorrowRevert(
            BOB, 70e6 + 1, abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 70e6, 0, 70e6 + 1)
        );
    }

    /// @notice 기존40에 추가30을 합산해 총부채70과 현금30을 기록한다.
    function test_AdditionalThirtyReachesTotalLimit() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(30e6);
        _assertBobDebtAndCash(70e6, 30e6);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 30e6);
    }

    /// @notice 추가 차입 한도를 넘으면 먼저 빌린40과 남은 현금60을 보존한다.
    function test_AdditionalDebtAboveTotalLimitReverts() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        _expectBorrowRevert(
            BOB, 30e6 + 1, abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 70e6, 40e6, 30e6 + 1)
        );
        _assertBobDebtAndCash(40e6, 60e6);
    }

    /// @notice 가격 급락으로 기존부채40이 새 한도35보다 커도 뺄셈 panic 대신 한도 오류를 낸다.
    function test_PriceDropBelowExistingDebtRejectsWithoutUnderflow() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        price.setPrice(50e8);
        _expectBorrowRevert(BOB, 1, abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 35e6, 40e6, 1));
        _assertBobDebtAndCash(40e6, 60e6);
    }

    /// @notice 요청과 기존부채의 단순 합이 넘쳐도 산술 panic 대신 정확한 한도 오류를 낸다.
    function test_MaxRequestWithExistingDebtRejectsWithoutAdditionOverflow() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        _expectBorrowRevert(
            BOB,
            type(uint256).max,
            abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 70e6, 40e6, type(uint256).max)
        );
    }

    /// @notice 0 차입은 잘못된 가격보다 먼저 거절하며 어떤 부채도 만들지 않는다.
    function test_ZeroBorrowPrecedesInvalidPrice() public {
        price.setPrice(0);
        _expectBorrowRevert(BOB, 0, abi.encodeWithSelector(LendingPool.ZeroAmount.selector));
    }

    /// @notice 다른 사람의 담보나 본인 공급 지분은 새 차입자의 담보로 쓸 수 없다.
    function test_UncollateralizedBorrowerCannotUseOtherCollateralOrSupplyRights() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        bytes memory expectedError = abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 0, 0, 1);
        _expectBorrowRevert(CHARLIE, 1, expectedError);
        _expectBorrowRevert(ALICE, 1, expectedError);
        assertEq(pool.debtOf(BOB), 40e6);
        assertEq(pool.debtOf(ALICE), 0);
        assertEq(pool.debtOf(CHARLIE), 0);
    }

    /// @notice 담보 raw3·가격150은 가치4에서 한도2로 두 번 내림하므로 raw2를 허용한다.
    function test_TinyCollateralAllowsTwoRawDebtAfterBothRoundingSteps() public {
        _depositFor(CHARLIE, 3);
        price.setPrice(150e8);
        vm.recordLogs();
        vm.prank(CHARLIE);
        pool.borrow(2);
        assertEq(pool.debtOf(CHARLIE), 2);
        assertEq(pool.totalDebt(), 2);
        assertEq(usdc.balanceOf(CHARLIE), 2);
        assertEq(usdc.balanceOf(address(pool)), 99_999_998);
        assertEq(pool.collateralOf(CHARLIE), 3);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", CHARLIE, 2);
    }

    /// @notice 같은 독립 준비에서 raw3 차입은 두 단계 내림한 한도2를 넘는다.
    function test_TinyCollateralRejectsThreeRawDebt() public {
        _depositFor(CHARLIE, 3);
        price.setPrice(150e8);
        _expectBorrowRevert(CHARLIE, 3, abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 2, 0, 3));
    }

    /// @notice 현재10000·갱신6400인 정확히3600초 가격은 차입에 사용할 수 있다.
    function test_PriceExactlyOneHourOldAllowsBorrow() public {
        price.setUpdatedAt(6_400);
        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(70e6);
        _assertBobDebtAndCash(70e6, 30e6);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 70e6);
        _assertRawPrice(100e8, 6_400);
    }

    /// @notice 3601초 가격은 담보 유무와 무관하게 정확한 stale 오류로 거절한다.
    function test_PriceOneSecondTooOldRevertsEvenWithoutCollateral() public {
        price.setUpdatedAt(6_399);
        _expectPriceFailureWithAndWithoutCollateral(
            abi.encodeWithSelector(CollateralMath.StalePrice.selector, 6_399, 10_000)
        );
        _assertRawPrice(100e8, 6_399);
    }

    /// @notice 0 가격은 담보가 없는 주소에서도 한도0으로 가려지지 않는다.
    function test_ZeroPriceRevertsEvenWithoutCollateral() public {
        price.setPrice(0);
        _expectPriceFailureWithAndWithoutCollateral(
            abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, int256(0))
        );
        _assertRawPrice(0, 10_000);
    }

    /// @notice 음수 가격은 부호를 바꾸거나 기본값으로 대체하지 않고 거절한다.
    function test_NegativePriceRevertsEvenWithoutCollateral() public {
        price.setPrice(-1);
        _expectPriceFailureWithAndWithoutCollateral(
            abi.encodeWithSelector(CollateralMath.InvalidPrice.selector, int256(-1))
        );
        _assertRawPrice(-1, 10_000);
    }

    /// @notice 갱신시각0은 현재 가격으로 간주하지 않고 원본 시각 오류를 낸다.
    function test_ZeroTimestampRevertsEvenWithoutCollateral() public {
        price.setUpdatedAt(0);
        _expectPriceFailureWithAndWithoutCollateral(
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, 0, 10_000)
        );
        _assertRawPrice(100e8, 0);
    }

    /// @notice 현재보다1초 미래인 가격도 담보 유무와 무관하게 거절한다.
    function test_FutureTimestampRevertsEvenWithoutCollateral() public {
        price.setUpdatedAt(10_001);
        _expectPriceFailureWithAndWithoutCollateral(
            abi.encodeWithSelector(CollateralMath.InvalidPriceTimestamp.selector, 10_001, 10_000)
        );
        _assertRawPrice(100e8, 10_001);
    }

    /// @notice 가격 호출의 실패를 주입하면 풀은 원본 오류를 전파하고 장부를 보존한다.
    function test_PriceSourceRevertPropagatesEvenWithoutCollateral() public {
        bytes memory expectedError =
            abi.encodeWithSelector(RevertingCollateralPriceSource.PriceSourceUnavailable.selector);
        vm.mockCallRevert(address(price), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), expectedError);
        _expectPriceFailureWithAndWithoutCollateral(expectedError);
        vm.clearMockedCalls();
        _assertRawPrice(100e8, 10_000);
    }

    /// @notice 한 번의 정상 차입은 연결된 가격 원천의 가격·시각 묶음을 정확히 한 번 읽는다.
    function test_BorrowReadsLatestPriceExactlyOnce() public {
        vm.expectCall(address(price), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), uint64(1));
        vm.prank(BOB);
        pool.borrow(40e6);
        _assertBobDebtAndCash(40e6, 60e6);
    }

    /// @notice 담보가 있는 Bob과 없는 Charlie 모두 같은 가격 오류와 전체 복구를 확인한다.
    function _expectPriceFailureWithAndWithoutCollateral(bytes memory expectedError) internal {
        _expectBorrowRevert(BOB, 1, expectedError);
        _expectBorrowRevert(CHARLIE, 1, expectedError);
    }

    /// @notice 실패한 차입이 시험 원천의 원시 가격과 시각까지 바꾸지 않았는지 대조한다.
    function _assertRawPrice(int256 expectedPrice, uint256 expectedUpdatedAt) internal view {
        (int256 actualPrice, uint256 actualUpdatedAt) = price.latestPrice();
        assertEq(actualPrice, expectedPrice);
        assertEq(actualUpdatedAt, expectedUpdatedAt);
    }

    /// @notice 실패 직전의 두 자산·승인·공급권리·담보·부채와 성공 이벤트 부재를 확인한다.
    function _expectBorrowRevert(address borrower, uint256 amount, bytes memory expectedError) internal {
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(expectedError);
        vm.prank(borrower);
        pool.borrow(amount);
        _assertUnchanged(beforeState);
    }

    /// @notice 외부 입력에서 정한 고정 기대값으로 대출자의 원금과 실제 현금을 대조한다.
    function _assertBobDebtAndCash(uint256 expectedDebt, uint256 expectedCash) internal view {
        assertEq(pool.debtOf(BOB), expectedDebt);
        assertEq(pool.totalDebt(), expectedDebt);
        assertEq(usdc.balanceOf(BOB), expectedDebt);
        assertEq(usdc.balanceOf(address(pool)), expectedCash);
    }
}
