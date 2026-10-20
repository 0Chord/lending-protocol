// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {LendingPoolHarness} from "./mocks/LendingPoolHarness.sol";
import {FailingMockUSDC} from "./mocks/FailingMockUSDC.sol";
import {CrossReentrantMockUSDC} from "./mocks/CrossReentrantMockUSDC.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title 실제 풀의 지분 환산·거절·복구 검증
/// @notice 정상 토큰 이동과 시험용 인정자산 주입을 구분해 검증한다.
contract LendingPoolSharesTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    MockUSDC private token;
    LendingPoolHarness private pool;

    /// @notice 각 사례는 별도 토큰·풀에서 시작한다.
    function setUp() public {
        token = new MockUSDC();
        pool = new LendingPoolHarness(token);
        token.mint(ALICE, 200_000_000);
    }

    /// @notice 양수 공급의 지분이 0이면 전송·승인을 소비하기 전에 거절한다.
    function test_ZeroShareSupplyPreservesAllState() public {
        _prepareRatio(new MockUSDC(), 10, 1, 0);
        token.mint(BOB, 1);
        vm.prank(BOB);
        token.approve(address(pool), 1);
        uint256[12] memory beforeSupply = _state();

        vm.expectRevert(abi.encodeWithSignature("ZeroShares()"));
        vm.prank(BOB);
        pool.supply(1);

        _assertUnchanged(beforeSupply);
    }

    /// @notice 마지막 총지분을 없애며 인정자산1을 남기는 출금은 전체 거절한다.
    function test_LastSharesWithResidualAssetRevert() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        uint256[12] memory beforeWithdrawal = _state();

        vm.expectRevert(abi.encodeWithSignature("ResidualAssets(uint256)", uint256(1)));
        vm.prank(ALICE);
        pool.withdraw(9_999_999);

        _assertUnchanged(beforeWithdrawal);
    }

    /// @notice 직접 송금20은 권리를 늘리지 않고 전액 출금·새 공급 뒤에도 잉여로 남는다.
    function test_DirectTransferLeavesSurplusAcrossExitAndRestart() public {
        _donationAndRestart(true);
    }

    /// @notice 풀에 직접 발행한20도 기존·새 공급자의 지분에 포함하지 않는다.
    function test_DirectMintLeavesSurplusAcrossExitAndRestart() public {
        _donationAndRestart(false);
    }

    /// @notice 빈 풀의 직접 유입20을 첫 정상 공급100의 지분으로 포획할 수 없다.
    function test_InitialDonationDoesNotBelongToFirstSupplier() public {
        token.mint(address(pool), 20_000_000);
        _assertBook(0, 0, 0, 0, 20_000_000);
        assertEq(pool.deposits(ALICE), 0);

        _supply(ALICE, 100_000_000);

        _assertBook(100_000_000, 100_000_000, 100_000_000, 0, 120_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(token.balanceOf(ALICE), 100_000_000);
        assertEq(token.totalSupply(), 220_000_000);
    }

    /// @notice 공급 전10/6 비율로4 USDC를 받으면2.4지분을 발행하고 이벤트는4 USDC다.
    function test_NonUnitSupplyUsesPreTransferRate() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        token.mint(BOB, 4_000_000);
        vm.recordLogs();

        _supply(BOB, 4_000_000);

        _assertBook(14_000_000, 8_400_000, 6_000_000, 2_400_000, 14_000_000);
        assertEq(pool.deposits(ALICE), 10_000_000);
        assertEq(pool.deposits(BOB), 4_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(BOB, address(pool)), 0);
        assertEq(token.totalSupply(), 14_000_000);
        _assertEvent(vm.getRecordedLogs(), keccak256("Supplied(address,uint256)"), BOB, 4_000_000);
    }

    /// @notice 나머지가 있는 공급은 지분을 내리고 두 환산권리의 합이 자산보다1 작을 수 있다.
    function test_RoundedSupplyPreservesSharesAndFloorsClaims() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        token.mint(BOB, 1_000_001);
        vm.recordLogs();

        _supply(BOB, 1_000_001);

        _assertBook(11_000_001, 6_600_000, 6_000_000, 600_000, 11_000_001);
        assertEq(pool.deposits(ALICE), 10_000_000);
        assertEq(pool.deposits(BOB), 1_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(BOB, address(pool)), 0);
        assertEq(token.totalSupply(), 11_000_001);
        _assertEvent(vm.getRecordedLogs(), keccak256("Supplied(address,uint256)"), BOB, 1_000_001);
    }

    /// @notice 비1:1에서4 USDC 출금은 정확한2.4지분을 차감하며 지급·이벤트는4 USDC다.
    function test_NonUnitWithdrawalBurnsExactFractionalShares() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        vm.recordLogs();

        vm.prank(ALICE);
        pool.withdraw(4_000_000);

        _assertBook(6_000_000, 3_600_000, 3_600_000, 0, 6_000_000);
        assertEq(pool.deposits(ALICE), 6_000_000);
        assertEq(token.balanceOf(ALICE), 4_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 10_000_000);
        _assertEvent(vm.getRecordedLogs(), keccak256("Withdrawn(address,uint256)"), ALICE, 4_000_000);
    }

    /// @notice 최소 USDC 단위1 출금은0.6지분 최소 단위를1로 올려 차감한다.
    function test_SmallestWithdrawalRoundsShareBurnUp() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        vm.prank(ALICE);
        pool.withdraw(1);
        _assertBook(9_999_999, 5_999_999, 5_999_999, 0, 9_999_999);
        assertEq(pool.deposits(ALICE), 9_999_999);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.totalSupply(), 10_000_000);
    }

    /// @notice 인정자산 전액 출금은 마지막 지분과 자산이 함께0이 되므로 허용한다.
    function test_FullNonUnitWithdrawalClearsAccounting() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        vm.prank(ALICE);
        pool.withdraw(10_000_000);
        _assertBook(0, 0, 0, 0, 0);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(token.balanceOf(ALICE), 10_000_000);
        assertEq(token.totalSupply(), 10_000_000);
    }

    /// @notice 마지막 지분의 잔여 자산보다 실제 현금 부족 오류가 먼저다.
    function test_InsufficientCashTakesPriorityOverResidualAssets() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 6_000_000, 0);
        deal(address(token), address(pool), 9_000_000, true);
        uint256[12] memory beforeWithdrawal = _state();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientLiquidity.selector, 9_000_000, 9_999_999));
        vm.prank(ALICE);
        pool.withdraw(9_999_999);
        _assertUnchanged(beforeWithdrawal);
    }

    /// @notice 총지분·현금이 충분해도 본인 지분의 환산권리5를 넘는6 출금은 거절한다.
    function test_PersonalClaimIsCheckedInsteadOfTotalShares() public {
        _prepareRatio(new MockUSDC(), 10_000_000, 3_000_000, 3_000_000);
        assertEq(pool.deposits(ALICE), 5_000_000);
        uint256[12] memory beforeWithdrawal = _state();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientDeposit.selector, 5_000_000, 6_000_000));
        vm.prank(ALICE);
        pool.withdraw(6_000_000);
        _assertUnchanged(beforeWithdrawal);
    }

    /// @notice 다른 사용자 지분은 보존하지만 반올림 뒤 그 지분의 USDC 가치는 달라질 수 있다.
    function test_OtherSharesStayFixedWhileConvertedClaimChanges() public {
        _prepareRatio(new MockUSDC(), 10, 3, 3);
        assertEq(pool.deposits(BOB), 5);
        vm.prank(ALICE);
        pool.withdraw(2);
        _assertBook(8, 4, 1, 3, 8);
        assertEq(pool.deposits(ALICE), 2);
        assertEq(pool.deposits(BOB), 6);
        assertEq(token.balanceOf(ALICE), 2);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), 10);
    }

    /// @notice 두 사용자 지분 합은 총지분과 같아도 내림한 권리 합은 인정자산보다 작을 수 있다.
    function test_RoundedClaimsNeedNotSumToAccountedAssets() public {
        _prepareRatio(new MockUSDC(), 10, 1, 5);
        _assertBook(10, 6, 1, 5, 10);
        assertEq(pool.deposits(ALICE), 1);
        assertEq(pool.deposits(BOB), 8);
        assertEq(pool.deposits(ALICE) + pool.deposits(BOB), 9);
    }

    /// @notice 지분0 공급은 승인 부족보다 먼저 거절하며 Bob의 토큰을 보존한다.
    function test_ZeroSharesTakesPriorityOverMissingAllowance() public {
        _prepareRatio(new MockUSDC(), 10, 1, 0);
        token.mint(BOB, 1);
        uint256[12] memory beforeSupply = _state();
        vm.expectRevert(abi.encodeWithSignature("ZeroShares()"));
        vm.prank(BOB);
        pool.supply(1);
        _assertUnchanged(beforeSupply);
    }

    /// @notice 토큰 장애가 켜져 있어도 지분0 오류가 전송보다 먼저 발생한다.
    function test_ZeroSharesTakesPriorityOverTokenFailure() public {
        FailingMockUSDC failureToken = new FailingMockUSDC();
        _prepareRatio(failureToken, 10, 1, 0);
        token.mint(BOB, 1);
        vm.prank(BOB);
        token.approve(address(pool), 1);
        failureToken.setFailureMode(FailingMockUSDC.FailureMode.Revert);
        uint256[12] memory beforeSupply = _state();
        vm.expectRevert(abi.encodeWithSignature("ZeroShares()"));
        vm.prank(BOB);
        pool.supply(1);
        _assertUnchanged(beforeSupply);
    }

    /// @notice 자산만0인 장부는 지분0 주소의 조회도 오류이며 금액0 요청은 별도 우선 오류다.
    function test_MissingAssetsRejectsPositiveCallsAndAllClaimQueries() public {
        _prepareRatio(new MockUSDC(), 1, 1, 0);
        pool.setAccountedAssetsForTest(0);
        _assertInvalidAccounting(0, 1);
    }

    /// @notice 지분만0인 장부도 임의 초기화하지 않고 동일한 우선순위로 거절한다.
    function test_MissingSharesRejectsPositiveCallsAndAllClaimQueries() public {
        token.mint(address(pool), 1);
        pool.setAccountedAssetsForTest(1);
        _assertInvalidAccounting(1, 0);
    }

    /// @notice 전송 뒤 회계 합산이 넘치면 토큰 이동·유한 승인까지 모두 복구한다.
    function test_SupplyAccountingOverflowRestoresTransferAndAllowance() public {
        uint256 max = type(uint256).max;
        _prepareRatio(new MockUSDC(), max, max, 0);
        deal(address(token), address(pool), 0, true);
        token.mint(ALICE, 1);
        vm.prank(ALICE);
        token.approve(address(pool), 1);
        _assertBook(max, max, max, 0, 0);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.allowance(ALICE, address(pool)), 1);
        assertEq(token.totalSupply(), 1);
        assertEq(pool.deposits(ALICE), max);
        uint256[12] memory beforeSupply = _state();

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        vm.prank(ALICE);
        pool.supply(1);

        _assertUnchanged(beforeSupply);
    }

    /// @notice 비1:1 공급의 실제 전송 뒤 false를 받으면 회계·승인을 복구하고 재시도할 수 있다.
    function test_NonUnitFalseSupplyRestoresStateAndAllowsRetry() public {
        FailingMockUSDC failureToken = new FailingMockUSDC();
        _prepareRatio(failureToken, 10_000_000, 6_000_000, 0);
        token.mint(BOB, 4_000_000);
        vm.prank(BOB);
        token.approve(address(pool), 4_000_000);
        failureToken.setFailureMode(FailingMockUSDC.FailureMode.ReturnFalse);
        uint256[12] memory beforeSupply = _state();
        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(token)));
        vm.prank(BOB);
        pool.supply(4_000_000);
        _assertUnchanged(beforeSupply);

        failureToken.setFailureMode(FailingMockUSDC.FailureMode.None);
        vm.prank(BOB);
        pool.supply(4_000_000);
        _assertBook(14_000_000, 8_400_000, 6_000_000, 2_400_000, 14_000_000);
        assertEq(pool.deposits(BOB), 4_000_000);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(BOB, address(pool)), 0);
        assertEq(token.totalSupply(), 14_000_000);
    }

    /// @notice 비1:1 출금의 선차감 뒤 전송 false가 나면 지분까지 복구하고 같은 출금을 재시도한다.
    function test_NonUnitFalseWithdrawalRestoresStateAndAllowsRetry() public {
        FailingMockUSDC failureToken = new FailingMockUSDC();
        _prepareRatio(failureToken, 10_000_000, 6_000_000, 0);
        failureToken.setTransferFailureMode(FailingMockUSDC.FailureMode.ReturnFalse);
        uint256[12] memory beforeWithdrawal = _state();
        vm.expectRevert(abi.encodeWithSignature("SafeERC20FailedOperation(address)", address(token)));
        vm.prank(ALICE);
        pool.withdraw(4_000_000);
        _assertUnchanged(beforeWithdrawal);

        failureToken.setTransferFailureMode(FailingMockUSDC.FailureMode.None);
        vm.prank(ALICE);
        pool.withdraw(4_000_000);
        _assertBook(6_000_000, 3_600_000, 3_600_000, 0, 6_000_000);
        assertEq(pool.deposits(ALICE), 6_000_000);
        assertEq(token.balanceOf(ALICE), 4_000_000);
        assertEq(token.allowance(ALICE, address(pool)), 0);
        assertEq(token.totalSupply(), 10_000_000);
    }

    /// @notice 잠금 오류를 잡으면 비1:1 바깥 출금2만 반영하고 선차감한 장부를 관측한다.
    function test_NonUnitCaughtReentryLeavesOneOuterWithdrawal() public {
        CrossReentrantMockUSDC callbackToken = _prepareNonUnitReentry(false);
        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(2);

        assertTrue(callbackToken.attempted());
        assertFalse(callbackToken.nestedSucceeded());
        assertEq(
            callbackToken.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
        assertEq(callbackToken.observedAssets(), 8);
        assertEq(callbackToken.observedTotalShares(), 4);
        assertEq(callbackToken.observedShares(), 3);
        assertEq(callbackToken.observedOwnShares(), 1);
        assertEq(callbackToken.observedDeposit(), 6);
        assertEq(pool.totalAssets(), 8);
        assertEq(pool.totalShares(), 4);
        assertEq(pool.shares(ALICE), 3);
        assertEq(pool.shares(address(callbackToken)), 1);
        assertEq(pool.shares(BOB), 0);
        assertEq(pool.deposits(ALICE), 6);
        assertEq(pool.deposits(address(callbackToken)), 2);
        assertEq(token.balanceOf(ALICE), 2);
        assertEq(token.balanceOf(address(pool)), 8);
        assertEq(token.balanceOf(address(callbackToken)), 1);
        assertEq(token.allowance(address(callbackToken), address(pool)), 1);
        assertEq(token.totalSupply(), 11);
        _assertEvent(vm.getRecordedLogs(), keccak256("Withdrawn(address,uint256)"), ALICE, 2);
    }

    /// @notice 비1:1 중첩 출금 오류를 전파하면 토큰 이동·선차감·콜백 관측 모두 복구한다.
    function test_NonUnitPropagatedReentryRestoresAccountingAndCallbackState() public {
        CrossReentrantMockUSDC callbackToken = _prepareNonUnitReentry(true);
        uint256[12] memory beforeWithdrawal = _state();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(ALICE);
        pool.withdraw(2);

        _assertUnchanged(beforeWithdrawal);
        assertEq(pool.shares(address(callbackToken)), 1);
        assertEq(pool.deposits(address(callbackToken)), 1);
        assertEq(token.balanceOf(address(callbackToken)), 1);
        assertEq(token.allowance(address(callbackToken), address(pool)), 1);
        assertFalse(callbackToken.attempted());
        assertFalse(callbackToken.nestedSucceeded());
        assertEq(callbackToken.nestedError().length, 0);
        assertEq(callbackToken.observedDeposit(), 0);
        assertEq(callbackToken.observedAssets(), 0);
        assertEq(callbackToken.observedTotalShares(), 0);
        assertEq(callbackToken.observedShares(), 0);
        assertEq(callbackToken.observedOwnShares(), 0);
    }

    /// @dev 최소 단위 A10/S6, Alice q5·토큰 q1에서 유효한 중첩 출금1을 준비한다.
    function _prepareNonUnitReentry(bool propagateError) private returns (CrossReentrantMockUSDC callbackToken) {
        callbackToken = new CrossReentrantMockUSDC();
        token = callbackToken;
        pool = new LendingPoolHarness(token);
        token.mint(address(callbackToken), 2);
        callbackToken.prepareOwnDeposit(pool);
        token.mint(ALICE, 5);
        _supply(ALICE, 5);
        token.mint(address(pool), 4);
        assertEq(pool.totalAssets(), 6);
        assertEq(token.balanceOf(address(pool)), 10);
        pool.setAccountedAssetsForTest(10);
        callbackToken.arm(
            pool,
            CrossReentrantMockUSDC.CallbackOn.Transfer,
            CrossReentrantMockUSDC.NestedAction.Withdraw,
            propagateError,
            ALICE
        );
        assertEq(pool.totalAssets(), 10);
        assertEq(pool.totalShares(), 6);
        assertEq(pool.shares(ALICE), 5);
        assertEq(pool.shares(address(callbackToken)), 1);
        assertEq(pool.deposits(address(callbackToken)), 1);
        assertEq(token.balanceOf(address(callbackToken)), 1);
        assertEq(token.allowance(address(callbackToken), address(pool)), 1);
        assertEq(token.totalSupply(), 11);
    }

    /// @dev 잘못된 장부에서는 환산 조회를 snapshot에 넣지 않고 원시10개 값을 비교한다.
    function _assertInvalidAccounting(uint256 assets, uint256 total) private {
        assertEq(pool.totalAssets(), assets);
        assertEq(pool.totalShares(), total);
        uint256[10] memory beforeCalls = _rawState();
        bytes memory expected = abi.encodeWithSignature("InvalidAccountingState(uint256,uint256)", assets, total);
        vm.expectRevert(expected);
        pool.deposits(ALICE);
        vm.expectRevert(expected);
        pool.deposits(BOB);
        vm.expectRevert(expected);
        vm.prank(BOB);
        pool.supply(1);
        vm.expectRevert(expected);
        vm.prank(BOB);
        pool.withdraw(1);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.supply(0);
        vm.expectRevert(LendingPool.ZeroAmount.selector);
        pool.withdraw(0);
        uint256[10] memory afterCalls = _rawState();
        for (uint256 i; i < beforeCalls.length; ++i) {
            assertEq(afterCalls[i], beforeCalls[i]);
        }
    }

    /// @dev 장부가 잘못돼도 읽을 수 있는 원시 기록과 토큰 상태만 수집한다.
    function _rawState() private view returns (uint256[10] memory) {
        return [
            pool.totalAssets(),
            pool.totalShares(),
            pool.shares(ALICE),
            pool.shares(BOB),
            token.balanceOf(ALICE),
            token.balanceOf(BOB),
            token.balanceOf(address(pool)),
            token.allowance(ALICE, address(pool)),
            token.allowance(BOB, address(pool)),
            token.totalSupply()
        ];
    }

    /// @dev 직접 유입 경로만 바꾸고 기존 권리·전액 출금·재시작의 같은 계약을 확인한다.
    function _donationAndRestart(bool viaTransfer) private {
        _supply(ALICE, 100_000_000);
        if (viaTransfer) {
            token.mint(BOB, 20_000_000);
            vm.prank(BOB);
            assertTrue(token.transfer(address(pool), 20_000_000));
        } else {
            token.mint(address(pool), 20_000_000);
        }
        _assertBook(100_000_000, 100_000_000, 100_000_000, 0, 120_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);
        assertEq(pool.deposits(BOB), 0);
        uint256[12] memory beforeDonorWithdrawal = _state();
        vm.expectRevert(abi.encodeWithSelector(LendingPool.InsufficientDeposit.selector, 0, 1_000_000));
        vm.prank(BOB);
        pool.withdraw(1_000_000);
        _assertUnchanged(beforeDonorWithdrawal);

        vm.prank(ALICE);
        pool.withdraw(100_000_000);
        _assertBook(0, 0, 0, 0, 20_000_000);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(pool.deposits(BOB), 0);
        assertEq(token.balanceOf(ALICE), 200_000_000);
        token.mint(BOB, 10_000_000);
        _supply(BOB, 10_000_000);
        _assertBook(10_000_000, 10_000_000, 0, 10_000_000, 30_000_000);
        assertEq(pool.deposits(BOB), 10_000_000);
        assertEq(pool.deposits(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(BOB, address(pool)), 0);
        assertEq(token.totalSupply(), 230_000_000);
    }

    /// @dev 두 사용자만 있는 준비에서 자산·총지분·개인 지분·현금을 고정값과 비교한다.
    function _assertBook(uint256 assets, uint256 total, uint256 alice, uint256 bob, uint256 cash) private view {
        assertEq(pool.totalAssets(), assets);
        assertEq(pool.totalShares(), total);
        assertEq(pool.shares(ALICE), alice);
        assertEq(pool.shares(BOB), bob);
        assertEq(pool.shares(ALICE) + pool.shares(BOB), total);
        assertEq(token.balanceOf(address(pool)), cash);
    }

    /// @dev 토큰 로그와 구분해 풀 이벤트의 주체·USDC 수량·1회를 확인한다.
    function _assertEvent(Vm.Log[] memory logs, bytes32 topic, address user, uint256 amount) private view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(pool) && logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                ++count;
                assertEq(logs[i].topics.length, 2);
                assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
                assertEq(abi.decode(logs[i].data, (uint256)), amount);
            }
        }
        assertEq(count, 1);
    }

    /// @dev 정상 1:1 공급으로 개인 지분을 만들고 직접 발행과 시험용 장부 주입을 구분한다.
    function _prepareRatio(MockUSDC currentToken, uint256 assets, uint256 aliceShares, uint256 bobShares) private {
        token = currentToken;
        pool = new LendingPoolHarness(token);
        token.mint(ALICE, aliceShares);
        _supply(ALICE, aliceShares);
        if (bobShares != 0) {
            token.mint(BOB, bobShares);
            _supply(BOB, bobShares);
        }
        uint256 initialShares = aliceShares + bobShares;
        token.mint(address(pool), assets - initialShares);
        assertEq(pool.totalAssets(), initialShares);
        assertEq(pool.totalShares(), initialShares);
        assertEq(token.balanceOf(address(pool)), assets);
        pool.setAccountedAssetsForTest(assets);
        assertEq(pool.totalAssets(), assets);
        assertEq(pool.shares(ALICE), aliceShares);
        assertEq(pool.shares(BOB), bobShares);
    }

    /// @dev 별도 승인과 실제 공급을 같은 사용자로 준비한다.
    function _supply(address user, uint256 amount) private {
        vm.startPrank(user);
        token.approve(address(pool), amount);
        pool.supply(amount);
        vm.stopPrank();
    }

    /// @dev 장부·두 사용자의 권리·토큰·승인·총량을 호출 직전 값으로 보관한다.
    function _state() private view returns (uint256[12] memory) {
        return [
            pool.totalAssets(),
            pool.totalShares(),
            pool.shares(ALICE),
            pool.shares(BOB),
            pool.deposits(ALICE),
            pool.deposits(BOB),
            token.balanceOf(ALICE),
            token.balanceOf(BOB),
            token.balanceOf(address(pool)),
            token.allowance(ALICE, address(pool)),
            token.allowance(BOB, address(pool)),
            token.totalSupply()
        ];
    }

    /// @dev 오류 종류뿐 아니라 직전12개 상태가 모두 보존되는지 확인한다.
    function _assertUnchanged(uint256[12] memory expected) private view {
        uint256[12] memory actual = _state();
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }
}
