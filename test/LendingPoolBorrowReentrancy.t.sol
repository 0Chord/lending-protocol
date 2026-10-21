// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BorrowTestBase} from "./helpers/BorrowTestBase.sol";
import {DebtReentrantMockUSDC} from "./mocks/DebtReentrantMockUSDC.sol";

/// @title 대출·상환과 기존 공급·출금의 공유 재진입 잠금 검사
/// @notice 실제 자원을 갖춘 중첩 raw1 호출의 정확한 오류와 바깥 호출의 한 번 반영·전체 복구를 확인한다.
contract LendingPoolBorrowReentrancyTest is BorrowTestBase {
    DebtReentrantMockUSDC private callbackUSDC;

    /// @notice 기본 대출 준비를 콜백 가능한 USDC로 바꾸며 아직 콜백은 활성화하지 않는다.
    function setUp() public override {
        callbackUSDC = new DebtReentrantMockUSDC();
        _prepareBorrowPool(callbackUSDC);
    }

    /// @notice 부채 선증가와 실제 전송을 관측하고 자원 있는 중첩 상환을 막은 뒤 바깥 대출만 반영한다.
    function testBorrowCatchesNestedRepayAndRecordsOuterBorrowOnce() public {
        _prepareOwnPosition(true);
        uint256[8] memory ownBefore = _participant(address(usdc));
        uint256[8] memory aliceBefore = _participant(ALICE);
        callbackUSDC.arm(
            pool, DebtReentrantMockUSDC.CallbackOn.Transfer, DebtReentrantMockUSDC.NestedAction.Repay, false, BOB
        );

        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(40e6);

        _assertBlocked();
        _assertEight(
            callbackUSDC.observedGlobalState(),
            [
                uint256(100_000_001),
                100_000_001,
                40_000_001,
                60_000_000,
                60_000_000,
                100_000_002,
                100_000_002,
                100_000_003
            ]
        );
        _assertEight(callbackUSDC.observedUserState(), [uint256(40e6), 0, 0, 0, 0, 0, 1e8, 40e6]);
        _assertEight(callbackUSDC.observedOwnState(), ownBefore);
        _assertFinalState(
            [
                uint256(100_000_001),
                100_000_001,
                40_000_001,
                60_000_000,
                60_000_000,
                100_000_002,
                100_000_002,
                100_000_003
            ],
            aliceBefore,
            [uint256(40e6), 0, 0, 0, 0, 0, 1e8, 40e6],
            ownBefore
        );
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 40e6);
    }

    /// @notice 대출 선증가 뒤 중첩 상환 오류를 전파하면 부채·이동 토큰·관측 플래그를 전부 복구한다.
    function testBorrowPropagatesNestedRepayAndRestoresAllState() public {
        _prepareOwnPosition(true);
        uint256[8] memory ownBefore = _participant(address(usdc));
        uint256[8] memory aliceBefore = _participant(ALICE);
        callbackUSDC.arm(
            pool, DebtReentrantMockUSDC.CallbackOn.Transfer, DebtReentrantMockUSDC.NestedAction.Repay, true, BOB
        );
        bytes memory beforeState = _snapshot();
        bytes memory beforeCallback = callbackUSDC.callbackState();

        vm.recordLogs();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(BOB);
        pool.borrow(40e6);

        _assertUnchanged(beforeState);
        assertEq(callbackUSDC.callbackState(), beforeCallback);
        assertFalse(callbackUSDC.attempted());
        callbackUSDC.disableCallback();
        vm.recordLogs();
        vm.prank(BOB);
        pool.borrow(40e6);
        _assertFinalState(
            [
                uint256(100_000_001),
                100_000_001,
                40_000_001,
                60_000_000,
                60_000_000,
                100_000_002,
                100_000_002,
                100_000_003
            ],
            aliceBefore,
            [uint256(40e6), 0, 0, 0, 0, 0, 1e8, 40e6],
            ownBefore
        );
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", BOB, 40e6);
    }

    /// @notice 상환 수령 뒤의 중첩 대출 오류를 전파하면 두 토큰·승인·전체 장부·콜백 저장값이 복구된다.
    function testRepayPropagatesNestedBorrowAndRestoresAllState() public {
        _prepareOwnPosition(false);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 15e6);
        uint256[8] memory ownBefore = _participant(address(usdc));
        uint256[8] memory aliceBefore = _participant(ALICE);
        callbackUSDC.arm(
            pool, DebtReentrantMockUSDC.CallbackOn.TransferFrom, DebtReentrantMockUSDC.NestedAction.Borrow, true, BOB
        );
        bytes memory beforeState = _snapshot();
        bytes memory beforeCallback = callbackUSDC.callbackState();

        vm.recordLogs();
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(BOB);
        pool.repay(15e6);

        _assertUnchanged(beforeState);
        assertEq(callbackUSDC.callbackState(), beforeCallback);
        assertFalse(callbackUSDC.attempted());
        callbackUSDC.disableCallback();
        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(15e6);
        _assertFinalState(
            [
                uint256(100_000_001),
                100_000_001,
                25_000_000,
                75_000_001,
                75_000_001,
                100_000_002,
                100_000_002,
                100_000_003
            ],
            aliceBefore,
            [uint256(25e6), 0, 0, 0, 0, 0, 1e8, 25e6],
            ownBefore
        );
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 15e6);
    }

    /// @notice 기존 공급의 실제 수령 뒤 중첩 대출도 차단하고 공급 기록과 이벤트만 한 번 남긴다.
    function testSupplyCatchesNestedBorrowAndRecordsOuterSupplyOnce() public {
        _prepareOwnPosition(false);
        usdc.mint(ALICE, 10e6);
        vm.prank(ALICE);
        usdc.approve(address(pool), 10e6);
        uint256[8] memory ownBefore = _participant(address(usdc));
        uint256[8] memory bobBefore = _participant(BOB);
        callbackUSDC.arm(
            pool, DebtReentrantMockUSDC.CallbackOn.TransferFrom, DebtReentrantMockUSDC.NestedAction.Borrow, false, ALICE
        );

        vm.recordLogs();
        vm.prank(ALICE);
        pool.supply(10e6);

        _assertBlocked();
        _assertEight(
            callbackUSDC.observedGlobalState(),
            [uint256(100_000_001), 100_000_001, 0, 100_000_001, 110_000_001, 100_000_002, 110_000_002, 100_000_003]
        );
        _assertEight(callbackUSDC.observedUserState(), [uint256(0), 0, 0, 0, 100e6, 100e6, 0, 0]);
        _assertEight(callbackUSDC.observedOwnState(), ownBefore);
        _assertFinalState(
            [uint256(110_000_001), 110_000_001, 0, 110_000_001, 110_000_001, 100_000_002, 110_000_002, 100_000_003],
            [uint256(0), 0, 0, 0, 110e6, 110e6, 0, 0],
            bobBefore,
            ownBefore
        );
        _assertEvent(vm.getRecordedLogs(), "Supplied(address,uint256)", ALICE, 10e6);
    }

    /// @notice 기존 출금의 선차감·실제 지급 뒤 중첩 상환도 차단하고 출금 한 번만 반영한다.
    function testWithdrawCatchesNestedRepayAndRecordsOuterWithdrawOnce() public {
        _prepareOwnPosition(true);
        uint256[8] memory ownBefore = _participant(address(usdc));
        uint256[8] memory bobBefore = _participant(BOB);
        callbackUSDC.arm(
            pool, DebtReentrantMockUSDC.CallbackOn.Transfer, DebtReentrantMockUSDC.NestedAction.Repay, false, ALICE
        );

        vm.recordLogs();
        vm.prank(ALICE);
        pool.withdraw(10e6);

        _assertBlocked();
        _assertEight(
            callbackUSDC.observedGlobalState(),
            [uint256(90_000_001), 90_000_001, 1, 90_000_000, 90_000_000, 100_000_002, 100_000_002, 100_000_003]
        );
        _assertEight(callbackUSDC.observedUserState(), [uint256(10e6), 0, 0, 0, 90e6, 90e6, 0, 0]);
        _assertEight(callbackUSDC.observedOwnState(), ownBefore);
        _assertFinalState(
            [uint256(90_000_001), 90_000_001, 1, 90_000_000, 90_000_000, 100_000_002, 100_000_002, 100_000_003],
            [uint256(10e6), 0, 0, 0, 90e6, 90e6, 0, 0],
            bobBefore,
            ownBefore
        );
        _assertEvent(vm.getRecordedLogs(), "Withdrawn(address,uint256)", ALICE, 10e6);
    }

    /// @notice 같은 담보raw2·가격100 준비에서 중첩 잠금이 없는 대출raw1은 실제 성공한다.
    function testNestedBorrowResourcesPermitNormalRawOneBorrow() public {
        _prepareOwnPosition(false);
        vm.recordLogs();
        vm.prank(address(callbackUSDC));
        pool.borrow(1);
        _assertEight(_participant(address(callbackUSDC)), [uint256(2), 1, 1, 1, 1, 1, 2, 1]);
        assertEq(pool.totalDebt(), 1);
        _assertEvent(vm.getRecordedLogs(), "Borrowed(address,uint256)", address(callbackUSDC), 1);
    }

    /// @notice 같은 부채·잔고·승인 준비에서 중첩 잠금이 없는 상환raw1은 실제 성공한다.
    function testNestedRepayResourcesPermitNormalRawOneRepay() public {
        _prepareOwnPosition(true);
        vm.recordLogs();
        vm.prank(address(callbackUSDC));
        pool.repay(1);
        _assertEight(_participant(address(callbackUSDC)), [uint256(1), 1, 0, 1, 1, 1, 2, 0]);
        assertEq(pool.totalDebt(), 0);
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", address(callbackUSDC), 1);
    }

    /// @notice 오류를 잡은 상환 콜백은 실제 수령·승인 소비 뒤에도 감소 전 부채를 관측한다.
    function testRepayCatchesNestedBorrowAndObservesDebtBeforeReduction() public {
        _prepareOwnPosition(false);
        vm.prank(BOB);
        pool.borrow(40e6);
        vm.prank(BOB);
        usdc.approve(address(pool), 15e6);
        uint256[8] memory ownBefore = _participant(address(usdc));
        uint256[8] memory aliceBefore = _participant(ALICE);
        callbackUSDC.arm(
            pool, DebtReentrantMockUSDC.CallbackOn.TransferFrom, DebtReentrantMockUSDC.NestedAction.Borrow, false, BOB
        );

        vm.recordLogs();
        vm.prank(BOB);
        pool.repay(15e6);

        _assertBlocked();
        _assertEight(
            callbackUSDC.observedGlobalState(),
            [
                uint256(100_000_001),
                100_000_001,
                40_000_000,
                60_000_001,
                75_000_001,
                100_000_002,
                100_000_002,
                100_000_003
            ]
        );
        _assertEight(callbackUSDC.observedUserState(), [uint256(25e6), 0, 0, 0, 0, 0, 1e8, 40e6]);
        _assertEight(callbackUSDC.observedOwnState(), ownBefore);
        _assertFinalState(
            [
                uint256(100_000_001),
                100_000_001,
                25_000_000,
                75_000_001,
                75_000_001,
                100_000_002,
                100_000_002,
                100_000_003
            ],
            aliceBefore,
            [uint256(25e6), 0, 0, 0, 0, 0, 1e8, 25e6],
            ownBefore
        );
        _assertEvent(vm.getRecordedLogs(), "Repaid(address,uint256)", BOB, 15e6);
    }

    /// @notice 예상한 전역8값과 모든 참여자의 두 토큰·승인·공급 권리·담보·부채를 비교한다.
    function _assertFinalState(
        uint256[8] memory expectedGlobal,
        uint256[8] memory expectedAlice,
        uint256[8] memory expectedBob,
        uint256[8] memory expectedOwn
    ) private view {
        uint256[8] memory emptyCharlie;
        assertEq(_snapshot(), abi.encode(expectedGlobal, expectedAlice, expectedBob, emptyCharlie, expectedOwn));
    }

    /// @notice 정상 공급raw1·담보raw2와 선택적 대출raw1을 만들어 중첩 호출의 부족 오류를 배제한다.
    function _prepareOwnPosition(bool withDebt) private {
        usdc.mint(address(callbackUSDC), 2);
        wbtc.mint(address(callbackUSDC), 3);
        callbackUSDC.prepareOwnPosition(pool, withDebt);
        _assertEight(
            _participant(address(callbackUSDC)), [withDebt ? uint256(2) : 1, 1, 1, 1, 1, 1, 2, withDebt ? 1 : 0]
        );
        (int256 currentPrice, uint256 updatedAt) = price.latestPrice();
        assertEq(currentPrice, 100e8);
        assertEq(updatedAt, block.timestamp);
        assertGe(pool.availableLiquidity(), 1);
    }

    /// @notice 중첩 호출이 실제 실행됐고 일반 부족 오류 대신 정확한 잠금 오류를 반환했는지 확인한다.
    function _assertBlocked() private view {
        assertTrue(callbackUSDC.attempted());
        assertFalse(callbackUSDC.nestedSucceeded());
        assertEq(
            callbackUSDC.nestedError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
        );
    }

    /// @notice 관련 장부·토큰 관측8값을 생략 없이 비교한다.
    function _assertEight(uint256[8] memory actual, uint256[8] memory expected) private pure {
        for (uint256 i; i < actual.length; ++i) {
            assertEq(actual[i], expected[i]);
        }
    }
}
