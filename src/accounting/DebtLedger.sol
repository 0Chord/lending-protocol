// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {InterestMath} from "../libraries/InterestMath.sol";

/// @title 토큰 이동 없이 원금과 단리 이자를 기록하는 내부 장부
/// @notice 개인과 전체 부채를 같은 시각으로 계산하며 전체 차입자를 순회하지 않는다.
library DebtLedger {
    /// @notice 원금은 USDC 최소 단위, 미납 이자는 InterestMath 분자 단위다.
    struct Position {
        uint256 principal;
        uint256 interestNumerator;
        uint256 updatedAt;
    }

    /// @notice 개인 기록과 전체 기록은 마지막 계산 시각이 서로 다를 수 있다.
    struct State {
        mapping(address => Position) borrowers;
        Position total;
    }

    /// @notice 지정 시각의 계산 결과이며 조회만으로 저장되지 않는다.
    struct Snapshot {
        uint256 principal;
        uint256 interestNumerator;
        uint256 debtNumerator;
        uint256 updatedAt;
    }

    /// @notice 이미 계산한 시각보다 과거로 장부를 돌릴 수 없다.
    error PastTimestamp(uint256 lastTimestamp, uint256 requestedTimestamp);

    /// @notice 개인의 저장값을 바꾸지 않고 지정 시각의 정확 부채를 계산한다.
    function borrowerSnapshot(State storage self, address borrower, uint256 timestamp)
        internal
        view
        returns (Snapshot memory)
    {
        return _preview(self.borrowers[borrower], timestamp);
    }

    /// @notice 전체 원금만으로 현재 부채를 계산하며 개인을 순회하지 않는다.
    function totalSnapshot(State storage self, uint256 timestamp) internal view returns (Snapshot memory) {
        return _preview(self.total, timestamp);
    }

    /// @notice 공급·출금처럼 대상 차입자가 없어도 전체 이자를 한 번 기록한다.
    /// @return accruedInterestNumerator 이번 기준 시각 사이에 새로 발생한 전체 이자
    function accrueTotal(State storage self, uint256 timestamp) internal returns (uint256 accruedInterestNumerator) {
        return _checkpoint(self.total, timestamp);
    }

    /// @notice 전체와 개인을 같은 시각에 맞추되 개인의 늦은 이자를 전체에 다시 더하지 않는다.
    function accrueBorrower(State storage self, address borrower, uint256 timestamp)
        internal
        returns (uint256 accruedInterestNumerator)
    {
        accruedInterestNumerator = accrueTotal(self, timestamp);
        _checkpoint(self.borrowers[borrower], timestamp);
    }

    /// @notice 기존 원금의 이자를 먼저 기록한 뒤 새 차입 원금을 더한다.
    /// @dev 호출자는 일관된 시각을 전달한다. 금액0과 표현 범위 초과는 전체 호출을 되돌린다.
    function recordBorrow(State storage self, address borrower, uint256 amount, uint256 timestamp)
        internal
        returns (uint256 accruedInterestNumerator)
    {
        if (amount == 0) revert InterestMath.ZeroAmount();
        accruedInterestNumerator = accrueBorrower(self, borrower, timestamp);
        self.borrowers[borrower].principal += amount;
        self.total.principal += amount;
        // 개인 합보다 작지 않은 전체 정확 채권까지 표현 가능한지 확인한다.
        _preview(self.total, timestamp);
    }

    /// @notice 현재 이자를 기록한 뒤 상환액을 이자·원금 순서로 차감한다.
    /// @return accruedInterestNumerator 전역 기준 이후 새 발생 이자이며 정산 올림 차이는 포함하지 않는다.
    /// @return repayment 실제 배분과 남은 개인 부채, 별도로 자산에 더할 정산 올림 차이
    function recordRepayment(State storage self, address borrower, uint256 amount, uint256 timestamp)
        internal
        returns (uint256 accruedInterestNumerator, InterestMath.Repayment memory repayment)
    {
        accruedInterestNumerator = accrueBorrower(self, borrower, timestamp);
        Position storage personal = self.borrowers[borrower];
        repayment = InterestMath.allocateRepayment(personal.principal, personal.interestNumerator, amount);

        // 올려 받은 금액이 아니라 실제 없앤 미납 분자만 전체 부채에서 뺀다.
        self.total.interestNumerator -= personal.interestNumerator - repayment.remainingInterestNumerator;
        self.total.principal -= repayment.principalPaid;
        personal.principal = repayment.remainingPrincipal;
        personal.interestNumerator = repayment.remainingInterestNumerator;
    }

    /// @notice 같은 시각에 완제할 원금과 올림 미납 이자의 합을 조회한다.
    function quoteRepayment(State storage self, address borrower, uint256 timestamp) internal view returns (uint256) {
        Snapshot memory current = borrowerSnapshot(self, borrower, timestamp);
        return InterestMath.quoteDebt(current.principal, current.interestNumerator);
    }

    /// @notice 개인별 올림 견적을 합하지 않고 전체 정확 채권을 한 번 내려 표시한다.
    function totalDebtRaw(State storage self, uint256 timestamp) internal view returns (uint256) {
        return InterestMath.toRawDown(totalSnapshot(self, timestamp).debtNumerator);
    }

    /// @notice 시각0도 정상 기록으로 계산하고 필요한 곱·합 초과를 그대로 거절한다.
    function _preview(Position storage position, uint256 timestamp) private view returns (Snapshot memory result) {
        if (timestamp < position.updatedAt) revert PastTimestamp(position.updatedAt, timestamp);
        result.principal = position.principal;
        result.interestNumerator =
            InterestMath.accrue(position.principal, position.interestNumerator, timestamp - position.updatedAt);
        result.debtNumerator = InterestMath.toNumerator(result.principal) + result.interestNumerator;
        result.updatedAt = timestamp;
    }

    /// @notice 조회와 같은 계산을 저장하며, 새 발생분만 반환한다.
    function _checkpoint(Position storage position, uint256 timestamp) private returns (uint256 accrued) {
        Snapshot memory current = _preview(position, timestamp);
        accrued = current.interestNumerator - position.interestNumerator;
        position.interestNumerator = current.interestNumerator;
        position.updatedAt = timestamp;
    }
}
