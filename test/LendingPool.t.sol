// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {FailingMockUSDC} from "./mocks/FailingMockUSDC.sol";
import {ReentrantMockUSDC} from "./mocks/ReentrantMockUSDC.sol";
import {CrossReentrantMockUSDC} from "./mocks/CrossReentrantMockUSDC.sol";

/// @title 본인 공급·출금과 예치 기록 검증
/// @notice 정상 준비와 실패 주입을 구분하고 명세의 고정 금액을 비교한다.
contract LendingPoolTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    bytes32 private constant SUPPLIED_TOPIC = keccak256("Supplied(address,uint256)");
    bytes32 private constant WITHDRAWN_TOPIC = keccak256("Withdrawn(address,uint256)");

    MockUSDC private token;
    LendingPool private pool;

    struct SupplyState {
        uint256 aliceBalance;
        uint256 bobBalance;
        uint256 poolBalance;
        uint256 aliceDeposit;
        uint256 bobDeposit;
        uint256 allowance;
        uint256 bobAllowance;
        uint256 totalSupply;
    }

    /// @notice 테스트마다 새 풀과 토큰을 만들고 Alice에게만 200 USDC를 준비한다.
    function setUp() public {
        token = new MockUSDC();
        pool = new LendingPool(token);
        token.mint(ALICE, 200_000_000);
    }

    /// @notice 100 공급은 승인만 소비하며 토큰 이동·본인 기록·이벤트가 한 번 반영된다.
    function test_SupplyMovesTokensAndCreditsOnlyCaller() public {
        vm.prank(ALICE);
        token.approve(address(pool), 100_000_000);

        assertEq(token.balanceOf(ALICE), 200_000_000);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(token.allowance(ALICE, address(pool)), 100_000_000);
        assertEq(token.totalSupply(), 200_000_000);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.supply(100_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(token.balanceOf(address(pool)), 100_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(pool.deposits(BOB), 0);
        _assertOneSupplyEvent(logs, address(pool), ALICE, 100_000_000);
    }

    /// @notice 배포 때 지정한 자산을 그대로 조회할 수 있다.
    function test_ConstructorFixesAsset() public view {
        assertEq(address(pool.asset()), address(token));
    }

    /// @notice 토큰 호출이 불가능한 0 주소를 배포 단계에서 거절한다.
    function test_ConstructorRejectsZeroAsset() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidAsset(address)", address(0)));
        new LendingPool(IERC20(address(0)));
    }

    /// @notice 코드가 없는 일반 주소를 토큰으로 설정하지 못한다.
    function test_ConstructorRejectsAssetWithoutCode() public {
        assertEq(ALICE.code.length, 0);
        vm.expectRevert(abi.encodeWithSignature("InvalidAsset(address)", ALICE));
        new LendingPool(IERC20(ALICE));
    }

    /// @notice 추가 공급은 기존 예치를 덮어쓰지 않고 요청한 20 USDC만 더한다.
    function test_AdditionalSupplyAddsToExistingDeposit() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);

        vm.recordLogs();
        _approveAndSupply(token, pool, ALICE, 20_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 80_000_000);
        assertEq(token.balanceOf(address(pool)), 120_000_000);
        assertEq(pool.deposits(ALICE), 120_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
        assertEq(pool.deposits(BOB), 0);
        _assertOneSupplyEvent(logs, address(pool), ALICE, 20_000_000);
    }

    /// @notice Bob의 공급은 Alice의 토큰이나 예치 기록을 변경하지 않는다.
    function test_DifferentUsersKeepSeparateDeposits() public {
        token.mint(BOB, 30_000_000);
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        assertEq(pool.deposits(BOB), 0);

        _approveAndSupply(token, pool, BOB, 30_000_000);

        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(pool)), 130_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(pool.deposits(BOB), 30_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.allowance(BOB, address(pool)), 0);
        assertEq(token.totalSupply(), 230_000_000);
    }

    /// @notice 0과 달리 양수 최소 단위 1은 반올림 없이 공급할 수 있다.
    function test_SupplyAcceptsOneSmallestUnit() public {
        _approveAndSupply(token, pool, ALICE, 1);

        assertEq(token.balanceOf(ALICE), 199_999_999);
        assertEq(token.balanceOf(address(pool)), 1);
        assertEq(pool.deposits(ALICE), 1);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
    }

    /// @notice 기존 예치가 있어도 0 공급을 거절하고 토큰·승인·기록을 보존한다.
    function test_ZeroSupplyRevertsWithoutChangingState() public {
        _approveAndSupply(token, pool, ALICE, 40_000_000);
        vm.prank(ALICE);
        token.approve(address(pool), 100_000_000);
        SupplyState memory beforeSupply = _snapshot(token, pool);

        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        vm.prank(ALICE);
        pool.supply(0);

        _assertStateUnchanged(token, pool, beforeSupply);
    }

    /// @notice 승인만 부족하면 정확한 승인 오류로 거절하고 기존 예치·승인을 보존한다.
    function test_InsufficientAllowanceRevertsWithoutChangingState() public {
        _approveAndSupply(token, pool, ALICE, 40_000_000);
        token.mint(ALICE, 40_000_000);
        vm.prank(ALICE);
        token.approve(address(pool), 99_000_000);
        SupplyState memory beforeSupply = _snapshot(token, pool);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(pool), 99_000_000, 100_000_000
            )
        );
        vm.prank(ALICE);
        pool.supply(100_000_000);

        _assertStateUnchanged(token, pool, beforeSupply);
    }

    /// @notice 승인을 먼저 차감하더라도 잔고 부족으로 실패하면 승인 100까지 복구된다.
    function test_InsufficientBalanceRestoresSpentAllowanceAndExistingDeposit() public {
        _approveAndSupply(token, pool, ALICE, 101_000_000);
        vm.prank(ALICE);
        token.approve(address(pool), 100_000_000);
        SupplyState memory beforeSupply = _snapshot(token, pool);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 99_000_000, 100_000_000)
        );
        vm.prank(ALICE);
        pool.supply(100_000_000);

        _assertStateUnchanged(token, pool, beforeSupply);
        assertEq(token.allowance(ALICE, address(pool)), 100_000_000);
        assertEq(pool.deposits(ALICE), 101_000_000);
    }

    /// @notice false를 무시하면 실제 토큰 이동이 남는 모형인지 풀 바깥에서 대조한다.
    function test_FalseTokenControlActuallyMovesTokensBeforeReturningFalse() public {
        FailingMockUSDC failureToken = new FailingMockUSDC();
        failureToken.mint(ALICE, 200_000_000);
        vm.prank(ALICE);
        failureToken.approve(address(this), 100_000_000);
        failureToken.setFailureMode(FailingMockUSDC.FailureMode.ReturnFalse);

        bool success = failureToken.transferFrom(ALICE, BOB, 100_000_000);

        assertFalse(success);
        assertEq(failureToken.balanceOf(ALICE), 100_000_000);
        assertEq(failureToken.balanceOf(BOB), 100_000_000);
        assertEq(failureToken.allowance(ALICE, address(this)), 0);
        assertEq(failureToken.totalSupply(), 200_000_000);
    }

    /// @notice 전송 뒤 false를 받으면 토큰 이동·승인 차감을 취소하고 기존 예치 40을 보존한다.
    function test_FalseTransferRollsBackTokenChangesAndKeepsExistingDeposit() public {
        (FailingMockUSDC failureToken, LendingPool failurePool) = _prepareFailurePool();
        failureToken.setFailureMode(FailingMockUSDC.FailureMode.ReturnFalse);
        SupplyState memory beforeSupply = _snapshot(failureToken, failurePool);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(failureToken)));
        vm.prank(ALICE);
        failurePool.supply(100_000_000);

        _assertStateUnchanged(failureToken, failurePool, beforeSupply);
        assertEq(failureToken.balanceOf(ALICE), 160_000_000);
        assertEq(failureToken.balanceOf(address(failurePool)), 40_000_000);
        assertEq(failurePool.deposits(ALICE), 40_000_000);
        assertEq(failureToken.allowance(ALICE, address(failurePool)), 100_000_000);
    }

    /// @notice 토큰이 발생시킨 오류를 그대로 전파하고 성공한 예치와 잔고를 보존한다.
    function test_RevertingTransferBubblesExactErrorAndPreservesState() public {
        (FailingMockUSDC failureToken, LendingPool failurePool) = _prepareFailurePool();
        failureToken.setFailureMode(FailingMockUSDC.FailureMode.Revert);
        SupplyState memory beforeSupply = _snapshot(failureToken, failurePool);

        vm.expectRevert(FailingMockUSDC.InjectedTransferFailure.selector);
        vm.prank(ALICE);
        failurePool.supply(100_000_000);

        _assertStateUnchanged(failureToken, failurePool, beforeSupply);
    }

    /// @notice 직접 전송 10은 권리가 되지 않으며 이후 공급 100에도 섞여 기록되지 않는다.
    function test_DirectTransferDoesNotCreateDepositOrInflateLaterSupply() public {
        vm.recordLogs();
        vm.prank(ALICE);
        bool transferred = token.transfer(address(pool), 10_000_000);
        Vm.Log[] memory donationLogs = vm.getRecordedLogs();

        assertTrue(transferred);
        assertEq(token.balanceOf(ALICE), 190_000_000);
        assertEq(token.balanceOf(address(pool)), 10_000_000);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(pool.deposits(BOB), 0);
        assertEq(token.totalSupply(), 200_000_000);
        _assertNoSupplyEvent(donationLogs, address(pool));

        _approveAndSupply(token, pool, ALICE, 100_000_000);

        assertEq(token.balanceOf(ALICE), 90_000_000);
        assertEq(token.balanceOf(address(pool)), 110_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(pool.deposits(BOB), 0);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
    }

    /// @notice 풀에 직접 발행하면 현금·총발행량만 늘고 기존 예치 권리는 늘지 않는다.
    function test_DirectMintDoesNotChangeExistingDeposits() public {
        _approveAndSupply(token, pool, ALICE, 40_000_000);

        vm.recordLogs();
        token.mint(address(pool), 10_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 160_000_000);
        assertEq(token.balanceOf(address(pool)), 50_000_000);
        assertEq(pool.deposits(ALICE), 40_000_000);
        assertEq(pool.deposits(BOB), 0);
        assertEq(token.totalSupply(), 210_000_000);
        _assertNoSupplyEvent(logs, address(pool));
    }

    /// @notice 충분한 잔고·승인이 있는 중첩 공급만 방어하고 바깥 공급 100은 한 번 반영한다.
    function test_ReentryIsRejectedWhileOuterSupplySucceedsOnce() public {
        ReentrantMockUSDC reentrantToken = new ReentrantMockUSDC();
        LendingPool reentrantPool = new LendingPool(reentrantToken);
        reentrantToken.mint(ALICE, 200_000_000);
        reentrantToken.mint(address(reentrantToken), 1);
        reentrantToken.configureReentry(reentrantPool);
        vm.prank(ALICE);
        reentrantToken.approve(address(reentrantPool), 100_000_000);
        assertEq(reentrantToken.balanceOf(address(reentrantToken)), 1);
        assertEq(reentrantToken.allowance(address(reentrantToken), address(reentrantPool)), 1);

        vm.recordLogs();
        vm.prank(ALICE);
        reentrantPool.supply(100_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(reentrantToken.attempted());
        assertFalse(reentrantToken.nestedSucceeded());
        assertEq(
            reentrantToken.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(reentrantToken.balanceOf(ALICE), 100_000_000);
        assertEq(reentrantToken.balanceOf(address(reentrantPool)), 100_000_000);
        assertEq(reentrantPool.deposits(ALICE), 100_000_000);
        assertEq(reentrantToken.allowance(ALICE, address(reentrantPool)), 0);
        assertEq(reentrantPool.deposits(address(reentrantToken)), 0);
        assertEq(reentrantToken.balanceOf(address(reentrantToken)), 1);
        assertEq(reentrantToken.allowance(address(reentrantToken), address(reentrantPool)), 1);
        assertEq(reentrantToken.balanceOf(BOB), 0);
        assertEq(reentrantPool.deposits(BOB), 0);
        assertEq(reentrantToken.totalSupply(), 200_000_001);
        _assertOneSupplyEvent(logs, address(reentrantPool), ALICE, 100_000_000);
    }

    /// @notice 승인 소진 후에도 40 출금은 토큰·예치·이벤트에 한 번 반영되고 총발행량은 유지된다.
    function test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(token.balanceOf(address(pool)), 100_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(40_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 140_000_000);
        assertEq(token.balanceOf(address(pool)), 60_000_000);
        assertEq(pool.deposits(ALICE), 60_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(pool.deposits(BOB), 0);
        _assertOneWithdrawalEvent(logs, address(pool), ALICE, 40_000_000);
    }

    /// @notice 두 번째 출금 20은 남은 예치에서 차감하고 이벤트도 누적액 대신 요청액을 기록한다.
    function test_AdditionalWithdrawalDebitsRemainingDepositAndEmitsRequestedAmount() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        vm.prank(ALICE);
        pool.withdraw(40_000_000);

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(20_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(token.balanceOf(ALICE), 160_000_000);
        assertEq(pool.deposits(ALICE), 40_000_000);
        assertEq(token.balanceOf(address(pool)), 40_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
        _assertOneWithdrawalEvent(logs, address(pool), ALICE, 20_000_000);
    }

    /// @notice 전액 100 출금은 예치와 현금을 모두 0으로 만들고 초기 토큰을 돌려준다.
    function test_WithdrawAcceptsFullDeposit() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        vm.prank(ALICE);
        pool.withdraw(100_000_000);

        assertEq(token.balanceOf(ALICE), 200_000_000);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
    }

    /// @notice 먼저 40을 출금했어도 남은 예치·현금과 같은 60 출금을 허용한다.
    function test_WithdrawAcceptsExactlyRemainingDepositAndCash() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        vm.prank(ALICE);
        pool.withdraw(40_000_000);
        assertEq(pool.deposits(ALICE), 60_000_000);
        assertEq(token.balanceOf(address(pool)), 60_000_000);

        vm.prank(ALICE);
        pool.withdraw(60_000_000);

        assertEq(token.balanceOf(ALICE), 200_000_000);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
    }

    /// @notice 최소 단위 1의 출금은 반올림 없이 토큰·예치·현금에 반영한다.
    function test_WithdrawAcceptsOneSmallestUnit() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        vm.prank(ALICE);
        pool.withdraw(1);

        assertEq(token.balanceOf(ALICE), 100_000_001);
        assertEq(pool.deposits(ALICE), 99_999_999);
        assertEq(token.balanceOf(address(pool)), 99_999_999);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 200_000_000);
    }

    /// @notice 예치와 현금도 0인 상태에서 0 요청은 금액 오류를 우선 반환한다.
    function test_ZeroWithdrawalTakesPriorityWhenDepositAndCashAreZero() public {
        SupplyState memory beforeWithdrawal = _snapshot(token, pool);

        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        vm.prank(ALICE);
        pool.withdraw(0);

        _assertStateUnchanged(token, pool, beforeWithdrawal);
    }

    /// @notice 이전 출금이 성공했어도 뒤이은 0 출금은 잔고·기록·양쪽 승인량을 보존한다.
    function test_ZeroWithdrawalKeepsPreviousWithdrawalAndApprovals() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        vm.prank(ALICE);
        pool.withdraw(40_000_000);
        vm.prank(ALICE);
        token.approve(address(pool), 7);
        vm.prank(BOB);
        token.approve(address(pool), 9);
        SupplyState memory beforeWithdrawal = _snapshot(token, pool);

        vm.expectRevert(bytes4(keccak256("ZeroAmount()")));
        vm.prank(ALICE);
        pool.withdraw(0);

        _assertStateUnchanged(token, pool, beforeWithdrawal);
    }

    /// @notice 예치와 현금이 모두 60이면 요청 61을 예치금 오류로 먼저 거절한다.
    function test_ExcessWithdrawalRejectsDepositBeforeLiquidityAndPreservesState() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        vm.prank(ALICE);
        pool.withdraw(40_000_000);
        SupplyState memory beforeWithdrawal = _snapshot(token, pool);

        vm.expectRevert(abi.encodeWithSignature("InsufficientDeposit(uint256,uint256)", 60_000_000, 61_000_000));
        vm.prank(ALICE);
        pool.withdraw(61_000_000);

        _assertStateUnchanged(token, pool, beforeWithdrawal);
    }

    /// @notice 예치가 충분해도 현금 50에서 요청 60을 전액 거절하고 조정 후 상태를 보존한다.
    function test_IlliquidWithdrawalRejectsWholeRequestAndPreservesAdjustedState() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        deal(address(token), address(pool), 50_000_000, true);
        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(token.balanceOf(address(pool)), 50_000_000);
        assertEq(token.totalSupply(), 150_000_000);
        SupplyState memory beforeWithdrawal = _snapshot(token, pool);

        vm.expectRevert(abi.encodeWithSignature("InsufficientLiquidity(uint256,uint256)", 50_000_000, 60_000_000));
        vm.prank(ALICE);
        pool.withdraw(60_000_000);

        _assertStateUnchanged(token, pool, beforeWithdrawal);
    }

    /// @notice 예치 100·현금 50에서 정확히 현금 한도 50을 출금할 수 있다.
    function test_WithdrawAcceptsExactCashLimitBelowDeposit() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        deal(address(token), address(pool), 50_000_000, true);
        assertEq(token.totalSupply(), 150_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(token.balanceOf(address(pool)), 50_000_000);

        vm.prank(ALICE);
        pool.withdraw(50_000_000);

        assertEq(token.balanceOf(ALICE), 150_000_000);
        assertEq(pool.deposits(ALICE), 50_000_000);
        assertEq(token.balanceOf(address(pool)), 0);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 150_000_000);
    }

    /// @notice Bob은 풀에 현금이 있어도 Alice의 예치를 자기 출금 권리로 사용할 수 없다.
    function test_WithdrawalWithoutOwnDepositPreservesOtherUserFunds() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        SupplyState memory beforeWithdrawal = _snapshot(token, pool);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientDeposit.selector, 0, 1_000_000));
        vm.prank(BOB);
        pool.withdraw(1_000_000);

        _assertStateUnchanged(token, pool, beforeWithdrawal);
    }

    /// @notice Alice의 출금은 Bob의 예치·토큰·양쪽 승인량을 건드리지 않는다.
    function test_WithdrawalKeepsOtherDepositorAndExistingApprovals() public {
        token.mint(BOB, 30_000_000);
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        _approveAndSupply(token, pool, BOB, 30_000_000);
        vm.prank(ALICE);
        token.approve(address(pool), 7);
        vm.prank(BOB);
        token.approve(address(pool), 9);

        vm.prank(ALICE);
        pool.withdraw(40_000_000);

        assertEq(token.balanceOf(ALICE), 140_000_000);
        assertEq(pool.deposits(ALICE), 60_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(pool.deposits(BOB), 30_000_000);
        assertEq(token.balanceOf(address(pool)), 90_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 7);
        assertEq(token.allowance(BOB, address(pool)), 9);
        assertEq(token.totalSupply(), 230_000_000);
    }

    /// @notice Bob의 직접 송금 10은 현금만 늘리며 Bob에게 출금 권리를 주지 않는다.
    function test_DirectDonorCannotWithdrawWithoutDeposit() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        token.mint(BOB, 10_000_000);
        vm.prank(BOB);
        assertTrue(token.transfer(address(pool), 10_000_000));
        _assertUncreditedBobCannotWithdraw();
    }

    /// @notice 풀에 직접 발행한 10도 예치 권리가 되지 않으므로 Bob의 출금을 거절한다.
    function test_DirectMintCannotCreateWithdrawalRight() public {
        _approveAndSupply(token, pool, ALICE, 100_000_000);
        token.mint(address(pool), 10_000_000);
        _assertUncreditedBobCannotWithdraw();
    }

    /// @dev 직접 유입 후 상태를 먼저 고정하고 Bob의 정확한 오류와 전체 상태 보존을 대조한다.
    function _assertUncreditedBobCannotWithdraw() private {
        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(pool.deposits(BOB), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(address(pool)), 110_000_000);
        assertEq(token.totalSupply(), 210_000_000);
        SupplyState memory beforeWithdrawal = _snapshot(token, pool);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientDeposit.selector, 0, 1_000_000));
        vm.prank(BOB);
        pool.withdraw(1_000_000);

        _assertStateUnchanged(token, pool, beforeWithdrawal);
    }

    /// @notice 직접 transfer 모형도 실제 잔고 변경 뒤 false를 반환하는지 풀 밖에서 대조한다.
    function test_FalseWithdrawalTokenControlActuallyTransfersBeforeReturningFalse() public {
        FailingMockUSDC failureToken = new FailingMockUSDC();
        failureToken.mint(ALICE, 200_000_000);
        failureToken.setTransferFailureMode(FailingMockUSDC.FailureMode.ReturnFalse);

        vm.prank(ALICE);
        bool success = failureToken.transfer(BOB, 40_000_000);

        assertFalse(success);
        assertEq(failureToken.balanceOf(ALICE), 160_000_000);
        assertEq(failureToken.balanceOf(BOB), 40_000_000);
        assertEq(failureToken.totalSupply(), 200_000_000);
    }

    /// @notice 전송 후 false는 예치 선차감·실제 토큰 이동을 취소하고 장애 해제 후 재시도할 수 있다.
    function test_FalseWithdrawalRestoresDebitedDepositAndTransferredTokensThenAllowsRetry() public {
        (FailingMockUSDC failureToken, LendingPool failurePool) = _prepareWithdrawalFailurePool();
        failureToken.setTransferFailureMode(FailingMockUSDC.FailureMode.ReturnFalse);
        SupplyState memory beforeWithdrawal = _snapshot(failureToken, failurePool);

        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(failureToken)));
        vm.prank(ALICE);
        failurePool.withdraw(40_000_000);

        _assertStateUnchanged(failureToken, failurePool, beforeWithdrawal);
        assertEq(failurePool.deposits(ALICE), 100_000_000);
        assertEq(failureToken.balanceOf(ALICE), 100_000_000);
        assertEq(failureToken.balanceOf(address(failurePool)), 100_000_000);

        failureToken.setTransferFailureMode(FailingMockUSDC.FailureMode.None);
        vm.recordLogs();
        vm.prank(ALICE);
        failurePool.withdraw(40_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(failurePool.deposits(ALICE), 60_000_000);
        assertEq(failureToken.balanceOf(ALICE), 140_000_000);
        assertEq(failureToken.balanceOf(address(failurePool)), 60_000_000);
        assertEq(failureToken.allowance(ALICE, address(failurePool)), 7);
        assertEq(failureToken.allowance(BOB, address(failurePool)), 9);
        assertEq(failureToken.totalSupply(), 200_000_000);
        _assertOneWithdrawalEvent(logs, address(failurePool), ALICE, 40_000_000);
    }

    /// @notice transfer의 지정 오류를 그대로 전파하고 예치와 모든 사용자 상태를 보존한다.
    function test_RevertingWithdrawalBubblesExactErrorAndPreservesState() public {
        (FailingMockUSDC failureToken, LendingPool failurePool) = _prepareWithdrawalFailurePool();
        failureToken.setTransferFailureMode(FailingMockUSDC.FailureMode.Revert);
        SupplyState memory beforeWithdrawal = _snapshot(failureToken, failurePool);

        vm.expectRevert(FailingMockUSDC.InjectedTransferFailure.selector);
        vm.prank(ALICE);
        failurePool.withdraw(40_000_000);

        _assertStateUnchanged(failureToken, failurePool, beforeWithdrawal);
    }

    /// @dev 정상 공급 100 뒤 양쪽 승인을 별도로 남기고 transfer 장애는 검사 직전에 켠다.
    function _prepareWithdrawalFailurePool() private returns (FailingMockUSDC failureToken, LendingPool failurePool) {
        failureToken = new FailingMockUSDC();
        failurePool = new LendingPool(failureToken);
        failureToken.mint(ALICE, 200_000_000);
        _approveAndSupply(failureToken, failurePool, ALICE, 100_000_000);
        vm.prank(ALICE);
        failureToken.approve(address(failurePool), 7);
        vm.prank(BOB);
        failureToken.approve(address(failurePool), 9);
        assertEq(failurePool.deposits(ALICE), 100_000_000);
        assertEq(failureToken.balanceOf(ALICE), 100_000_000);
        assertEq(failureToken.balanceOf(address(failurePool)), 100_000_000);
    }

    /// @notice 공급 중 예치가 있는 토큰 주소의 중첩 출금을 거절하고 바깥 공급만 반영한다.
    function test_SupplyRejectsNestedWithdrawalWithFundedDeposit() public {
        (CrossReentrantMockUSDC callbackToken, LendingPool callbackPool) = _prepareCrossReentrantPool();
        callbackToken.arm(
            callbackPool,
            CrossReentrantMockUSDC.CallbackOn.TransferFrom,
            CrossReentrantMockUSDC.NestedAction.Withdraw,
            false,
            ALICE
        );
        _assertCallbackOwnRights(callbackToken, callbackPool);

        vm.recordLogs();
        _approveAndSupply(callbackToken, callbackPool, ALICE, 100_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertRejectedCrossCall(callbackToken, callbackPool, 100_000_000, 100_000_000, 100_000_001);
        assertEq(callbackToken.observedDeposit(), 0);
        _assertOneSupplyEvent(logs, address(callbackPool), ALICE, 100_000_000);
        _assertNoWithdrawalEvent(logs, address(callbackPool));
    }

    /// @notice 출금 중 자체 잔고·승인이 있는 중첩 공급은 거절하고 선차감된 예치 60을 관측한다.
    function test_WithdrawRejectsNestedSupplyAndExposesDebitedDeposit() public {
        (CrossReentrantMockUSDC callbackToken, LendingPool callbackPool) = _prepareCrossReentrantPool();
        _approveAndSupply(callbackToken, callbackPool, ALICE, 100_000_000);
        callbackToken.arm(
            callbackPool,
            CrossReentrantMockUSDC.CallbackOn.Transfer,
            CrossReentrantMockUSDC.NestedAction.Supply,
            false,
            ALICE
        );
        _assertCallbackOwnRights(callbackToken, callbackPool);

        vm.recordLogs();
        vm.prank(ALICE);
        callbackPool.withdraw(40_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertRejectedCrossCall(callbackToken, callbackPool, 140_000_000, 60_000_000, 60_000_001);
        assertEq(callbackToken.observedDeposit(), 60_000_000);
        _assertOneWithdrawalEvent(logs, address(callbackPool), ALICE, 40_000_000);
        _assertNoSupplyEvent(logs, address(callbackPool));
    }

    /// @notice 예치가 있는 토큰 주소의 중첩 출금 오류를 잡으면 바깥 출금 40만 성공한다.
    function test_WithdrawRejectsNestedWithdrawalWhileOuterSucceedsOnce() public {
        (CrossReentrantMockUSDC callbackToken, LendingPool callbackPool) = _prepareCrossReentrantPool();
        _approveAndSupply(callbackToken, callbackPool, ALICE, 100_000_000);
        callbackToken.arm(
            callbackPool,
            CrossReentrantMockUSDC.CallbackOn.Transfer,
            CrossReentrantMockUSDC.NestedAction.Withdraw,
            false,
            ALICE
        );
        _assertCallbackOwnRights(callbackToken, callbackPool);

        vm.recordLogs();
        vm.prank(ALICE);
        callbackPool.withdraw(40_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertRejectedCrossCall(callbackToken, callbackPool, 140_000_000, 60_000_000, 60_000_001);
        assertEq(callbackToken.observedDeposit(), 60_000_000);
        _assertOneWithdrawalEvent(logs, address(callbackPool), ALICE, 40_000_000);
        _assertNoSupplyEvent(logs, address(callbackPool));
    }

    /// @notice 전송 후 중첩 출금 오류를 전파하면 바깥 출금·토큰 이동·모형 관측도 복구된다.
    function test_PropagatedNestedWithdrawalRestoresTokensDepositAndCallbackState() public {
        (CrossReentrantMockUSDC callbackToken, LendingPool callbackPool) = _prepareCrossReentrantPool();
        _approveAndSupply(callbackToken, callbackPool, ALICE, 100_000_000);
        callbackToken.arm(
            callbackPool,
            CrossReentrantMockUSDC.CallbackOn.Transfer,
            CrossReentrantMockUSDC.NestedAction.Withdraw,
            true,
            ALICE
        );
        _assertCallbackOwnRights(callbackToken, callbackPool);
        SupplyState memory beforeWithdrawal = _snapshot(callbackToken, callbackPool);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(ALICE);
        callbackPool.withdraw(40_000_000);

        _assertStateUnchanged(callbackToken, callbackPool, beforeWithdrawal);
        _assertCallbackOwnRights(callbackToken, callbackPool);
        assertFalse(callbackToken.attempted());
        assertFalse(callbackToken.nestedSucceeded());
        assertEq(callbackToken.nestedError().length, 0);
        assertEq(callbackToken.observedDeposit(), 0);
        assertEq(callbackToken.balanceOf(ALICE), 100_000_000);
        assertEq(callbackPool.deposits(ALICE), 100_000_000);
        assertEq(callbackToken.balanceOf(address(callbackPool)), 100_000_001);
    }

    /// @dev 콜백 없이 자체 정상 예치 1을 만들고 중첩 공급용 잔고도 1 남긴다.
    function _prepareCrossReentrantPool()
        private
        returns (CrossReentrantMockUSDC callbackToken, LendingPool callbackPool)
    {
        callbackToken = new CrossReentrantMockUSDC();
        callbackPool = new LendingPool(callbackToken);
        callbackToken.mint(ALICE, 200_000_000);
        callbackToken.mint(address(callbackToken), 2);
        callbackToken.prepareOwnDeposit(callbackPool);
        assertEq(callbackPool.deposits(address(callbackToken)), 1);
        assertEq(callbackToken.balanceOf(address(callbackToken)), 1);
        assertEq(callbackToken.balanceOf(address(callbackPool)), 1);
        assertFalse(callbackToken.attempted());
    }

    /// @dev 방어가 없어도 중첩 호출의 금액·예치·잔고·승인 조건이 만족하는지 확인한다.
    function _assertCallbackOwnRights(CrossReentrantMockUSDC callbackToken, LendingPool callbackPool) private view {
        assertEq(callbackToken.balanceOf(address(callbackToken)), 1);
        assertEq(callbackPool.deposits(address(callbackToken)), 1);
        assertEq(callbackToken.allowance(address(callbackToken), address(callbackPool)), 1);
    }

    /// @dev 정확한 잠금 오류와 바깥 1회 반영, 중첩 호출자·Bob·승인·총량 보존을 함께 관측한다.
    function _assertRejectedCrossCall(
        CrossReentrantMockUSDC callbackToken,
        LendingPool callbackPool,
        uint256 aliceBalance,
        uint256 aliceDeposit,
        uint256 poolBalance
    ) private view {
        assertTrue(callbackToken.attempted());
        assertFalse(callbackToken.nestedSucceeded());
        assertEq(
            callbackToken.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(callbackToken.balanceOf(ALICE), aliceBalance);
        assertEq(callbackPool.deposits(ALICE), aliceDeposit);
        assertEq(callbackToken.balanceOf(address(callbackPool)), poolBalance);
        assertEq(callbackToken.allowance(ALICE, address(callbackPool)), 0);
        assertEq(callbackToken.balanceOf(BOB), 0);
        assertEq(callbackPool.deposits(BOB), 0);
        assertEq(callbackToken.totalSupply(), 200_000_002);
        _assertCallbackOwnRights(callbackToken, callbackPool);
    }

    /// @dev 중첩 출금이 성공한 로그를 바깥 공급의 성공으로 혼동하지 않는다.
    function _assertNoWithdrawalEvent(Vm.Log[] memory logs, address emitter) private pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0) {
                assertNotEq(logs[i].topics[0], WITHDRAWN_TOPIC);
            }
        }
    }

    /// @dev 토큰 Transfer와 구분해 풀 출금 이벤트의 주체·요청 금액·횟수를 확인한다.
    function _assertOneWithdrawalEvent(Vm.Log[] memory logs, address emitter, address user, uint256 amount)
        private
        pure
    {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == WITHDRAWN_TOPIC) {
                ++count;
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
                assertEq(abi.decode(logs[i].data, (uint256)), amount);
            }
        }
        assertEq(count, 1);
    }

    /// @dev 장애를 켜기 전에 40 공급을 완료하고 다음 호출의 유한 승인 100을 별도로 준다.
    function _prepareFailurePool() private returns (FailingMockUSDC failureToken, LendingPool failurePool) {
        failureToken = new FailingMockUSDC();
        failurePool = new LendingPool(failureToken);
        failureToken.mint(ALICE, 200_000_000);
        _approveAndSupply(failureToken, failurePool, ALICE, 40_000_000);
        vm.prank(ALICE);
        failureToken.approve(address(failurePool), 100_000_000);
    }

    /// @dev 승인과 공급의 호출자를 함께 지정하는 정상 준비용 함수다.
    function _approveAndSupply(MockUSDC currentToken, LendingPool currentPool, address user, uint256 amount) private {
        vm.startPrank(user);
        currentToken.approve(address(currentPool), amount);
        currentPool.supply(amount);
        vm.stopPrank();
    }

    /// @dev 실패 직전의 이미 성공한 예치와 별도 승인까지 비교 기준으로 보관한다.
    function _snapshot(MockUSDC currentToken, LendingPool currentPool) private view returns (SupplyState memory) {
        return SupplyState({
            aliceBalance: currentToken.balanceOf(ALICE),
            bobBalance: currentToken.balanceOf(BOB),
            poolBalance: currentToken.balanceOf(address(currentPool)),
            aliceDeposit: currentPool.deposits(ALICE),
            bobDeposit: currentPool.deposits(BOB),
            allowance: currentToken.allowance(ALICE, address(currentPool)),
            bobAllowance: currentToken.allowance(BOB, address(currentPool)),
            totalSupply: currentToken.totalSupply()
        });
    }

    /// @dev 단순 오류 발생과 구분해 호출 직전의 잔고·예치·양쪽 승인·총량을 확인한다.
    function _assertStateUnchanged(MockUSDC currentToken, LendingPool currentPool, SupplyState memory beforeSupply)
        private
        view
    {
        assertEq(currentToken.balanceOf(ALICE), beforeSupply.aliceBalance);
        assertEq(currentToken.balanceOf(BOB), beforeSupply.bobBalance);
        assertEq(currentToken.balanceOf(address(currentPool)), beforeSupply.poolBalance);
        assertEq(currentPool.deposits(ALICE), beforeSupply.aliceDeposit);
        assertEq(currentPool.deposits(BOB), beforeSupply.bobDeposit);
        assertEq(currentToken.allowance(ALICE, address(currentPool)), beforeSupply.allowance);
        assertEq(currentToken.allowance(BOB, address(currentPool)), beforeSupply.bobAllowance);
        assertEq(currentToken.totalSupply(), beforeSupply.totalSupply);
    }

    /// @dev 직접 전송·발행의 Transfer 로그를 공급 이벤트로 잘못 세지 않는다.
    function _assertNoSupplyEvent(Vm.Log[] memory logs, address emitter) private pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0) {
                assertNotEq(logs[i].topics[0], SUPPLIED_TOPIC);
            }
        }
    }

    /// @dev 토큰 Transfer 로그와 구분해 풀 공급 이벤트의 주체·금액·횟수를 확인한다.
    function _assertOneSupplyEvent(Vm.Log[] memory logs, address emitter, address user, uint256 amount) private pure {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics.length > 0 && logs[i].topics[0] == SUPPLIED_TOPIC) {
                ++count;
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
                assertEq(logs[i].data, abi.encode(amount));
            }
        }
        assertEq(count, 1);
    }
}
