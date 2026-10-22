// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title 연10% 단리 이자의 정확한 누적과 정산
/// @notice 토큰·저장 상태를 바꾸지 않고 USDC 최소 단위보다 작은 이자를 보존한다.
library InterestMath {
    /// @notice 상환 뒤 부채와 실제 받은 금액의 배분을 후속 장부에 전달한다.
    /// @dev 원금·지급액은 USDC 최소 단위이며, 두 Numerator 필드는 DENOMINATOR 배율의 분자다.
    struct Repayment {
        uint256 remainingPrincipal;
        uint256 remainingInterestNumerator;
        uint256 interestPaid;
        uint256 principalPaid;
        uint256 roundingSurplusNumerator;
    }

    /// @notice 금액0을 유효한 상환으로 취급하지 않는다.
    error ZeroAmount();

    /// @notice 완제 견적보다 큰 요청은 일부 배분 없이 거절한다.
    error RepayExceedsDebt(uint256 debt, uint256 requested);

    /// @notice 이자 분자를 나누면 USDC 최소 단위 금액이 되는 고정 분모다.
    /// @dev 원금 × 경과초 / (365일 × 10)으로 연10% 단리를 계산한다.
    uint256 internal constant DENOMINATOR = 315_360_000;

    /// @notice USDC 최소 단위 금액을 정확한 분자 단위로 올려 표현한다.
    /// @dev 변환 결과가 uint256을 넘으면 Panic(0x11)이며 끝자리를 버리지 않는다.
    function toNumerator(uint256 amount) internal pure returns (uint256) {
        return amount * DENOMINATOR;
    }

    /// @notice 정확한 분자를 USDC 최소 단위에서 내려 표시한다.
    function toRawDown(uint256 numerator) internal pure returns (uint256) {
        return numerator / DENOMINATOR;
    }

    /// @notice 정확한 분자를 실제 정산 가능한 USDC 최소 단위까지 올린다.
    /// @dev 분자에 분모를 미리 더하지 않아 최댓값 분자도 변환할 수 있다.
    function toRawUp(uint256 numerator) internal pure returns (uint256) {
        uint256 whole = toRawDown(numerator);
        return numerator % DENOMINATOR == 0 ? whole : whole + 1;
    }

    /// @notice 원금과 올림 미납 이자를 합쳐 완제에 필요한 최소 단위 금액을 계산한다.
    /// @dev 견적만 반환하며 정산 수익·부채를 기록하지 않는다. 합 초과는 Panic(0x11)이다.
    function quoteDebt(uint256 principal, uint256 interestNumerator) internal pure returns (uint256) {
        return principal + toRawUp(interestNumerator);
    }

    /// @notice 상환액을 미납 이자부터 배분하고 남는 금액만 원금에서 차감한다.
    /// @dev 이자를 모두 정산할 때만 올림 차이를 반환하며 실제 수익 기록은 하지 않는다.
    /// @param principal USDC 최소 단위의 남은 원금
    /// @param interestNumerator 기존 미납 이자의 정확한 분자
    /// @param amount 이번에 받을 USDC 최소 단위 금액
    /// @return result 남은 원금·미납 분자·이자/원금 지급액·올림 추가분 분자
    function allocateRepayment(uint256 principal, uint256 interestNumerator, uint256 amount)
        internal
        pure
        returns (Repayment memory result)
    {
        if (amount == 0) revert ZeroAmount();
        uint256 debt = quoteDebt(principal, interestNumerator);
        if (amount > debt) revert RepayExceedsDebt(debt, amount);

        uint256 interestDue = toRawUp(interestNumerator);
        if (amount < interestDue) {
            result.remainingPrincipal = principal;
            result.remainingInterestNumerator = interestNumerator - toNumerator(amount);
            result.interestPaid = amount;
            return result;
        }

        result.interestPaid = interestDue;
        result.principalPaid = amount - interestDue;
        result.remainingPrincipal = principal - result.principalPaid;
        uint256 remainder = interestNumerator % DENOMINATOR;
        if (remainder != 0) result.roundingSurplusNumerator = DENOMINATOR - remainder;
    }

    /// @notice 남은 원금에 대한 기간 이자를 기존 미납 이자 분자에 더한다.
    /// @dev 미납 이자는 원금에 합치지 않으며 곱·합의 범위 초과는 Panic(0x11)이다.
    /// @param principal USDC 최소 단위의 남은 원금
    /// @param interestNumerator 기존 미납 이자의 정확한 분자
    /// @param elapsedSeconds 원금이 유지된 기간의 초 수
    /// @return 누적된 이자의 정확한 분자
    function accrue(uint256 principal, uint256 interestNumerator, uint256 elapsedSeconds)
        internal
        pure
        returns (uint256)
    {
        return interestNumerator + principal * elapsedSeconds;
    }
}
