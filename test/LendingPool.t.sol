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

/// @title 본인 공급과 예치 기록 검증
/// @notice 승인과 실제 전송을 구분하고 명세의 고정 금액을 비교한다.
contract LendingPoolTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    bytes32 private constant SUPPLIED_TOPIC = keccak256("Supplied(address,uint256)");

    MockUSDC private token;
    LendingPool private pool;

    struct SupplyState {
        uint256 aliceBalance;
        uint256 bobBalance;
        uint256 poolBalance;
        uint256 aliceDeposit;
        uint256 bobDeposit;
        uint256 allowance;
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
            totalSupply: currentToken.totalSupply()
        });
    }

    /// @dev 단순 오류 발생과 구분해 공급 호출 직전의 일곱 상태가 그대로인지 확인한다.
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
