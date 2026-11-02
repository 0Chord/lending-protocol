// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {InterestTestBase} from "./helpers/InterestTestBase.sol";
import {LendingPool} from "../src/LendingPool.sol";

/// @title 실제 공급·차입 뒤 시간에 따른 권리와 현금의 구분
contract LendingPoolInterestTest is InterestTestBase {
    /// @notice 반년 이자2는 부채와 공급자 권리만 늘리고 현금60과 저장값을 유지한다.
    function test_HalfYearInterestAppearsWithoutWritingOrCreatingCash() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.warp(block.timestamp + 365 days / 2);

        vm.record();
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.totalDebt(), 42e6);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.availableLiquidity(), 60e6);
        (, bytes32[] memory writes) = vm.accesses(address(pool));
        assertEq(writes.length, 0);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 60e6);
        assertEq(usdc.balanceOf(BOB), 40e6);
        assertEq(usdc.totalSupply(), 100e6);
    }

    /// @notice 이자2를 포함한12 수령은 원금30을 남기며 다음 반년에는1.5만 더 붙는다.
    function test_PartialRepaymentPaysInterestFirstAndKeepsSupplierIncome() public {
        _borrowAndWait();
        vm.prank(BOB);
        usdc.approve(address(pool), 12e6);
        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(12e6);

        assertEq(interestPool.storedDebt(BOB).principal, 30e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(interestPool.storedDebt(BOB).updatedAt, block.timestamp);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.deposits(ALICE), 102e6);
        assertEq(pool.debtOf(BOB), 30e6);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(usdc.balanceOf(BOB), 28e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 12e6);

        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 31_500_000);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(pool.availableLiquidity(), 72e6);
        assertEq(usdc.balanceOf(address(pool)), 72e6);
    }

    /// @notice 상한32 중 실제 완제액31.5만 받고 원금·미납 이자0과 담보 반환을 확인한다.
    function test_RepayAllTakesOnlyQuoteAndAllowsCollateralReturn() public {
        _borrowAndWait();
        vm.startPrank(BOB);
        usdc.approve(address(pool), 12e6);
        pool.repay(12e6);
        vm.stopPrank();
        vm.warp(block.timestamp + HALF_YEAR);
        usdc.mint(BOB, 3_500_000);
        vm.prank(BOB);
        usdc.approve(address(pool), 31_500_000);
        vm.recordLogs();
        vm.prank(BOB);
        pool.repayAll(32e6);

        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(interestPool.storedDebt(BOB).principal, 0);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(pool.availableLiquidity(), 103_500_000);
        assertEq(usdc.balanceOf(address(pool)), 103_500_000);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 31_500_000);
        vm.prank(BOB);
        pool.withdrawCollateral(1e8);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(wbtc.balanceOf(BOB), 1e8);
    }

    /// @notice 상한 부족과 정액 초과 상환은 새 이자의 저장까지 모두 취소한다.
    function test_RepaymentLimitsRestoreUnstoredInterest() public {
        _borrowAndWait();
        vm.prank(BOB);
        usdc.approve(address(pool), 50e6);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepaymentLimitExceeded.selector, 42e6, 41e6));
        vm.prank(BOB);
        pool.repayAll(41e6);
        _assertInterestUnchanged(beforeState);

        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepayExceedsDebt.selector, 42e6, 43e6));
        vm.prank(BOB);
        pool.repay(43e6);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 부채 없는 주소도0상한을 먼저 거절하고 양수 상한에는 부채 없음 오류를 낸다.
    function test_RepayAllRejectsZeroThenNoDebtWithoutChanges() public {
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(BOB);
        pool.repayAll(0);
        _assertInterestUnchanged(beforeState);
        vm.recordLogs();
        vm.expectRevert(LendingPool.NoDebt.selector);
        vm.prank(BOB);
        pool.repayAll(1);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 큰 상한은 금액 배율로 변환하지 않고 실제 견적의 잔고·승인만 사용한다.
    function test_MaximumCapTakesOnlyExactDebt() public {
        _borrowAndWait();
        usdc.mint(BOB, 2e6);
        vm.startPrank(BOB);
        usdc.approve(address(pool), 42e6);
        pool.repayAll(type(uint256).max);
        vm.stopPrank();
        assertEq(pool.debtOf(BOB), 0);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 102e6);
    }

    /// @notice 조회 후1초가 지난 정액 상환은1raw를 남기며 충분한 상한 완제는 나머지를 없앤다.
    function test_DelayedQuotedAmountLeavesDebtThatRepayAllClears() public {
        _borrowAndWait();
        assertEq(pool.debtOf(BOB), 42e6);
        usdc.mint(BOB, 2e6 + 1);
        vm.prank(BOB);
        usdc.approve(address(pool), 42e6 + 1);
        vm.warp(block.timestamp + 1);
        vm.prank(BOB);
        pool.repay(42e6);
        assertEq(pool.debtOf(BOB), 1);
        assertEq(interestPool.storedDebt(BOB).principal, 1);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(pool.totalAssets(), 102e6 + 1);
        assertEq(pool.availableLiquidity(), 102e6);
        vm.prank(BOB);
        pool.repayAll(1);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.availableLiquidity(), 102e6 + 1);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
    }

    /// @notice 이전 반년 이자2를 보존하고 추가10에는 이후 기간부터만 단리를 붙인다.
    function test_AdditionalBorrowPreservesEarlierInterest() public {
        _borrowAndWait();
        price.setUpdatedAt(block.timestamp);
        vm.prank(BOB);
        pool.borrow(10e6);
        assertEq(interestPool.storedDebt(BOB).principal, 50e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 630_720_000_000_000_000);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 54_500_000);
        assertEq(pool.totalAssets(), 104_500_000);
        assertEq(pool.deposits(ALICE), 104_500_000);
        assertEq(pool.availableLiquidity(), 50e6);
        assertEq(usdc.balanceOf(address(pool)), 50e6);
    }

    /// @notice 이자10 중3만 갚으면 원금100은 그대로여서 다음 반년에도5가 발생한다.
    function test_InterestOnlyRepaymentDoesNotReducePrincipal() public {
        _supplyFor(ALICE, 100e6);
        _depositFor(BOB, 1e8);
        vm.prank(BOB);
        pool.borrow(100e6);
        vm.warp(block.timestamp + 365 days);
        vm.startPrank(BOB);
        usdc.approve(address(pool), 3e6);
        pool.repay(3e6);
        vm.stopPrank();
        assertEq(interestPool.storedDebt(BOB).principal, 100e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 2_207_520_000_000_000_000);
        assertEq(pool.debtOf(BOB), 107e6);
        assertEq(pool.totalAssets(), 210e6);
        assertEq(pool.availableLiquidity(), 103e6);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 112e6);
        assertEq(pool.totalAssets(), 215e6);
        assertEq(pool.availableLiquidity(), 103e6);
    }

    /// @notice 새 공급104는100지분을 받고 기존 이자4는 Alice에게 남으며 이후 이자만 나눈다.
    function test_NewSupplierDoesNotTakeEarlierInterest() public {
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.warp(block.timestamp + 365 days);
        _supplyFor(CHARLIE, 104e6);
        assertEq(pool.shares(CHARLIE), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.totalShares(), 200e6);
        assertEq(pool.deposits(ALICE), 104e6);
        assertEq(pool.deposits(CHARLIE), 104e6);
        assertEq(pool.totalAssets(), 208e6);
        assertEq(pool.availableLiquidity(), 164e6);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.deposits(ALICE), 105e6);
        assertEq(pool.deposits(CHARLIE), 105e6);
        assertEq(pool.totalAssets(), 210e6);
        assertEq(pool.debtOf(BOB), 46e6);
        assertEq(pool.availableLiquidity(), 164e6);
    }

    /// @notice 이자 포함 권리102라도 현금60까지만 지급하고 소각 지분을 올림한다.
    function test_InterestRightsDoNotCreateWithdrawalCash() public {
        _borrowAndWait();
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 60e6, 61e6));
        vm.prank(ALICE);
        pool.withdraw(61e6);
        _assertInterestUnchanged(beforeState);
        vm.prank(ALICE);
        pool.withdraw(60e6);
        assertEq(pool.shares(ALICE), 41_176_470);
        assertEq(pool.totalAssets(), 42e6);
        assertEq(pool.deposits(ALICE), 42e6);
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.availableLiquidity(), 0);
        assertEq(usdc.balanceOf(address(pool)), 0);
        assertEq(usdc.balanceOf(ALICE), 60e6);
    }

    /// @notice 직접 유입20은 이자가 생겨도 대출·출금 재원과 공급자 권리에서 제외한다.
    function test_DirectSurplusRemainsExcludedAfterInterest() public {
        usdc.mint(address(pool), 20e6);
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.totalAssets(), 103_500_000);
        assertEq(pool.debtOf(BOB), 73_500_000);
        assertEq(pool.availableLiquidity(), 30e6);
        assertEq(usdc.balanceOf(address(pool)), 50e6);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 30e6, 40e6));
        vm.prank(ALICE);
        pool.withdraw(40e6);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 한도70에 소수 이자만 추가돼도 새 차입과 담보 반환을 거절하고 저장을 복구한다.
    function test_AccruedInterestCountsAgainstBorrowLimitAndCollateralExit() public {
        vm.prank(BOB);
        pool.borrow(70e6);
        vm.warp(block.timestamp + 1);
        bytes memory beforeState = _interestSnapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.BorrowLimitExceeded.selector, 70e6, 70e6 + 1, 1));
        vm.prank(BOB);
        pool.borrow(1);
        _assertInterestUnchanged(beforeState);
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.OutstandingDebt.selector, 70e6 + 1));
        vm.prank(BOB);
        pool.withdrawCollateral(1);
        _assertInterestUnchanged(beforeState);
    }

    /// @notice 가격 원천이 오류여도 조회·공급·출금·담보 추가·상환·완제 뒤 담보 반환은 가능하다.
    function test_NonBorrowActionsDoNotReadBrokenPriceSource() public {
        _borrowAndWait();
        vm.mockCallRevert(address(price), abi.encodeWithSignature("latestPrice()"), hex"cafe");
        assertEq(pool.debtOf(BOB), 42e6);
        assertEq(pool.deposits(ALICE), 102e6);
        _depositFor(BOB, 1e8);
        _supplyFor(ALICE, 1e6);
        vm.prank(ALICE);
        pool.withdraw(1e6);
        usdc.mint(BOB, 2e6);
        vm.startPrank(BOB);
        usdc.approve(address(pool), 42e6);
        pool.repay(1e6);
        pool.repayAll(41e6);
        pool.withdrawCollateral(2e8);
        vm.stopPrank();
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 102e6);
        assertEq(wbtc.balanceOf(BOB), 2e8);
    }

    /// @notice 완제·담보 반환 뒤 빈 부채 기간을 지나 다시 빌려도 이전 이자를 재청구하지 않는다.
    function test_ReborrowAfterPayoffStartsInterestFromNewBorrow() public {
        _borrowAndWait();
        usdc.mint(BOB, 2e6);
        vm.startPrank(BOB);
        usdc.approve(address(pool), type(uint256).max);
        pool.repayAll(42e6);
        pool.withdrawCollateral(1e8);
        vm.stopPrank();
        assertEq(usdc.allowance(BOB, address(pool)), type(uint256).max);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalAssets(), 102e6);
        vm.startPrank(BOB);
        wbtc.approve(address(pool), 1e8);
        pool.depositCollateral(1e8);
        vm.stopPrank();
        price.setUpdatedAt(block.timestamp);
        vm.prank(BOB);
        pool.borrow(10e6);
        assertEq(pool.debtOf(BOB), 10e6);
        assertEq(interestPool.storedDebt(BOB).interestNumerator, 0);
        assertEq(pool.totalAssets(), 102e6);
        assertEq(pool.availableLiquidity(), 92e6);
        vm.warp(block.timestamp + HALF_YEAR);
        assertEq(pool.debtOf(BOB), 10_500_000);
        assertEq(pool.totalAssets(), 102_500_000);
        assertEq(pool.availableLiquidity(), 92e6);
    }

    /// @notice 민트한 자금을 정상 공급으로 받게 해 공급자 진입 전후를 비교한다.
    function _supplyFor(address user, uint256 amount) private {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(pool), amount);
        pool.supply(amount);
        vm.stopPrank();
    }

    /// @notice 실제 정상 대출 뒤 반년을 보내며 가격은 상환에 필요 없어 갱신하지 않는다.
    function _borrowAndWait() private {
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.warp(block.timestamp + HALF_YEAR);
    }
}
