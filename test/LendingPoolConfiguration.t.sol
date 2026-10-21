// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {ICollateralPriceSource} from "../src/interfaces/ICollateralPriceSource.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";
import {MockWBTC} from "../src/mocks/MockWBTC.sol";
import {MockCollateralPriceSource} from "./mocks/MockCollateralPriceSource.sol";
import {RevertingCollateralPriceSource} from "./mocks/RevertingCollateralPriceSource.sol";
import {
    EighteenDecimalToken,
    EighteenDecimalPriceSource,
    MissingDecimalsMetadata,
    RevertingDecimalsMetadata,
    ShortDecimalsMetadata,
    OutOfRangeDecimalsMetadata
} from "./mocks/MetadataMocks.sol";

/// @title 실제 연결한 자산과 가격의 정밀도 검사
/// @notice 잘못된 연결의 정확한 오류와 외부 상태 보존을 정상 재배포와 대조한다.
contract LendingPoolConfigurationTest is Test {
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant SPENDER = address(0x5151);
    MockUSDC private usdc;
    MockWBTC private wbtc;
    MockCollateralPriceSource private price;
    IERC20[] private observedTokens;
    ICollateralPriceSource[] private observedPrices;

    /// @notice 정상 자산의 기존 잔고·유한 승인과 고정 시각의 원시 가격을 준비한다.
    function setUp() public {
        vm.warp(10_000);
        usdc = new MockUSDC();
        wbtc = new MockWBTC();
        price = new MockCollateralPriceSource(100e8, 10_000);
        usdc.mint(ALICE, 200_000_000);
        usdc.mint(BOB, 7_000_000);
        wbtc.mint(ALICE, 25_000_000);
        wbtc.mint(BOB, 200_000_000);
        _prepareApprovals(usdc);
        _prepareApprovals(wbtc);
        observedTokens.push(usdc);
        observedTokens.push(wbtc);
        observedPrices.push(price);
    }

    /// @notice USDC6·WBTC8·가격8 연결은 기존 상태와 이벤트를 건드리지 않고 실제 주소를 고정한다.
    function test_DeploysWithSixEightEightDecimals() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        uint256[7][] memory beforeTokens = _tokenStates(predicted);
        vm.recordLogs();
        LendingPool pool = new LendingPool(usdc, wbtc, price);
        _assertConfiguration(pool, price);
        assertEq(address(pool), predicted);
        _assertTokensUnchanged(predicted, beforeTokens);
        assertEq(vm.getRecordedLogs().length, 0);
        (int256 rawPrice, uint256 updatedAt) = price.latestPrice();
        assertEq(rawPrice, 100e8);
        assertEq(updatedAt, 10_000);
    }

    /// @notice 대출 자산18은 실제 입력 주소와 기대6·실제18을 담은 오류로 거절한다.
    function test_RejectsEighteenDecimalAsset() public {
        EighteenDecimalToken wrong = _newEighteenDecimalToken();
        _assertRejected(
            wrong,
            wbtc,
            price,
            abi.encodeWithSelector(LendingPool.UnsupportedDecimals.selector, address(wrong), uint8(6), uint8(18))
        );
    }

    /// @notice 담보18을 WBTC8로 읽기 전에 정확한 정밀도 오류로 배포를 거절한다.
    function test_RejectsEighteenDecimalCollateral() public {
        EighteenDecimalToken wrong = _newEighteenDecimalToken();
        _assertRejected(
            usdc,
            wrong,
            price,
            abi.encodeWithSelector(LendingPool.UnsupportedDecimals.selector, address(wrong), uint8(8), uint8(18))
        );
    }

    /// @notice 가격18의 정상 raw 값이 있어도 기대8과 다른 연결은 거절한다.
    function test_RejectsEighteenDecimalPriceSource() public {
        EighteenDecimalPriceSource wrong = new EighteenDecimalPriceSource(100e18, 10_000);
        observedPrices.push(wrong);
        _assertRejected(
            usdc,
            wbtc,
            wrong,
            abi.encodeWithSelector(LendingPool.UnsupportedDecimals.selector, address(wrong), uint8(8), uint8(18))
        );
    }

    /// @notice 정상 두 토큰을 바꾸어 연결하면 첫 대출 자산의 기대6·실제8 오류를 먼저 낸다.
    function test_RejectsSwappedTokensAtAssetPrecisionCheck() public {
        _assertRejected(
            wbtc,
            usdc,
            price,
            abi.encodeWithSelector(LendingPool.UnsupportedDecimals.selector, address(wbtc), uint8(6), uint8(8))
        );
    }

    /// @notice 0 가격 주소는 metadata 호출 전에 주소 오류로 거절한다.
    function test_RejectsZeroPriceSource() public {
        _assertRejected(
            usdc,
            wbtc,
            ICollateralPriceSource(address(0)),
            abi.encodeWithSelector(LendingPool.InvalidPriceSource.selector, address(0))
        );
    }

    /// @notice 코드 없는 가격 주소를 정상 metadata 원천으로 간주하지 않는다.
    function test_RejectsPriceSourceWithoutCode() public {
        assertEq(BOB.code.length, 0);
        _assertRejected(
            usdc,
            wbtc,
            ICollateralPriceSource(BOB),
            abi.encodeWithSelector(LendingPool.InvalidPriceSource.selector, BOB)
        );
    }

    /// @notice decimals 함수 없는 대역의 성공·빈 응답을 세 역할 모두에서 거절한다.
    function test_RejectsMissingDecimalsInEveryRole() public {
        MissingDecimalsMetadata wrong = new MissingDecimalsMetadata();
        (bool success, bytes memory response) = address(wrong).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(success);
        assertEq(response.length, 0);
        bytes memory expected = abi.encodeWithSelector(LendingPool.InvalidDecimalsMetadata.selector, address(wrong));
        _assertRejected(IERC20(address(wrong)), wbtc, price, expected);
        _assertRejected(usdc, IERC20(address(wrong)), price, expected);
        _assertRejected(usdc, wbtc, ICollateralPriceSource(address(wrong)), expected);
    }

    /// @notice 원천의 decimals 호출 오류를 정상값으로 대체하지 않고 metadata 오류로 구분한다.
    function test_RejectsRevertingDecimals() public {
        RevertingDecimalsMetadata wrong = new RevertingDecimalsMetadata();
        vm.expectRevert(RevertingDecimalsMetadata.MetadataUnavailable.selector);
        wrong.decimals();
        _assertRejected(
            usdc,
            wbtc,
            ICollateralPriceSource(address(wrong)),
            abi.encodeWithSelector(LendingPool.InvalidDecimalsMetadata.selector, address(wrong))
        );
    }

    /// @notice 값8을 담아도 31바이트로 깨진 ABI 응답은 배포를 거절한다.
    function test_RejectsShortDecimalsResponse() public {
        ShortDecimalsMetadata wrong = new ShortDecimalsMetadata();
        (bool success, bytes memory response) = address(wrong).staticcall(abi.encodeWithSignature("decimals()"));
        assertTrue(success);
        assertEq(response.length, 31);
        _assertRejected(
            usdc,
            wbtc,
            ICollateralPriceSource(address(wrong)),
            abi.encodeWithSelector(LendingPool.InvalidDecimalsMetadata.selector, address(wrong))
        );
    }

    /// @notice 길이가32인 raw256도 uint8 범위 밖이므로 잘라서 허용하지 않는다.
    function test_RejectsDecimalsOutsideUint8Range() public {
        OutOfRangeDecimalsMetadata wrong = new OutOfRangeDecimalsMetadata();
        assertEq(wrong.decimals(), 256);
        _assertRejected(
            usdc,
            wbtc,
            ICollateralPriceSource(address(wrong)),
            abi.encodeWithSelector(LendingPool.InvalidDecimalsMetadata.selector, address(wrong))
        );
    }

    /// @notice 가격0·오래된 시각이어도 metadata8이면 배포에서 가격 유효성을 검사하지 않는다.
    function test_DeploymentDoesNotValidateRawPriceOrTimestamp() public {
        price.setPrice(0);
        price.setUpdatedAt(1);
        vm.recordLogs();
        LendingPool pool = new LendingPool(usdc, wbtc, price);
        _assertConfiguration(pool, price);
        assertEq(vm.getRecordedLogs().length, 0);
        (int256 rawPrice, uint256 updatedAt) = price.latestPrice();
        assertEq(rawPrice, 0);
        assertEq(updatedAt, 1);
    }

    /// @notice latestPrice가 항상 실패해도 배포·공급·담보 입금·부채 없는 반환은 정상 동작한다.
    function test_RevertingLatestPriceAllowsDeploymentAndIndependentActions() public {
        RevertingCollateralPriceSource unavailable = new RevertingCollateralPriceSource();
        assertEq(unavailable.decimals(), 8);
        vm.expectRevert(RevertingCollateralPriceSource.PriceSourceUnavailable.selector);
        unavailable.latestPrice();
        vm.recordLogs();
        LendingPool pool = new LendingPool(usdc, wbtc, unavailable);
        _assertConfiguration(pool, unavailable);
        assertEq(vm.getRecordedLogs().length, 0);

        vm.startPrank(ALICE);
        usdc.approve(address(pool), 100_000_000);
        pool.supply(100_000_000);
        vm.stopPrank();
        assertEq(usdc.balanceOf(ALICE), 100_000_000);
        assertEq(usdc.balanceOf(address(pool)), 100_000_000);
        assertEq(usdc.allowance(ALICE, address(pool)), 0);
        assertEq(pool.totalAssets(), 100_000_000);
        assertEq(pool.totalShares(), 100_000_000);
        assertEq(pool.shares(ALICE), 100_000_000);
        assertEq(pool.deposits(ALICE), 100_000_000);

        vm.startPrank(BOB);
        wbtc.approve(address(pool), 100_000_000);
        pool.depositCollateral(100_000_000);
        vm.stopPrank();
        assertEq(wbtc.balanceOf(BOB), 100_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 100_000_000);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(pool.collateralOf(BOB), 100_000_000);

        vm.prank(BOB);
        pool.withdrawCollateral(40_000_000);
        assertEq(pool.collateralOf(BOB), 60_000_000);
        assertEq(wbtc.balanceOf(BOB), 140_000_000);
        vm.prank(BOB);
        pool.withdrawCollateral(60_000_000);
        assertEq(pool.collateralOf(BOB), 0);
        assertEq(wbtc.balanceOf(BOB), 200_000_000);
        assertEq(wbtc.balanceOf(address(pool)), 0);
        assertEq(wbtc.allowance(BOB, address(pool)), 0);
        assertEq(wbtc.totalSupply(), 225_000_000);
        assertEq(usdc.totalSupply(), 207_000_000);
        assertEq(usdc.balanceOf(address(pool)), 100_000_000);
        assertEq(pool.totalAssets(), 100_000_000);
        assertEq(pool.totalShares(), 100_000_000);
        assertEq(pool.shares(ALICE), 100_000_000);
    }

    /// @notice 잘못된 토큰에도 기존 잔고·승인을 만들어 배포 실패의 보존 대상에 포함한다.
    function _newEighteenDecimalToken() private returns (EighteenDecimalToken token) {
        token = new EighteenDecimalToken();
        token.mint(ALICE, 3e18);
        token.mint(BOB, 5e18);
        _prepareApprovals(token);
        observedTokens.push(token);
    }

    /// @notice 별도 거래로 설정한 유한 승인은 배포 실패가 취소하거나 소비할 수 없다.
    function _prepareApprovals(IERC20 token) private {
        vm.prank(ALICE);
        token.approve(SPENDER, 11);
        vm.prank(BOB);
        token.approve(SPENDER, 13);
    }

    /// @notice 실패 주소·오류·외부 상태·이벤트 부재를 검사한 뒤 정상 연결 재배포를 대조한다.
    function _assertRejected(IERC20 asset_, IERC20 collateral_, ICollateralPriceSource price_, bytes memory expected)
        private
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        uint256[7][] memory beforeTokens = _tokenStates(predicted);
        int256[] memory beforePrices = new int256[](observedPrices.length);
        uint256[] memory beforeTimes = new uint256[](observedPrices.length);
        for (uint256 i; i < observedPrices.length; ++i) {
            (beforePrices[i], beforeTimes[i]) = observedPrices[i].latestPrice();
        }
        vm.recordLogs();
        vm.expectRevert(expected);
        new LendingPool(asset_, collateral_, price_);
        assertEq(predicted.code.length, 0);
        _assertTokensUnchanged(predicted, beforeTokens);
        // 생성 중 Transfer·Approval·프로토콜 성공 이벤트가 모두 없어야 한다.
        assertEq(vm.getRecordedLogs().length, 0);
        for (uint256 i; i < observedPrices.length; ++i) {
            (int256 rawPrice, uint256 updatedAt) = observedPrices[i].latestPrice();
            assertEq(rawPrice, beforePrices[i]);
            assertEq(updatedAt, beforeTimes[i]);
        }
        vm.recordLogs();
        LendingPool retry = new LendingPool(usdc, wbtc, price);
        _assertConfiguration(retry, price);
        assertEq(vm.getRecordedLogs().length, 0);
        _assertTokensUnchanged(predicted, beforeTokens);
    }

    /// @notice 양 사용자와 예정 풀의 잔고·기존 승인·발행량을 각 실제 토큰에서 읽는다.
    function _tokenStates(address predicted) private view returns (uint256[7][] memory states) {
        states = new uint256[7][](observedTokens.length);
        for (uint256 i; i < observedTokens.length; ++i) {
            IERC20 token = observedTokens[i];
            states[i] = [
                token.balanceOf(ALICE),
                token.balanceOf(BOB),
                token.balanceOf(predicted),
                token.allowance(ALICE, SPENDER),
                token.allowance(BOB, SPENDER),
                token.allowance(ALICE, predicted),
                token.totalSupply()
            ];
        }
    }

    /// @notice 배포 실패 직전 관측한 각 실제 토큰의 모든 값을 비교한다.
    function _assertTokensUnchanged(address predicted, uint256[7][] memory beforeTokens) private view {
        uint256[7][] memory afterTokens = _tokenStates(predicted);
        for (uint256 i; i < beforeTokens.length; ++i) {
            for (uint256 j; j < beforeTokens[i].length; ++j) {
                assertEq(afterTokens[i][j], beforeTokens[i][j]);
            }
        }
    }

    /// @notice 정상 배포가 실제 입력 주소를 고정하고 빈 장부에서 시작하는지 확인한다.
    function _assertConfiguration(LendingPool pool, ICollateralPriceSource expectedPrice) private view {
        assertEq(address(pool.asset()), address(usdc));
        assertEq(address(pool.collateralAsset()), address(wbtc));
        assertEq(address(pool.priceSource()), address(expectedPrice));
        assertEq(pool.totalAssets(), 0);
        assertEq(pool.totalShares(), 0);
        assertEq(pool.collateralOf(ALICE), 0);
        assertEq(pool.collateralOf(BOB), 0);
    }
}
