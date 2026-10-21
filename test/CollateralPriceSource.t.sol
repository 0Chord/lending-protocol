// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";
import {CollateralMath} from "../src/libraries/CollateralMath.sol";
import {MockCollateralPriceSource} from "./mocks/MockCollateralPriceSource.sol";
import {RevertingCollateralPriceSource} from "./mocks/RevertingCollateralPriceSource.sol";

/// @title 가격 원천과 담보 계산을 연결하는 시험 전용 호출 경계
/// @notice 원천을 한 번 읽고 갱신시각과 현재 블록시각을 구분해 계산기에 전달한다.
contract CollateralPriceSourceHarness {
    /// @notice 원천의 원시값과 현재시각으로 USDC 6자리의 70% 대출 한도를 계산한다.
    /// @dev 가격 검증과 두 단계 내림은 라이브러리에 맡기며 원천 오류를 그대로 전파한다.
    function maxDebtDown(ICollateralPriceSource source, uint256 collateralWBTC8) external view returns (uint256) {
        (int256 price, uint256 updatedAt) = source.latestPrice();
        return CollateralMath.maxDebtDown(collateralWBTC8, price, updatedAt, block.timestamp);
    }
}

/// @title 가격 원천의 원시값과 계산 연결 검증
/// @notice 원시값 보존·원천 한 번 조회·계산 오류와 원천 오류 전파를 확인한다.
contract CollateralPriceSourceTest is Test {
    /// @notice 100 USDC/WBTC의 8자리 가격과 갱신시각을 주입한 그대로 읽는다.
    function test_InitialRawValuesAreReturnedThroughInterface() public {
        ICollateralPriceSource source = new MockCollateralPriceSource(10_000_000_000, 6_400);

        (int256 price, uint256 updatedAt) = source.latestPrice();

        assertEq(price, 10_000_000_000);
        assertEq(updatedAt, 6_400);
    }

    /// @notice 가격만 150 USDC/WBTC로 바꿔도 기존 갱신시각은 유지한다.
    function test_SetPricePreservesTimestamp() public {
        MockCollateralPriceSource mockSource = new MockCollateralPriceSource(10_000_000_000, 6_400);
        ICollateralPriceSource source = mockSource;

        mockSource.setPrice(15_000_000_000);
        (int256 price, uint256 updatedAt) = source.latestPrice();

        assertEq(price, 15_000_000_000);
        assertEq(updatedAt, 6_400);
    }

    /// @notice 가격 변경 뒤 시각만 0으로 바꿔도 가격은 그대로 남는다.
    function test_SetUpdatedAtPreservesPrice() public {
        MockCollateralPriceSource mockSource = new MockCollateralPriceSource(10_000_000_000, 6_400);
        ICollateralPriceSource source = mockSource;
        mockSource.setPrice(15_000_000_000);

        mockSource.setUpdatedAt(0);
        (int256 price, uint256 updatedAt) = source.latestPrice();

        assertEq(price, 15_000_000_000);
        assertEq(updatedAt, 0);
    }

    /// @notice 생성자는 0·음수 가격과 0·과거·미래 시각을 그대로 보존한다.
    function test_ConstructorPreservesInvalidRawInputs() public {
        vm.warp(10_000);
        int256[4] memory prices = [int256(0), -1, type(int256).min, 15_000_000_000];
        uint256[4] memory timestamps = [uint256(0), 6_400, 10_001, 10_001];

        for (uint256 i; i < prices.length; ++i) {
            ICollateralPriceSource source = new MockCollateralPriceSource(prices[i], timestamps[i]);

            (int256 price, uint256 updatedAt) = source.latestPrice();

            assertEq(price, prices[i]);
            assertEq(updatedAt, timestamps[i]);
        }
    }

    /// @notice 설정 함수도 원시값을 제한하거나 갱신시각을 자동으로 찍지 않는다.
    function test_SettersPreserveInvalidRawInputs() public {
        vm.warp(10_000);
        MockCollateralPriceSource mockSource = new MockCollateralPriceSource(10_000_000_000, 6_400);
        ICollateralPriceSource source = mockSource;
        int256[4] memory prices = [int256(0), -1, type(int256).min, 15_000_000_000];
        uint256[4] memory timestamps = [uint256(0), 6_400, 10_001, 10_001];

        for (uint256 i; i < prices.length; ++i) {
            mockSource.setPrice(prices[i]);
            mockSource.setUpdatedAt(timestamps[i]);

            (int256 price, uint256 updatedAt) = source.latestPrice();

            assertEq(price, prices[i]);
            assertEq(updatedAt, timestamps[i]);
        }
    }

    /// @notice 서로 다른 가격 원천을 각각 한 번 읽어 1 WBTC의 한도 70·105 USDC를 구분한다.
    function test_WrapperReadsSourceOnceToCalculateMaxDebt() public {
        vm.warp(10_000);
        ICollateralPriceSource source = new MockCollateralPriceSource(10_000_000_000, 6_400);
        ICollateralPriceSource otherSource = new MockCollateralPriceSource(15_000_000_000, 10_000);
        CollateralPriceSourceHarness harness = new CollateralPriceSourceHarness();

        vm.expectCall(address(source), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), uint64(1));
        vm.expectCall(address(otherSource), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), uint64(1));
        uint256 limit = harness.maxDebtDown(source, 100_000_000);
        uint256 otherLimit = harness.maxDebtDown(otherSource, 100_000_000);

        assertEq(limit, 70_000_000);
        assertEq(otherLimit, 105_000_000);
    }

    /// @notice 원천의 3601초 전 시각을 덮어쓰지 않고 거절하며 원시값도 유지한다.
    function test_WrapperRejectsStalePriceWithoutChangingRawValues() public {
        vm.warp(10_000);
        ICollateralPriceSource source = new MockCollateralPriceSource(10_000_000_000, 6_399);
        CollateralPriceSourceHarness harness = new CollateralPriceSourceHarness();
        (int256 beforePrice, uint256 beforeUpdatedAt) = source.latestPrice();
        assertEq(beforePrice, 10_000_000_000);
        assertEq(beforeUpdatedAt, 6_399);

        vm.expectRevert(abi.encodeWithSelector(CollateralMath.StalePrice.selector, uint256(6_399), uint256(10_000)));
        harness.maxDebtDown(source, 100_000_000);

        (int256 afterPrice, uint256 afterUpdatedAt) = source.latestPrice();
        assertEq(afterPrice, beforePrice);
        assertEq(afterUpdatedAt, beforeUpdatedAt);
    }

    /// @notice 원천이 실제 조회에서 실패하면 정확한 장애 오류를 삼키지 않고 전파한다.
    function test_WrapperPropagatesPriceSourceFailure() public {
        vm.warp(10_000);
        ICollateralPriceSource source = new RevertingCollateralPriceSource();
        CollateralPriceSourceHarness harness = new CollateralPriceSourceHarness();

        vm.expectCall(address(source), abi.encodeCall(ICollateralPriceSource.latestPrice, ()), uint64(1));
        vm.expectRevert(abi.encodeWithSelector(RevertingCollateralPriceSource.PriceSourceUnavailable.selector));
        harness.maxDebtDown(source, 100_000_000);
    }
}
