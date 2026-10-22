// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {DebtLedger} from "../../src/accounting/DebtLedger.sol";
import {InterestMath} from "../../src/libraries/InterestMath.sol";

/// @title 내부 장부의 정상 기록과 오류 복구를 관측하는 시험용 호출 경계
/// @notice 토큰을 다루지 않으며 운영 풀에 노출할 API가 아니다.
contract DebtLedgerHarness {
    using DebtLedger for DebtLedger.State;

    DebtLedger.State private ledger;

    /// @notice 차입 기록을 외부 경계로 전달한다.
    function borrow(address borrower, uint256 amount, uint256 timestamp) external returns (uint256) {
        return ledger.recordBorrow(borrower, amount, timestamp);
    }

    /// @notice 정확액 상환의 신규 이자와 배분·올림 차이를 관측한다.
    function repay(address borrower, uint256 amount, uint256 timestamp)
        external
        returns (uint256, InterestMath.Repayment memory)
    {
        return ledger.recordRepayment(borrower, amount, timestamp);
    }

    /// @notice 개인과 전체를 같은 시각에 기록한다.
    function accrueBorrower(address borrower, uint256 timestamp) external returns (uint256) {
        return ledger.accrueBorrower(borrower, timestamp);
    }

    /// @notice 개인 기록을 건드리지 않는 전체 갱신을 전달한다.
    function accrueTotal(uint256 timestamp) external returns (uint256) {
        return ledger.accrueTotal(timestamp);
    }

    /// @notice 개인의 현재 완제 견적을 올림하여 조회한다.
    function quoteRepayment(address borrower, uint256 timestamp) external view returns (uint256) {
        return ledger.quoteRepayment(borrower, timestamp);
    }

    /// @notice 전체 현재 채권을 최소 단위에서 내려 표시한다.
    function totalDebtRaw(uint256 timestamp) external view returns (uint256) {
        return ledger.totalDebtRaw(timestamp);
    }

    /// @notice 특정 개인의 현재 계산 결과를 저장 없이 조회한다.
    function borrowerSnapshot(address borrower, uint256 timestamp) external view returns (DebtLedger.Snapshot memory) {
        return ledger.borrowerSnapshot(borrower, timestamp);
    }

    /// @notice 전체 현재 계산 결과를 저장 없이 조회한다.
    function totalSnapshot(uint256 timestamp) external view returns (DebtLedger.Snapshot memory) {
        return ledger.totalSnapshot(timestamp);
    }

    /// @notice 조회·실패 전후 비교를 위해 개인의 실제 저장값을 읽는다.
    function storedBorrower(address borrower) external view returns (DebtLedger.Position memory) {
        return ledger.borrowers[borrower];
    }

    /// @notice 조회·실패 전후 비교를 위해 전체 실제 저장값을 읽는다.
    function storedTotal() external view returns (DebtLedger.Position memory) {
        return ledger.total;
    }

    /// @notice 극단값·지연 기록 시험에만 사용할 개인 상태를 준비한다. 운영 API가 아니다.
    function seedBorrower(address borrower, uint256 principal, uint256 interestNumerator, uint256 timestamp) external {
        ledger.borrowers[borrower] = DebtLedger.Position(principal, interestNumerator, timestamp);
    }

    /// @notice 소수 정산·범위 오류 시험을 위한 전체 상태를 준비한다. 운영 API가 아니다.
    function seedTotal(uint256 principal, uint256 interestNumerator, uint256 timestamp) external {
        ledger.total = DebtLedger.Position(principal, interestNumerator, timestamp);
    }
}
