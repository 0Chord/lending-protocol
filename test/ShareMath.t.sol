// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {ShareMath} from "../src/libraries/ShareMath.sol";

/// @title 환산 오류를 관측하는 시험 전용 호출 경계
/// @notice 계산을 복제하지 않고 internal 라이브러리를 외부 호출로 실행한다.
contract ShareMathHarness {
    /// @notice 공급 지분 내림 계산을 그대로 전달한다.
    function toSharesDown(uint256 assets, uint256 accountedAssets, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return ShareMath.toSharesDown(assets, accountedAssets, totalShares);
    }

    /// @notice 출금 지분 올림 계산을 그대로 전달한다.
    function toSharesUp(uint256 assets, uint256 accountedAssets, uint256 totalShares) external pure returns (uint256) {
        return ShareMath.toSharesUp(assets, accountedAssets, totalShares);
    }

    /// @notice 지분의 USDC 가치 내림 계산을 그대로 전달한다.
    function toAssetsDown(uint256 shares, uint256 accountedAssets, uint256 totalShares)
        external
        pure
        returns (uint256)
    {
        return ShareMath.toAssetsDown(shares, accountedAssets, totalShares);
    }
}

/// @title USDC·지분 환산 검증
/// @notice 인정자산과 총지분으로 계산한 최소 단위의 반올림을 확인한다.
contract ShareMathTest is Test {
    ShareMathHarness private harness;

    /// @notice 매 테스트에서 오류를 관측할 별도 호출 경계를 준비한다.
    function setUp() public {
        harness = new ShareMathHarness();
    }

    /// @notice 같은 금액도 공급 지분은 내리고 출금 차감 지분은 올린다.
    function test_ShareConversionsRoundInOppositeDirections() public pure {
        assertEq(ShareMath.toSharesDown(1_000_001, 10_000_000, 6_000_000), 600_000);
        assertEq(ShareMath.toSharesUp(1_000_001, 10_000_000, 6_000_000), 600_001);
    }

    /// @notice 정확한 지분 가치는 유지하고 나머지가 있는 USDC 환산은 내린다.
    function test_AssetConversionRoundsDown() public pure {
        assertEq(ShareMath.toAssetsDown(2_400_000, 10_000_000, 6_000_000), 4_000_000);
        assertEq(ShareMath.toAssetsDown(1, 10, 6), 1);
    }

    /// @notice 빈 장부의 초기 비율은 0부터 uint256 최댓값까지 수학적 1:1이다.
    function test_EmptyAccountingUsesOneToOneForAllInputs() public pure {
        uint256[4] memory inputs = [uint256(0), 1, 100_000_000, type(uint256).max];
        for (uint256 i; i < inputs.length; ++i) {
            uint256 input = inputs[i];
            assertEq(ShareMath.toSharesDown(input, 0, 0), input);
            assertEq(ShareMath.toSharesUp(input, 0, 0), input);
            assertEq(ShareMath.toAssetsDown(input, 0, 0), input);
        }
    }

    /// @notice 두 장부 값이 양수일 때 입력 0은 세 방향 모두 0이다.
    function test_ZeroInputWithValidAccountingReturnsZero() public pure {
        assertEq(ShareMath.toSharesDown(0, 10, 6), 0);
        assertEq(ShareMath.toSharesUp(0, 10, 6), 0);
        assertEq(ShareMath.toAssetsDown(0, 10, 6), 0);
    }

    /// @notice 자산만 0인 장부는 입력 0과 1 모두 정확한 오류 인수를 반환한다.
    function test_MissingAssetsRevertsEvenForZeroInput() public {
        _assertInvalidAccountingState(0, 1);
    }

    /// @notice 총지분만 0인 장부도 입력에 앞서 같은 상태 오류로 거절한다.
    function test_MissingSharesRevertsEvenForZeroInput() public {
        _assertInvalidAccountingState(1, 0);
    }

    /// @notice 나누어떨어지는 1:1과 비1:1에서는 공급·출금 환산이 같은 정확한 값이다.
    function test_ExactShareConversionsPreserveFractionalShares() public pure {
        assertEq(ShareMath.toSharesDown(40_000_000, 100_000_000, 100_000_000), 40_000_000);
        assertEq(ShareMath.toSharesUp(40_000_000, 100_000_000, 100_000_000), 40_000_000);
        assertEq(ShareMath.toSharesDown(4_000_000, 10_000_000, 6_000_000), 2_400_000);
        assertEq(ShareMath.toSharesUp(4_000_000, 10_000_000, 6_000_000), 2_400_000);
    }

    /// @notice 자산 최소 단위 1의 환산은 지분 내림0·올림1을 그대로 반환한다.
    function test_SmallestAssetMayConvertToZeroShares() public pure {
        assertEq(ShareMath.toSharesDown(1, 10, 6), 0);
        assertEq(ShareMath.toSharesUp(1, 10, 6), 1);
    }

    /// @notice 마지막 총지분을 차감하는 계산도 성공하며 실제 출금 허용은 판단하지 않는다.
    function test_LastTotalSharesIsACalculationResult() public pure {
        assertEq(ShareMath.toSharesUp(9_999_999, 10_000_000, 6_000_000), 6_000_000);
    }

    /// @notice 중간 곱이 uint256을 넘어도 최종 정수 결과가 최댓값이면 성공한다.
    function test_IntermediateProductCanOverflowWhenResultFits() public pure {
        uint256 max = type(uint256).max;
        assertEq(ShareMath.toSharesDown(max, 2, 2), max);
        assertEq(ShareMath.toSharesUp(max, 2, 2), max);
        assertEq(ShareMath.toAssetsDown(max, 2, 2), max);
    }

    /// @notice 내림 결과가 최댓값이어도 올림하면 범위를 넘는 인접 경계를 구분한다.
    function test_FloorCanReturnMaxBeforeCeilOverflows() public {
        uint256 max = type(uint256).max;
        assertEq(ShareMath.toSharesDown(max - 1, max - 2, max - 1), max);

        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.toSharesUp(max - 1, max - 2, max - 1);
    }

    /// @notice 지분 환산의 내림 결과부터 범위를 넘으면 두 방향 모두 정확한 산술 오류다.
    function test_ShareConversionsRejectOverflowingResults() public {
        uint256 max = type(uint256).max;
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.toSharesDown(max, max - 1, max);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.toSharesUp(max, max - 1, max);
    }

    /// @notice USDC 역환산의 최종 결과가 범위를 넘어도 같은 산술 오류를 전파한다.
    function test_AssetConversionRejectsOverflowingResult() public {
        uint256 max = type(uint256).max;
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        harness.toAssetsDown(max, max, max - 1);
    }

    /// @notice 세 계산이 입력 0·1에서 같은 오류 종류와 장부 값을 전달하는지 확인한다.
    function _assertInvalidAccountingState(uint256 accountedAssets, uint256 totalShares) private {
        bytes memory expected =
            abi.encodeWithSignature("InvalidAccountingState(uint256,uint256)", accountedAssets, totalShares);
        for (uint256 input; input < 2; ++input) {
            vm.expectRevert(expected);
            harness.toSharesDown(input, accountedAssets, totalShares);
            vm.expectRevert(expected);
            harness.toSharesUp(input, accountedAssets, totalShares);
            vm.expectRevert(expected);
            harness.toAssetsDown(input, accountedAssets, totalShares);
        }
    }
}
