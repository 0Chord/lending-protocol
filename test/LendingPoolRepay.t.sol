// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BorrowTestBase} from "./helpers/BorrowTestBase.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @title 원금 일부·전액 상환과 담보 반환 연결
contract LendingPoolRepayTest is BorrowTestBase {
    /// @notice 부채40보다 많은50을 준비해도 초과상환은 잔고·승인·장부를 모두 유지한다.
    function test_ExcessRepayPreservesFundedRequest() public {
        _borrowForty();
        usdc.mint(BOB, 10e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 50e6);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepayExceedsDebt.selector, 40e6, 50e6));
        vm.prank(BOB);
        pool.repay(50e6);
        _assertUnchanged(beforeState);
        assertEq(usdc.totalSupply(), 110e6);
    }

    /// @notice 부채0의 본인 상환은 타인의 부채를 줄이지 않는다.
    function test_NoDebtCannotRepayAnotherBorrower() public {
        _borrowForty();
        usdc.mint(CHARLIE, 1e6);
        vm.prank(CHARLIE);
        usdc.approve(address(pool), 1e6);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.RepayExceedsDebt.selector, 0, 1e6));
        vm.prank(CHARLIE);
        pool.repay(1e6);
        _assertUnchanged(beforeState);
    }

    /// @notice 양수 부채에도0상환은 가격이나 전송 없이 거절한다.
    function test_ZeroRepayPreservesState() public {
        _borrowForty();
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(BOB);
        pool.repay(0);
        _assertUnchanged(beforeState);
    }

    /// @notice 부채가 있으면 일부·전액·기록초과 반환 모두 부채 오류이며0은 먼저 거절한다.
    function test_OutstandingDebtBlocksCollateralBeforeRecordCheck() public {
        _borrowForty();
        uint256[3] memory amounts = [uint256(1), 1e8, 1e8 + 1];
        for (uint256 i; i < amounts.length; ++i) {
            bytes memory beforeState = _snapshot();
            vm.recordLogs();
            vm.expectRevert(abi.encodeWithSelector(LendingPool.OutstandingDebt.selector, 40e6));
            vm.prank(BOB);
            pool.withdrawCollateral(amounts[i]);
            _assertUnchanged(beforeState);
        }
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        vm.prank(BOB);
        pool.withdrawCollateral(0);
    }

    /// @notice 승인 부족의 정확한 오류와 상환 직전 전체 상태를 확인한다.
    function test_RepayInsufficientAllowancePreservesState() public {
        _borrowForty();
        vm.prank(BOB);
        usdc.approve(address(pool), 15e6 - 1);
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 15e6 - 1, 15e6)
        );
        vm.prank(BOB);
        pool.repay(15e6);
        _assertUnchanged(beforeState);
    }

    /// @notice 전송 전 승인 차감도 잔고 부족 오류가 전파되면 복구된다.
    function test_RepayInsufficientBalanceRestoresAllowance() public {
        _borrowForty();
        vm.startPrank(BOB);
        assertTrue(usdc.transfer(CHARLIE, 30e6));
        usdc.approve(address(pool), 15e6);
        vm.stopPrank();
        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, BOB, 10e6, 15e6));
        vm.prank(BOB);
        pool.repay(15e6);
        _assertUnchanged(beforeState);
    }

    /// @notice 무제한 승인으로 상환하면 원금만 줄고 max 승인은 유지된다.
    function test_UnlimitedApprovalRemainsAfterRepay() public {
        _borrowForty();
        vm.startPrank(BOB);
        usdc.approve(address(pool), type(uint256).max);
        pool.repay(15e6);
        vm.stopPrank();
        assertEq(usdc.allowance(BOB, address(pool)), type(uint256).max);
        assertEq(pool.debtOf(BOB), 25e6);
        assertEq(pool.totalDebt(), 25e6);
        assertEq(usdc.balanceOf(address(pool)), 75e6);
        assertEq(usdc.balanceOf(BOB), 25e6);
        _assertInitialRights();
    }

    /// @notice 배포 후 metadata와 가격 조회가 모두 실패해도 상환·담보·공급·출금은 자체 규칙대로 실행한다.
    function test_PriceAndMetadataFailureDoNotBlockPriceIndependentActions() public {
        _borrowForty();
        bytes memory outage = abi.encodeWithSignature("PriceSourceUnavailable()");
        vm.mockCallRevert(address(price), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), outage);
        bytes memory metadataCall = abi.encodeCall(ICollateralPriceSource.decimals, ());
        vm.mockCallRevert(address(price), metadataCall, outage);
        vm.mockCallRevert(address(usdc), metadataCall, outage);
        vm.mockCallRevert(address(wbtc), metadataCall, outage);

        bytes memory beforeState = _snapshot();
        vm.recordLogs();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.OutstandingDebt.selector, 40e6));
        vm.prank(BOB);
        pool.withdrawCollateral(1);
        _assertUnchanged(beforeState);
        _depositFor(BOB, 1e8);
        assertEq(pool.collateralOf(BOB), 2e8);
        vm.startPrank(BOB);
        usdc.approve(address(pool), 40e6);
        pool.repay(15e6);
        assertEq(pool.debtOf(BOB), 25e6);
        assertEq(pool.availableLiquidity(), 75e6);
        pool.repay(25e6);
        assertEq(pool.totalDebt(), 0);
        pool.withdrawCollateral(1e8);
        assertEq(pool.collateralOf(BOB), 1e8);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdrawCollateral(0);
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientCollateral.selector, 1e8, 1e8 + 1));
        pool.withdrawCollateral(1e8 + 1);
        pool.withdrawCollateral(1e8);
        vm.stopPrank();
        assertEq(wbtc.balanceOf(BOB), 2e8);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(pool.availableLiquidity(), 100e6);

        vm.startPrank(ALICE);
        pool.withdraw(10e6);
        assertEq(pool.deposits(ALICE), 90e6);
        usdc.approve(address(pool), 10e6);
        pool.supply(10e6);
        vm.stopPrank();
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.totalAssets(), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(usdc.totalSupply(), 100e6);
    }

    /// @notice 같은 사용자가 세 역할을 겸해도 공급 지분·담보·부채는 서로 상계하지 않는다.
    function test_SupplierBorrowerRolesRemainSeparateAndDebtSums() public {
        _borrowForty();
        _depositFor(ALICE, 1e8);
        vm.startPrank(ALICE);
        pool.borrow(10e6);
        assertEq(pool.debtOf(ALICE), 10e6);
        assertEq(pool.totalDebt(), 50e6);
        assertEq(pool.totalDebt(), pool.debtOf(ALICE) + pool.debtOf(BOB));
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.collateralOf(ALICE), 1e8);
        usdc.approve(address(pool), 5e6);
        pool.repay(5e6);
        pool.withdraw(5e6);
        vm.stopPrank();
        assertEq(pool.debtOf(ALICE), 5e6);
        assertEq(pool.debtOf(BOB), 40e6);
        assertEq(pool.totalDebt(), 45e6);
        assertEq(pool.totalAssets(), 95e6);
        assertEq(pool.shares(ALICE), 95e6);
        assertEq(pool.collateralOf(ALICE), 1e8);
        assertEq(pool.collateralOf(BOB), 1e8);
    }

    /// @notice 첫 정상 차입을 별도 성공 거래로 준비한다.
    function _borrowForty() private {
        vm.prank(BOB);
        pool.borrow(40e6);
    }

    /// @notice 40을 빌려15·25를 갚으면 담보 반환 전까지 공급 권리와 담보는 유지된다.
    function test_RepayFifteenThenTwentyFiveAndReturnCollateral() public {
        vm.startPrank(BOB);
        pool.borrow(40e6);
        usdc.approve(address(pool), 15e6);
        vm.recordLogs();
        pool.repay(15e6);
        assertEq(usdc.balanceOf(BOB), 25e6);
        assertEq(usdc.balanceOf(address(pool)), 75e6);
        assertEq(pool.debtOf(BOB), 25e6);
        assertEq(pool.totalDebt(), 25e6);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 15e6);

        usdc.approve(address(pool), 25e6);
        vm.recordLogs();
        pool.repay(25e6);
        assertEq(usdc.balanceOf(BOB), 0);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(pool.debtOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(usdc.allowance(BOB, address(pool)), 0);
        _assertInitialRights();
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 25e6);

        vm.recordLogs();
        pool.withdrawCollateral(1e8);
        assertEq(wbtc.balanceOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(pool.totalDebt(), 0);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(usdc.balanceOf(address(pool)), 100e6);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        _assertEvent(vm.getRecordedLogs(), "CollateralWithdrawn(address,uint256)", BOB, 1e8);
        vm.stopPrank();
    }
}
