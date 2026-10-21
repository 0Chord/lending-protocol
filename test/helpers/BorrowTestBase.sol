// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {LendingPool} from "../../src/LendingPool.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../../src/mocks/MockWBTC.sol";
import {MockCollateralPriceSource} from "../mocks/MockCollateralPriceSource.sol";

/// @title 총발행량100·정상 공급100·Bob 담보1의 대출 준비
abstract contract BorrowTestBase is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xCA11);
    MockUSDC internal usdc;
    MockWBTC internal wbtc;
    MockCollateralPriceSource internal price;
    LendingPool internal pool;

    /// @notice 가격의 1시간 경계를 고정하고 정상 공급·담보 입금으로 준비한다.
    function setUp() public virtual {
        _prepareBorrowPool(new MockUSDC());
    }

    /// @notice 실패 토큰도 같은 공급·담보 전제를 사용한다.
    function _prepareBorrowPool(MockUSDC token) internal {
        vm.warp(10_000);
        usdc = token;
        wbtc = new MockWBTC();
        price = new MockCollateralPriceSource(100e8, 10_000);
        pool = new LendingPool(usdc, wbtc, price);
        usdc.mint(ALICE, 100e6);
        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100e6);
        pool.supply(100e6);
        vm.stopPrank();
        _depositFor(BOB, 1e8);
    }

    /// @notice 시험 토큰을 발행하고 지정 사용자가 정상 담보 입금을 한다.
    function _depositFor(address user, uint256 amount) internal {
        wbtc.mint(user, amount);
        vm.startPrank(user);
        wbtc.approve(address(pool), amount);
        pool.depositCollateral(amount);
        vm.stopPrank();
    }

    /// @notice 공급자의 권리와 담보·총발행량이 대출 전후 보존되는지 고정값으로 확인한다.
    function _assertInitialRights() internal view {
        assertEq(pool.totalAssets(), 100e6);
        assertEq(pool.totalShares(), 100e6);
        assertEq(pool.shares(ALICE), 100e6);
        assertEq(pool.deposits(ALICE), 100e6);
        assertEq(pool.shares(BOB), 0);
        assertEq(pool.deposits(BOB), 0);
        assertEq(pool.collateralOf(BOB), 1e8);
        assertEq(wbtc.balanceOf(address(pool)), 1e8);
        assertEq(usdc.totalSupply(), 100e6);
    }

    /// @notice 사용자별 두 토큰·승인·지분·환산권리·담보·부채를 관측한다.
    function _participant(address user) internal view returns (uint256[8] memory) {
        return [
            usdc.balanceOf(user),
            wbtc.balanceOf(user),
            usdc.allowance(user, address(pool)),
            wbtc.allowance(user, address(pool)),
            pool.shares(user),
            pool.deposits(user),
            pool.collateralOf(user),
            pool.debtOf(user)
        ];
    }

    /// @notice 유효 장부의 참여자·풀·두 총발행량·사용 가능 현금을 실패 직전과 비교한다.
    function _snapshot() internal view returns (bytes memory) {
        uint256[8] memory global = [
            pool.totalAssets(),
            pool.totalShares(),
            pool.totalDebt(),
            pool.availableLiquidity(),
            usdc.balanceOf(address(pool)),
            wbtc.balanceOf(address(pool)),
            usdc.totalSupply(),
            wbtc.totalSupply()
        ];
        return
            abi.encode(
                global, _participant(ALICE), _participant(BOB), _participant(CHARLIE), _participant(address(usdc))
            );
    }

    /// @notice 실패한 호출의 전체 관측값과 풀 성공 이벤트 부재를 함께 확인한다.
    function _assertUnchanged(bytes memory beforeState) internal view {
        assertEq(_snapshot(), beforeState);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertNotEq(logs[i].emitter, address(pool));
        }
    }

    /// @notice 풀 이벤트의 emitter·호출자·금액·정확히1회를 검증한다.
    function _assertEvent(Vm.Log[] memory logs, string memory signature, address user, uint256 amount) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool)) continue;
            assertEq(logs[i].topics[0], keccak256(bytes(signature)));
            assertEq(logs[i].topics.length, 2);
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(user))));
            assertEq(abi.decode(logs[i].data, (uint256)), amount);
            ++count;
        }
        assertEq(count, 1);
    }
}
