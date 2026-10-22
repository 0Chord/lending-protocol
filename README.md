# Lending Protocol 학습 프로젝트

Solidity·Foundry로 공급·출금부터 작은 단위로 만드는 개인 학습 프로젝트다.
현재 구현 범위는 [이슈 #1](https://github.com/0Chord/lending-protocol/issues/1)의 테스트 환경·MockUSDC와
[#2](https://github.com/0Chord/lending-protocol/issues/2)의 본인 공급·예치 기록과
[#3](https://github.com/0Chord/lending-protocol/issues/3)의 본인 출금과
[#7](https://github.com/0Chord/lending-protocol/issues/7)의 지분 환산 계산과
[#8](https://github.com/0Chord/lending-protocol/issues/8)의 공급·출금·조회 연결과
[#11](https://github.com/0Chord/lending-protocol/issues/11)의 테스트용 MockWBTC와
[#12](https://github.com/0Chord/lending-protocol/issues/12)의 Mock 가격·담보 가치/한도 계산과
[#13](https://github.com/0Chord/lending-protocol/issues/13)의 본인 WBTC 담보 입금·반환과
[#14](https://github.com/0Chord/lending-protocol/issues/14)의 이자 없는 담보대출·상환 연결과
[#19](https://github.com/0Chord/lending-protocol/issues/19)의 순수 이자 계산과
[#23](https://github.com/0Chord/lending-protocol/issues/23)의 고정 금리 상수 분리와
[#20](https://github.com/0Chord/lending-protocol/issues/20)의 토큰 없는 부채 장부다. 테스트 전용 학습 프로젝트다.

## 이번에 읽을 동작: 빌린 원금과 이자를 기록한다

[DebtLedger](src/accounting/DebtLedger.sol)는 **사람별 원금·미납 이자·마지막 계산 시각을 저장하는 내부 라이브러리**다.
전체 원금·이자도 별도로 기록한다. 기존 [InterestMath](src/libraries/InterestMath.sol)가 계산을 담당하고,
장부는 어느 시점의 계산을 저장했는지 관리한다. 연10%·남은 원금 기준 단리와 이자 우선 상환은 그대로다.

첫 예시는 다음과 같다. 금액은 USDC이며 실제 토큰을 옮기지 않고 장부 기록으로 검증한다.

| 시점·동작 | 원금 | 미납 이자 | 의미 |
| --- | ---: | ---: | --- |
| 시각0에40 차입 기록 | 40 | 0 | 개인·전체에 원금40 저장 |
| 반년 뒤 조회 | 40 | 2 | 현재 값을 계산하지만 저장 기록은 그대로 |
| 같은 시각12 상환 기록 | 30 | 0 | 이자2와 원금10을 갚고 두 장부의 시각도 갱신 |
| 다시 반년 뒤 조회 | 30 | 1.5 | 줄어든 원금30에만 이자 발생 |

### 저장값과 조회값

`Position`에는 `principal`(USDC 최소 단위), `interestNumerator`(정확한 미납 이자 분자), `updatedAt`이 있다.
`State.borrowers`는 주소별 기록, `State.total`은 전체 기록이다. 이자를 최소 단위에서 잘라 저장하지 않는다.
분모는 계산기의 `Q=315_360_000_000`을 재사용하고, 정확 채권은 `principal × Q + interestNumerator`다.

`borrowerSnapshot`과 `totalSnapshot`은 기록 이후의 이자를 계산해 `Snapshot`으로 반환한다.
`Snapshot.updatedAt`은 요청한 계산 시각이고, 실제 저장된 `Position.updatedAt`은 조회만으로 바뀌지 않는다.
**시각0은 정상 시각**이다. 처음 빌리기 전이나 모두 갚은 후의 기간에는 원금0이므로 이자도0이다.
운영 연결 시 호출자는 일관된 `block.timestamp`를 전달해야 한다. 지금은 하네스가 시험 시각을 전달한다.

### 전체 이자를 두 번 더하지 않는 방법

Bob이 먼저40을 빌리고 반년 뒤 Charlie가20을 빌렸다고 하자. 그 뒤 다시 반년이 지나면
Bob의 이자는4, Charlie의 이자는1이며 전체는 원금60·이자5다.
Bob의 저장 기록이 예전 시각에 남아 있어도 **두 사람을 같은 현재 시각으로 조회한 합**은 전체와 같아야 한다.

장부를 바꾸는 순서는 다음과 같다.

1. 전체 원금으로 마지막 전체 기록부터 현재까지의 이자를 누적한다.
2. 대상 개인도 자신의 마지막 기록부터 같은 현재까지 누적한다. 이 금액을 전체에 다시 더하지 않는다.
3. 차입이면 새 원금을 더한다. 상환이면 `InterestMath.allocateRepayment`가 나눈 이자·원금을 차감한다.
4. 이번에 새로 생긴 **전체 이자**를 반환한다. 상환의 **올림 차이**는 별도 필드로 반환한다.

개인들을 순회하지 않아도 되는 이유는 같은 고정금리에서 각 원금의 기간 이자 합이 전체 원금의 기간 이자와 같기 때문이다.
전체 원금이 바뀌기 전에 이전 구간을 계산하므로, 새 대출에 과거 이자를 붙이지 않는다.
`accrueTotal`은 개인을 건드리지 않고 전체만 갱신한다. 같은 시각의 다음 갱신은 새 전체 이자0을 반환한다.

| 내부 함수 | 입력 → 결과 | 저장 영향 |
| --- | --- | --- |
| `borrowerSnapshot` / `totalSnapshot` | 대상·시각 → 원금·미납 분자·정확 채권·계산 시각 | 없음 |
| `quoteRepayment` | 사람·시각 → 원금 + 올림 미납 이자 | 없음 |
| `totalDebtRaw` | 시각 → 전체 정확 채권의 내림 표시 | 없음 |
| `accrueTotal` / `accrueBorrower` | 시각 / 사람·시각 → 새 전체 이자 분자 | 전체 / 전체와 개인의 미납 분자·시각 갱신 |
| `recordBorrow` | 사람·금액·시각 → 새 전체 이자 분자 | 갱신 후 개인·전체 원금 증가 |
| `recordRepayment` | 사람·금액·시각 → 새 전체 이자와 상환 배분 | 갱신 후 개인·전체 원금·미납 분자 차감 |

### 올림해서 받은 돈과 사라진 부채는 다르다

여기만 USDC 최소 단위인 **raw**로 설명한다. 원금100 raw에서 이자0.4 raw가 생긴 뒤30 raw를 갚으면
이자 몫으로1 raw, 원금 몫으로29 raw를 받아 원금71·미납0이 된다.

- 새 발생 이자: `0.4 × Q = 126_144_000_000`
- 정산 올림 차이: `0.6 × Q = 189_216_000_000`

전체 미납 이자에서 뺄 것은 실제로 사라진 **0.4 raw의 분자**다. 올려 받은1 raw 전부를 빼면 다른 사람의
미납 이자까지 줄이거나 산술 오류가 난다. 그래서 코드는 `개인 정산 전 분자 − 정산 후 분자`를 차감한다.
올림 차이는 기존 부채에 포함돼 있지 않았으므로 별도로 반환한다. 후속 풀은 새 발생 이자와 이 차이를 각각 한 번 반영한다.

두 사람의 정확 부채가10.2 raw·10.7 raw라면 개인 완제 견적은11·11이고, 전체 정확 부채는20.9 raw다.
`totalDebtRaw`는20을 표시한다. 개인 견적의 합22를 전체 부채로 저장하지 않는다.
첫 사람이11로 완제하면 전체는10.7, 두 번째도11로 완제하면0이며 올림 차이는 각각0.8·0.3이다.
최대 지불액을 정하는 `repayAll(maxAmount)`와 실제 토큰 수령은 #21에서 연결한다.

### 거절과 복구

- 과거 시각은 `PastTimestamp(마지막 시각, 요청 시각)`으로 거절한다. 개인 조회는 개인 기록, 전체 조회는 전체 기록을 기준으로 검사한다.
- 차입0·상환0은 `InterestMath.ZeroAmount()`로 거절한다. 상환액이 현재 완제 견적보다 크면 `RepayExceedsDebt(견적, 요청액)`이다.
- 원금·미납 분자·정확 채권의 필요한 곱이나 합이 `uint256`을 넘으면 `Panic(0x11)`이다.
- 실패하면 그 호출에서 먼저 갱신한 **개인·전체 원금, 이자, 기준 시각도 모두 복구**된다.

`U=uint256.max`, `K=floor(U/Q)`일 때 원금K의 배율 변환은 가능하지만 K+1은 불가능하다.
K에 남은 표현 여유 `168_649_639_935`만큼의 미납 분자를 더하면 정확 채권U로 성공한다.
여기서 분자1을 더하면 실패한다. 순수 계산기의 상환 견적이 나온다고 장부의 정확 채권 합산까지 가능한 것은 아니다.

[DebtLedgerHarness](test/mocks/DebtLedgerHarness.sol)의 외부 래퍼·상태 조회·`seed` 함수는 테스트용이다.
운영 라이브러리의 진입점은 모두 `internal`이며 자산 주소·토큰 전송·가격·LTV 검사를 갖지 않는다.
기존 `LendingPool`은 아직 이 장부를 호출하지 않고 이자 없는 동작을 유지한다.
이번 실패 복구 검사는 장부와 시각에 대한 것이다. 실제 토큰 실패·재진입 복구는 #21의 통합 검증 대상이다.

<details>
<summary>정상 장부 테스트의 준비·실행·실제 검증문 따라 읽기</summary>

[DebtLedgerTest](test/DebtLedger.t.sol)는 매번 빈 하네스를 만든다. Bob·Charlie는 테스트 주소이며 토큰은 배포하지 않는다.
수용 예시의 고정 숫자를 직접 비교하고, `_assertTotals`는 같은 시각의 개인 원금·이자·정확 채권 합을 전체와 비교한다.
`storedBorrower` / `storedTotal`은 조회나 실패가 실제 저장값을 바꾸었는지 관측하기 위한 시험 함수다.

| 테스트 | 준비·실행 | 실제 검증 |
| --- | --- | --- |
| `test_HalfYearSnapshotDoesNotWrite` | 시각0에40 차입, 반년 조회 | 원금40·이자2의 고정 분자·정확 채권, 개인/전체 동일, 저장 전후 전체 필드 동일 |
| `test_RepayTwelveAfterHalfYearLeavesThirty` | 40 차입 후 반년에12 상환, 다음 반년 조회 | 새 이자2 반환, 이자2·원금10 배분, 남은30·이자0·시각 갱신, 다음 이자1.5 |
| `test_AdditionalBorrowPreservesEarlierInterest` | 40 차입, 반년에10 추가, 다음 반년 조회 | 미납2 보존·원금50, 이후 총 미납4.5·완제 견적54.5 |
| `test_StaggeredBorrowersMatchCurrentGlobalDebt` | Bob40, 반년 뒤 Charlie20, 다시 반년 | Bob이자4·Charlie1·전체원금60·이자5·채권65, 같은 시각 합 일치 |
| `test_GlobalThenBorrowerOrderDoesNotDoubleCount` | 위 상태의 두 하네스, 전체 우선/개인 역순 갱신 | 새 전체 이자3을 한 번 반환, 나머지는0, 개인 보존·최종 모든 저장값 일치 |
| `test_MonthlyAndOnceAccrualAgree` | 같은1년을12등분 갱신하거나 한 번 갱신 | 반환 합·개인/전체 저장값 동일, 같은 시각 재갱신0 |
| `test_SubRawAccrualSurvivesCheckpoints` | 원금1 raw에서1초씩3회 갱신 | 새 분자1,000씩, 최종3,000, 전체 내림1·개인 견적2 |
| `test_LongEmptyPeriodDoesNotAccrueBeforeBorrow` | 20년 빈 장부 갱신 후 처음40 차입 | 첫 이자0·첫 시각 저장, 이후 반년 이자2 |
| `test_ReborrowAfterEveryoneRepaysStartsFresh` | 두 사람 완제,20년 뒤10 재차입 | 전체0 확인, 새 미납0, 이후 견적10.5, 완제한 다른 사람0 |
| `test_InterestOnlyRepaymentKeepsPrincipal` | 원금100·1년 이자10에서3 상환 | 원금100 유지·이자7, 배분3/0·올림0, 다음 반년 총미납12 |
| `test_FractionalRepaymentSeparatesAccrualAndSurplus` | 원금100 raw·1,261,440초 후30 상환, 같은 시각1 상환 | 새 이자0.4·올림0.6 분리, 원금71, 재상환에는 이자·올림 차이0 |
| `test_TwoFractionalPayoffsPreserveOtherBorrower` | 시험용10.2·10.7 준비,11씩 완제 | 견적11/11·전체표시20, 정확20.9→10.7→0, 올림0.8/0.3, 다른 개인 기록 보존 |
| `testFuzz_InterleavedOperationsConserveExactDebt` | 임의 시각·두 사람·차입/상환/갱신16회를 한 시나리오로 반복 | 매번 개인 합=전체, 새 이자 반환, 받은 금액 배분, 차입/상환/올림을 반영한 정확 채권 보존 |

fuzz는 제품 조회·반환값 사이의 일관성을 보는 보조 검사다. 독립 금액 기대값은 앞의 고정12개가 검증한다.

[DebtLedgerBoundsTest](test/DebtLedgerBounds.t.sol)는 모든 거절에서 Bob·Charlie·전체의 원금·미납 분자·시각
아홉 필드를 전후 비교한다. `_prepareTwoBorrowers`는 Bob40 raw를시각10, Charlie20 raw를시각20에 기록한다.
기본 전체 상태는 원금60·미납 분자400,000·시각20이며, Bob의시각10 기록은 그대로 남아 있다.

| 테스트 | 준비·실행 | 실제 검증 |
| --- | --- | --- |
| `test_PastTotalTimestampRestoresEveryPosition` | 기본 상태에서 Bob을시각19로 갱신 | `PastTimestamp(20,19)`·저장 보존 |
| `test_PastBorrowerTimestampRollsBackEarlierTotalCheckpoint` | 시험용 개인시각30·전체시각10,시각20 갱신 | 먼저 바뀐 전체도 복구, `PastTimestamp(30,20)` |
| `test_PersonalReadsRejectPastTimestampWithoutMutation` / `test_TotalReadsRejectPastTimestampWithoutMutation` | 기본 상태의 개인 snapshot/견적, 전체 snapshot/표시를 각각 과거로 조회 | 개인 `(10,9)`, 전체 `(20,19)`의 정확 오류·저장 보존 |
| `test_ZeroPrincipalStillRejectsPastTimestamp` | 시각10에 전액 상환 후시각9 조회·갱신 | 개인/전체0 확인, 원금0에서도 `PastTimestamp(10,9)`·저장 보존 |
| `test_ZeroRepaymentRestoresEveryPosition` | 기본 상태에서시각30에0 상환 | `ZeroAmount`, 먼저 계산한 개인/전체 이자·시각도 복구 |
| `test_ExcessRepaymentRestoresEveryPosition` / `test_MaximumRepaymentAmountUsesExcessDebtError` | 기본 상태에서42 또는U 상환 | 견적41을 담은 `RepayExceedsDebt`·저장 보존 |
| `test_EmptyRepaymentRestoresUninitializedTimestamps` | 빈 장부에서시각50에1 상환 | `RepayExceedsDebt(0,1)`·개인/전체시각0 유지 |
| `test_ZeroBorrowRestoresEveryPosition` | 기본 상태에서시각30에0 차입 | `ZeroAmount`·저장 보존 |
| `test_MaximumRawBorrowPreservesExactNumerator` | 빈 장부에서K 차입 | 개인/전체 원금K, 정확 분자`U−168_649_639_935`·시각 보존 |
| `test_OneAboveMaximumRawBorrowRestoresNewCheckpoints` | 전체만시각10 기록 후시각20에K+1 차입 | 배율 곱 `Panic(0x11)`, 먼저 바뀐 기준 시각까지 복구 |
| `test_ExactDebtAtMaximumNumeratorSucceeds` | 원금1·미납`U−Q−1,000`에서1초 갱신 | 새분자1,000, 개인/전체 정확 채권U, 개인 견적K+1·전체 표시K |
| `test_ExactDebtSumOverflowRejectsReadsAndAccrual` | 원금1·미납`U−Q`에서1초 뒤 조회·갱신 | 미납만으로는 유효해도 정확 채권 합은 `Panic(0x11)`·저장 보존 |
| `test_TotalExactDebtSumOverflowRestoresNewCheckpoints` | 일치하는 두 개인/전체의 큰 미납 상태에서1 추가 차입 | 개인별 범위 안, 전체 채권 합 초과는 `Panic(0x11)`·두 기준 시각 복구 |
| `test_AccrualPrincipalTimeProductOverflowRestoresState` / `test_AccrualRateProductOverflowRestoresState` | 원금2·기간U/2+1 또는 원금1·기간U/1,000+1 | 시간 곱/금리 곱의 `Panic(0x11)`·저장 보존 |
| `test_AccrualInterestAdditionOverflowRestoresState` | 원금1·미납`U−Q`에서315,360,001초 경과 | 유효한 새 분자를 더한 합은 `Panic(0x11)`·저장 보존 |
| `test_PersonalPrincipalAdditionOverflowRestoresNewCheckpoints` / `test_TotalPrincipalAdditionOverflowRestoresPersonalWrite` | 기존 원금에U 추가 / Bob1을 둔 채 Charlie에게U 차입 기록 | 개인 원금합/전체 원금합의 `Panic(0x11)`, 선행 개인 대입·갱신까지 복구 |

개인 시각이 전체보다 앞선 경우는 정상 API로 만들 수 없으므로 해당 검사만 불일치 fixture를 사용한다.
임의 분자 끝자리와 최댓값 fixture는 개인 합·전체가 일치하도록 준비한다. 시험용 setter는 실제 운영 API에 없다.

로컬 실행: 장부33개(정상13·경계20), 전체274개·실패0·skip0을 확인했다.
`forge test --match-contract 'DebtLedger(Test|BoundsTest)' -vv`, `forge fmt --check`, `forge build`,
`forge test -vv`를 실행했다. 원격 PR CI는 아직 실행하지 않았다.

</details>

## 기반 계산기: 연10%를 상수로 읽고 같은 이자를 계산한다

#19에서 만든 [InterestMath](src/libraries/InterestMath.sol)는 **이자를 계산하고 상환액을 나누는 계산기**다.
#23에서는 분모에 합쳐 두었던 연10%를 `ANNUAL_RATE_BPS` 상수로 분리했다. 이자 금액과 상환 규칙은 같다.
원금40 USDC와 반년을 넣으면 이자2가 나온다. 이어12를 갚는 계산을 하면 이자2·원금10으로 나누고 원금30을 남긴다.
그 뒤1년의 이자는 남은 원금30의10%인3이다. 미납 이자에는 다시 이자를 붙이지 않는 단리다.

| 상수 | 값 | 의미 |
| --- | ---: | --- |
| `YEAR_SECONDS` | 31,536,000 | 365일의 초 수 |
| `RATE_SCALE` | 10,000 | 금리100%를 표현하는 기준 |
| `ANNUAL_RATE_BPS` | 1,000 | 1,000/10,000 = 연10% |
| `DENOMINATOR` (Q) | 315,360,000,000 | `YEAR_SECONDS × RATE_SCALE` |

금리 상수는 `accrue`의 실제 누적식에서 사용한다. 금리를 입력받거나 운영 중 바꾸는 기능은 없다.
실제 풀은 아직 원금만 빌리고 갚는다. #20의 장부는 이 계산 결과를 저장하며 테스트 하네스에서 사용한다.
공급자 자산·실제 상환·`repayAll` 연결은 [#21](https://github.com/0Chord/lending-protocol/issues/21)에서 다룬다.

### 작은 이자를 남겨 두는 방법

USDC는 소수점6자리이므로 계약에서 `1 USDC = 1_000_000 raw`다. 여기서 raw는 토큰의 최소 단위다.
그보다 작은 이자도 사라지지 않도록 **나누기 전의 분자 `N`**을 보존한다.

```text
Q = 31,536,000초 × 10,000 = 315,360,000,000
이자(raw) = 원금(raw) × 경과초 × 1,000 / Q

원금40 USDC · 반년:
N = 40,000,000 × 15,768,000 × 1,000 = 630,720,000,000,000,000
N / Q = 2,000,000 raw = 2 USDC
```

USDC의1,000,000은 **토큰 수량**의 기준이고, 금리의10,000은 **비율**의 기준이다. 서로 다른 역할이다.
이전 Q=315,360,000과 비교하면 같은 이자의 분자·분모가 모두1,000배다. 원금·상환액·지분 수량은 커지지 않는다.

`accrue`의 핵심 코드는 다음과 같다. 금리를 한 번 곱하고, 미납 이자는 이자가 붙는 원금에 넣지 않는다.

```solidity
return interestNumerator + principal * elapsedSeconds * ANNUAL_RATE_BPS;
```

바로 나누지 않으므로 원금1 raw를3초 유지한 결과와1초씩 세 번 계산한 결과가 모두 분자3,000이다.
시간 구간을 쪼갰다는 이유로 소수 이자가 사라지지 않는다. 원금과 경과초를 먼저 곱하므로 둘 중0이면
다른 입력이 최댓값이어도 기존 분자를 보존한다.
이 함수는 경과초를 입력받는다. 마지막 계산 시각은 위 DebtLedger가 저장하며, 실제 풀 연결 시 호출자는 블록 시각을 전달한다.
이미 정수 금액인 raw를 분자로 바꾸는 `toNumerator`는 `raw × Q`만 계산하며 금리를 다시 곱하지 않는다.

| 함수 | 입력 → 반환 | 경계 |
| --- | --- | --- |
| `accrue(P, N, seconds)` | 남은 원금·기존 미납 분자·기간 → 새 미납 분자 | 원금0 또는 기간0이면 기존 분자 유지; 미납 이자에는 이자를 붙이지 않음 |
| `toNumerator(raw)` | raw → `raw × Q` | 정확한 곱이 uint256에 들어가야 함 |
| `toRawDown(N)` / `toRawUp(N)` | 분자 → 내림/올림한 raw | 분자0은 둘 다0; 최대 분자도 몫·나머지로 계산 가능 |
| `quoteDebt(P, N)` | 남은 원금·미납 분자 → `P + ceil(N/Q)` | 실제로 완제할 금액의 견적이며 기록이나 수익을 바꾸지 않음 |
| `allocateRepayment(P, N, amount)` | 부채·상환액 → 남은 부채와 이자/원금 배분 | 요청0과 견적 초과는 거절; 이자를 먼저 갚음 |

### 상환액은 이자부터 갚는다

`allocateRepayment`는 먼저 요청0을 거절하고, 완제 견적보다 큰 요청도 거절한다.
상환액이 올림한 미납 이자보다 작으면 전부 이자에서 빼고 원금은 유지한다.
이자를 전부 정리할 수 있으면 이자를 최소 단위까지 올려 받고, 남은 금액만 원금에서 뺀다.

| 준비 | 상환액 | 남은 원금 / 미납 이자 | 받은 이자 / 원금 | 올림 차이 |
| --- | ---: | --- | --- | ---: |
| 원금100 USDC·이자10 USDC | 30 USDC | 80 / 0 USDC | 10 / 20 USDC | 0 |
| 원금100 USDC·이자10 USDC | 3 USDC | 100 / 7 USDC | 3 / 0 USDC | 0 |
| 원금100 raw·이자1.4 raw | 1 raw | 100 / 0.4 raw | 1 / 0 raw | 0 |
| 원금100 raw·이자1.4 raw | 2 raw | 100 / 0 raw | 2 / 0 raw | 0.6 raw |
| 원금100 raw·이자0.4 raw | 30 raw | 71 / 0 raw | 1 / 29 raw | 0.6 raw |
| 원금100 raw·이자0.4 raw | 101 raw | 0 / 0 raw | 1 / 100 raw | 0.6 raw |

반환하는 `Repayment`의 `remainingPrincipal`, `interestPaid`, `principalPaid`는 raw이고,
`remainingInterestNumerator`, `roundingSurplusNumerator`는 정확 분자다.
표의0.4 raw는 분자`126_144_000_000`, 올림 차이0.6 raw는 분자`189_216_000_000`으로 반환한다.
이 차이는 장부가 별도로 반환하고 후속 풀에서 공급자 수익으로 반영할 값이다. 계산기 자체는 자산·현금·부채 기록을 바꾸지 않는다.

정산이 끝난 미납 분자는0이므로 다음 상환에 같은 이자를 다시 청구하지 않는다.
다만 **새로 생긴 작은 이자를 여러 번 정산하면 올림 비용도 여러 번 생긴다.** 원금4 raw에서 반년 이자0.2 raw를
두 번 정산하면 실제 이자는 총2 raw를 받는다.1년 이자0.4 raw를 한 번 정산하면1 raw를 받는다.
견적 조회나 기간 계산만으로 이 비용을 기록하지는 않는다.

### 잘못된 입력과 너무 큰 계산

상환0은 `ZeroAmount()`, 부채0에 양수 상환하거나 견적을 넘으면 `RepayExceedsDebt(견적, 요청액)`이다.
예를 들어 원금100 raw·이자0.4 raw에서102 raw 요청은 `RepayExceedsDebt(101, 102)`로 거절한다.
최대 정수를 요청해도 불필요한 배율 곱을 먼저 하지 않아 같은 초과상환 오류로 구분한다.

필요한 분자 곱·분자 합·원금과 올림 이자의 합이 `uint256`을 넘으면 `Panic(0x11)`이다.
값을 잘라내거나 최대값으로 바꾸지 않는다. 반면 올림은 `N + Q - 1`을 미리 더하지 않고 몫과 나머지로 구한다.
올림 차이도 `Q - 나머지`로 구하므로 큰 완제액 전체에Q를 곱할 필요가 없다.

`U = uint256.max`, `K = floor(U/Q)`라면 `K × Q`는 표현 가능하지만 `(K+1) × Q`는 불가능하다.
새 Q는 기존의1,000배이므로 분자로 표현 가능한 실제 금액의 상한은 줄어든다. 같은 uint256 안에
더 큰 배율로 담는 데 따른 한계이며, 두 표현에서 모두 허용되는 정상 금액의 이자는 동일하다.
분자U 자체의 내림K·올림K+1과 순수 상환 배분은 성공할 수 있다. 이를 장부의 모든 정확 채권 합산도
성공한다는 뜻으로 해석하지 않는다. 기존 [ShareMath](src/libraries/ShareMath.sol)의 큰 중간 곱 처리 계약은 그대로다.
정상 누적으로 생긴 분자는1,000의 배수지만 변환·견적·상환은 그 밖의 uint256 분자도 받는다.
기존 운영 장부의 분자를 이전하는 기능은 없으며, DebtLedger와 후속 풀은 처음부터 새 단위를 사용한다.

<details>
<summary>이자 테스트35개의 준비·실행·실제 검증문 따라 읽기</summary>

모두 [InterestMathTest](test/InterestMath.t.sol)에 있다. `setUp`은 오류를 외부 호출 경계에서 관측할
`InterestMathHarness`만 배포한다. 정상 계산은 라이브러리를 직접 호출하며, 하네스는 계산을 복제하지 않고 전달한다.
토큰·가격 원천·풀은 배포하지 않는다. 아래 테스트명은 공통 접두어 `test_`를 생략했다.

| 테스트 | 준비 → 실행 | 실제로 비교하는 값 |
| --- | --- | --- |
| `FixedAnnualRateIsSeparateFromDenominator` | 고정 상수 네 개 조회 | 1년31,536,000초·금리 기준10,000·금리1,000·Q315,360,000,000 |
| `FortyForHalfYearAccruesTwo`, `OneAndTwoYearsRemainSimpleInterest` | 원금40 USDC, 반년/1년/2년 → 누적 | 이자2/4/8 USDC에 해당하는 고정 분자; 반년 결과는 내림·올림 모두2,000,000 raw |
| `UnpaidInterestDoesNotEarnInterest`, `ZeroPrincipalOrTimePreservesExistingInterest` | 기존 이자10·원금40의1년, 또는 원금/기간0 → 누적 | 이자14, 또는 기존 분자 그대로; 미납 이자의 복리 없음 |
| `SplittingTimePreservesSubRawInterest` | 원금1 raw를1초씩 세 번 또는3초 한 번 → 누적 | 두 결과 모두 분자3,000; 이후0초도3,000 |
| `AccrualAcceptsMaximumNumerator`, `AccrualProductOverflowReverts`, `AccrualAdditionOverflowReverts` | 원금U/1,000·기간1초와 그 다음 원금; 기존 분자U−1,000/U−999에1,000 추가; U×2의 기간 곱 | 허용 결과U−935 / U; 금리 곱·기간 곱·합 초과는 정확한 `Panic(0x11)` |
| `DebtQuoteRoundsOnlyUnpaidInterestUp`, `QuoteAtOneRawInterestBoundary` | 원금100·이자0.4 raw 견적, 원금1 raw·T−1/T/T+1초 누적 후 견적. T=315,360,000초=Q/1,000 | 101, 정확 분자Q−1,000/Q/Q+1,000과 견적2/2/3 |
| `ExactAndZeroConversionsDoNotAddRounding`, `SubRawInterestHasDifferentFloorAndCeil` | 0·정수2 USDC·소수0.4 raw → 배율/내림/올림·견적 | 정수와0은 그대로, 소수는 내림0·올림1 |
| `ArbitraryNumeratorsAroundOneRawAreRounded` | N=Q−1/Q/Q+1을 직접 입력 → 내림/올림 | 각각0/1, 1/1, 1/2; 분자가1,000의 배수가 아니어도 허용 |
| `MaximumNumeratorCanBeRounded`, `NumeratorConversionHasExplicitUpperBound`, `DebtQuoteAdditionOverflowReverts` | N=U·K/K+1 배율, 원금+올림 이자 합 경계 → 변환·견적 | U의 나머지168,649,639,935·내림K·올림K+1; 배율/견적 초과만 정확한 산술 오류 |
| `RepaymentPaysInterestBeforePrincipal`, `PartialInterestPaymentPreservesPrincipal`, `ExactInterestOnlyPaymentPreservesPrincipal` | 원금100·이자10 USDC에서30/3/10 상환 계산 | 남은 원금80/100/100·이자0/7/0; 지급 배분·올림 차이까지 다섯 필드 비교 |
| `AccrualAfterRepaymentUsesReducedPrincipal` | 40·반년 누적 →12 상환 → 다음1년 누적 | 이자2, 원금30·이자0·지급2/10·차이0, 다음 이자3의 고정 분자 |
| `NoInterestPaymentOnlyReducesPrincipal` | 원금100 raw·이자0 →40 상환 | 남은 원금60, 지급 이자0·원금40, 나머지 필드0 |
| `PartialFractionalInterestKeepsRemainder`, `ClearingFractionalInterestOnlyRoundsOnce` | 원금100 raw·이자1.4 raw →1/2 상환 | 부분 상환은 분자126,144,000,000 유지; 정산은 분자0·차이189,216,000,000 |
| `FractionalInterestSettlementThenPrincipal`, `FullRepaymentClearsPrincipalAndInterest` | 원금100 raw·이자0.4 raw →30/101 상환 | 원금71/0, 미납0, 이자 지급1·원금 지급29/100·차이189,216,000,000 |
| `SettledInterestIsNotChargedAgain` | 소수 이자 정산 반환값으로 다시1 raw 상환 | 두 번째는 원금만1 차감, 이자 지급·미납·차이 모두0 |
| `SeparateSettlementsCanAccumulateRounding` | 원금4 raw의 반년 이자 두 번 / 1년 한 번 → 각각 정산 | 실제 이자2/1 raw; 올림 차이 총분자504,576,000,000/189,216,000,000 |
| `ZeroRepaymentRevertsBeforeQuote`, `NoDebtRepaymentReverts`, `ExcessRepaymentRevertsBeforeScalingRequest`, `RepaymentPropagatesQuoteOverflow` | 요청0·부채0·견적+1/최대 요청·견적 합 초과 → 배분 | 각각 정확한0/초과상환 오류와 인수, 또는 `Panic(0x11)`; 부수 산술 오류로 거절 이유를 숨기지 않음 |
| `PartialMaximumInterestPreservesExactRemainder`, `MaximumInterestSettlementAvoidsUnneededMultiplication`, `MaximumPrincipalSettlementDoesNotScalePayment` | 최대 분자 일부/전부, 이자 없는 최대 원금 → 상환 | 나머지168,649,639,935 / 완제 차이146,710,360,065 / 원금 전액 지급; 다섯 필드 비교 |

상환 결과는 공통 `_assertRepayment`가 다섯 필드를 각각 비교한다. 기대값은 계산 함수의 결과를 다시 정답으로 쓰지 않고
명세의 고정 금액·분자에서 정했다. 이 검증은 순수 계산과 오류 경계이며, 토큰 전송·상태 복구·실제 시각 갱신은 후속 범위다.

새 계산 검사는 `forge test --match-contract InterestMathTest -vv`로 실행한다.
기존 CI와 같은 전체 검사는 `forge fmt --check`, `forge build`, `forge test -vv`다.

</details>

## #14에서 익힌 동작: 담보로 빌린 원금을 갚고 담보를 돌려받는다

#14는 **공급 지분·WBTC 담보·USDC 원금 부채를 별도로 기록**한다. 공급자는 `supply`로 지분을 받고,
차입자는 `depositCollateral`로 담보를 맡긴 뒤 `borrow`로 USDC를 받는다. `repay`는 본인 원금만 줄이며,
부채가 0이 된 뒤 `withdrawCollateral`을 별도로 호출해야 담보가 돌아온다.

아래는 #13 병합본 `a1fcd9b`에 추가한 대출·상환의 실제 함수와 검증문을 읽기 위한 안내다.
정상 대출·상환부터 배포 연결 검사, 거절 조건, 공통 현금 한도, 전송 실패·재진입 순서로 읽는다.
대출과 출금의 공통 재원 연결을 포함해 로컬 전체206개가 통과했다. 실행·독립 리뷰·원격 CI 결과는 PR에서 각각 확인한다.

### 먼저 볼 정상 흐름: 40을 빌리고 15와 25를 갚는다

[대출 테스트](test/LendingPoolBorrow.t.sol)의 `test_BorrowFortyMovesCashAndRecordsOnlyDebt`와
[상환 테스트](test/LendingPoolRepay.t.sol)의 `test_RepayFifteenThenTwentyFiveAndReturnCollateral`부터 읽는다.
[BorrowTestBase](test/helpers/BorrowTestBase.sol)는 Alice에게 **100 USDC만 발행해 전부 정상 공급**하고,
Bob은 1 WBTC를 정상 담보 입금한다. Mock 가격은 1 WBTC당 100 USDC, 가격 시각과 현재시각은 모두 10,000초다.
이 준비는 뒤의 #13 담보 예시(Alice에게 200 USDC 발행)와 다르다.

| 단계 | Bob USDC | 풀 USDC 현금 | Bob / 총부채 | Bob 담보 기록 | Alice 공급 권리 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 정상 공급·담보 입금 완료 | 0 | 100 | 0 / 0 | 1 WBTC | 100 |
| Bob이 40 대출 | 40 | 60 | 40 / 40 | 1 WBTC | 100 |
| 유한 승인 15 뒤 15 상환 | 25 | 75 | 25 / 25 | 1 WBTC | 100 |
| 새 유한 승인 25 뒤 25 상환 | 0 | 100 | 0 / 0 | 1 WBTC | 100 |
| 새 승인 없이 1 WBTC 반환 | 0 | 100 | 0 / 0 | 0 | 100 |

표의 USDC는 사람이 읽는 단위이며 계약 입력·부채·이벤트는 USDC6 최소 단위다. 40 USDC는 `40_000_000`이다.
대출은 Bob의 USDC 승인을 요구하지 않는다. 상환은 Bob의 USDC 승인이 필요하고, 위 유한 승인은 각 요청 후 0이다.
원금 대출·상환 중 인정자산·총지분·Alice 지분은 각각 100을 유지한다. 현금과 받을 원금의 구성이 바뀌는 것이다.
WBTC 담보를 USDC 인정자산에 더하거나, 차입자의 공급 지분을 부채와 자동으로 상계하지 않는다.

### 실제 입력의 단위를 배포 때 확인한다

현재 생성자는 `new LendingPool(usdc, wbtc, priceSource)`다. 세 주소의 코드와 두 토큰의 구분을 먼저 확인한 뒤,
**대출 토큰6 → 담보 토큰8 → 가격 원천8** 순서로 각 실제 주소의 `decimals()`를 읽는다.
[LendingPool](src/LendingPool.sol)의 생성자와 `_checkDecimals`를 읽으면 이 경계를 확인할 수 있다.

| 연결 오류 | 구분할 결과 |
| --- | --- |
| 자산/담보/가격 중 하나만 18자리 | `UnsupportedDecimals(해당 주소, 기대 6 또는 8, 실제 18)` |
| WBTC를 대출 자산에, USDC를 담보에 연결 | 첫 자산 검사에서 `UnsupportedDecimals(WBTC 주소, 6, 8)` |
| decimals 함수 없음·빈 응답·revert·짧은 ABI·uint8 범위 밖의 raw256 | `InvalidDecimalsMetadata(해당 주소)` |
| 0 또는 코드 없는 가격 주소 | `InvalidPriceSource(해당 주소)` |

배포에서 `latestPrice()`는 호출하지 않는다. 따라서 가격값이 0이거나 오래되었어도 metadata8 연결은 배포 가능하다.
항상 가격 조회가 실패하는 원천으로도 배포·공급·담보 입금·부채 없는 반환이 가능해야 한다.
[정밀도 테스트](test/LendingPoolConfiguration.t.sol)는 정확한 오류와 기존 토큰 잔고·승인·총발행량·원시 가격의 보존,
배포 중 이벤트 부재, 이후 정상 연결의 배포 성공을 함께 비교한다.
metadata 검사는 단위 연결 검사이며 토큰 정체나 가격 페어의 진실성, 임의 계약의 향후 정밀도 변경까지 보증하지 않는다.

### 대출·상환·담보 반환이 멈추는 지점

[LendingPool](src/LendingPool.sol)의 `borrow`, `repay`, `withdrawCollateral`을 아래 순서로 읽는다.

| 행동 | 판단 순서 | 성공 시 변경과 외부 호출 |
| --- | --- | --- |
| `borrow(amount)` | 0 거절 → 가격·갱신시각 검증 및 70% 총부채 한도 계산 → 본인 기존 부채를 포함한 한도 → 사용 가능 현금 | 개인/총부채 선증가 → 본인에게 USDC 전송 → `Borrowed` 1회 |
| `repay(amount)` | 0 거절 → 본인 부채를 넘는 요청 전체 거절 | 승인된 USDC를 실제 수령 → 개인/총부채 차감 → `Repaid` 1회 |
| `withdrawCollateral(amount)` | 0 거절 → 본인 부채0 필수 → 본인 담보 기록 이하 | 담보 기록 선차감 → 본인에게 WBTC 전송 → `CollateralWithdrawn` 1회 |
| `withdraw(amount)` | 0 거절 → 본인 USDC 환산 권리 → 공통 사용 가능 현금 → 올림 지분·마지막 지분의 잔여자산 검사 | 인정자산·총/개인 지분 선차감 → 본인에게 USDC 전송 |

대출 한도는 이번 요청의 한도가 아니라 **기존 부채를 포함한 총부채 한도**다. 담보1·가격100이면 70까지 가능하다.
40을 빌린 뒤 가격을50으로 낮추면 한도는35가 되어 추가1 최소 단위도 거절한다. 기존 부채40을 지우지는 않는다.
코드는 `debt > limit || amount > limit - debt`로 비교해 이 상황을 underflow나 요청액 합산 overflow로 잘못 처리하지 않는다.
가격0·음수, 시각0·미래, 3601초 이상 지난 가격은 거절하며 정확히3600초는 허용한다. 담보0도 잘못된 가격을 숨기지 않는다.

상환은 유효한 가격을 요구하지 않는다. 부채40에서 지갑·승인을50으로 충분히 준비해도 50상환은
`RepayExceedsDebt(40_000_000, 50_000_000)`로 전체 거절한다. 초과분을 보관하거나 일부만 받지 않는다.
이 사례의 추가 mint10 때문에 USDC 총발행량은110이며, 잔고 부족에 우연히 실패한 것을 초과상환 검사로 세지 않는다.
부채가 남은 담보 반환은 `OutstandingDebt`로 거절하고, 전액 상환 후에도 담보는 반환 요청 전까지 그대로 있다.

가격값과 metadata는 역할이 다르다. metadata는 배포 때만 확인하고, 배포 후에는 **새 `borrow`만 가격값을 읽는다.**
공급·출금·담보 추가·상환·부채0 담보 반환과 장부·사용 가능 현금 조회는 가격 원천에 의존하지 않는다.
`test_PriceAndMetadataFailureDoNotBlockPriceIndependentActions`는 정상 대출 뒤 가격 및 세 역할의 metadata 호출이
실제로 revert하도록 바꾸어 위 동작을 실행한다. 오래된 가격만 놓고 우연히 통과한 사례와 구별한다.

### 직접 유입20은 대출과 출금의 재원이 되지 않는다

C는 풀의 실제 USDC 현금, A는 공급 장부의 인정자산, D는 미상환 총원금, S는 총지분이다.
정상 장부의 `D <= A`에서 [availableLiquidity](src/LendingPool.sol)는 **`min(C, A - D)`**다.
풀에 직접 보낸 USDC는 공급 지분을 만들지 않으며, `repay`를 호출하지 않았으므로 부채도 줄이지 않는다.
대출과 공급자 출금은 이 한도를 함께 사용해 직접 유입을 공급자 재원으로 꺼내 쓰지 않는다.

| 단계 | C 현금 | A 인정자산 | D 총부채 | S / Alice 지분 | 사용 가능 현금 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Alice100 공급 + 직접20 유입 | 120 | 100 | 0 | 100 / 100 | 100 |
| Bob70 대출 | 50 | 100 | 70 | 100 / 100 | 30 |
| Alice40 출금 거절 | 50 | 100 | 70 | 100 / 100 | 30 |
| Alice30 출금 | 20 | 70 | 70 | 70 / 70 | 0 |
| Bob70 상환 | 90 | 70 | 0 | 70 / 70 | 70 |
| Alice 나머지70 출금 | 20 | 0 | 0 | 0 / 0 | 0 |
| 새 공급자 Charlie10 공급 | 30 | 10 | 0 | 10 / 0 | 10 |

[공통 재원 테스트](test/LendingPoolLiquidity.t.sol)의 transfer·mint 두 사례가 이 순서를 각각 실행한다.
C50·A100·D70에서 출금40은 `InsufficientLiquidity(30_000_000, 40_000_000)`이다.
Bob의 담보를2 WBTC로 늘려 총부채 한도140을 준비해도 추가 대출40은 같은 재원 오류다.
담보 한도 부족과 현금 부족을 서로의 검증 근거로 쓰지 않는다.

실제 현금이 장부상 남은30보다 적은10이면 사용할 수 있는 금액도10이다. 이 손실 준비는 테스트의 잔고 조정이며
A를 자동으로 상각하는 기능이 아니다. D가 A보다 크도록 시험 장부를 주입한 경우에는 `InvalidDebtAccounting(A,D)`를
발생시켜 잘못된 장부를0현금으로 숨기지 않는다. 정상 풀에는 이 상태를 만들기 위한 setter가 없다.

### 전송 실패와 재진입은 어느 순간을 관측하나

[실패 테스트](test/LendingPoolDebtFailure.t.sol)는 실제 transfer/transferFrom 뒤 false 또는 원본 revert를 발생시킨다.
대출 실패는 먼저 늘린 개인/총부채와 이미 움직인 토큰을 복구한다. 상환 실패는 토큰 이동·유한 승인 소비·부채를 복구한다.
장애를 끄고 같은 요청을 다시 실행하면 대출40 또는 상환15가 한 번만 반영된다. 별도 거래로 끝난 approve까지 취소하지 않는다.

[재진입 테스트](test/LendingPoolBorrowReentrancy.t.sol)는 [DebtReentrantMockUSDC](test/mocks/DebtReentrantMockUSDC.sol)가
실제 토큰 이동을 끝낸 뒤 풀을 다시 호출하게 한다. 중첩 호출자는 Bob이 아니라 토큰 계약 자신이다.
그 주소에 정상 공급raw1·담보raw2를 만들며, 가격100에서 담보raw2의 한도는 USDC raw1이다.
중첩 상환에는 정상 대출raw1과 잔고·승인도 준비한다. 담보raw1이면 한도0이므로 충분한 대출 전제가 아니다.

| 콜백 시점 | 직접 관측할 값 | 오류 처리 결과 |
| --- | --- | --- |
| 대출의 USDC 전송 직후 | Bob이 USDC40을 받았고 개인/총부채도 이미 증가. A/S/공급자 지분 유지 | 중첩 상환의 정확한 `ReentrancyGuardReentrantCall`을 잡으면 바깥 대출만 1회 성공 |
| 상환의 USDC 수령 직후 | Bob 잔고·승인이 줄고 풀 현금은 늘었지만 부채는 아직40 | 중첩 대출 오류를 잡으면 이어서 부채25로 감소. 오류를 전파하면 바깥 상환 전체 복구 |
| 전파 실패 후 정상 재시도 | 직전 장부·두 토큰·승인과 콜백 설정/관측 저장 비교 | 실패 중 저장한 `attempted`까지 되돌아가며, 콜백 해제 뒤 같은 상환 성공 |

모든 공급·출금·담보 입금·반환·대출·상환은 같은 `nonReentrant` 잠금을 사용한다.
새 대출/상환 대표 경로와 기존 WBTC↔USDC 회귀를 함께 읽는다. 모든6×6 조합을 실행했다는 뜻은 아니다.
기존 공급 중 중첩 대출, 기존 출금 중 중첩 상환도 각각 정확한 잠금 오류와 바깥1회 반영을 비교한다.
같은 토큰 주소가 콜백을 끈 상태에서 raw1 대출/상환에 실제 성공하는 정상 대조도 두어 자원이 충분했는지 확인한다.
가격 조회의 읽기 전용 호출이나 일반 자원 부족 오류를 공유 잠금의 실행 근거로 삼지 않는다.

### 테스트를 찾고 읽는 지도

아래 표는 로컬 EVM에서 실제 풀·토큰을 배포하는 동작 테스트다. Given은 준비, When은 호출,
Then은 테스트의 실제 assertion이 비교하는 값이다. 실행과 독립 검토 결과는 PR의 검증 기록에서 확인한다.

| 파일·대표 실제 함수 | Given — 준비 | When — 실행 | Then — 실제 확인 |
| --- | --- | --- | --- |
| [Configuration](test/LendingPoolConfiguration.t.sol) · `test_RejectsEighteenDecimalCollateral` | 정상 USDC6·가격8, 잔고/승인이 있는 담보18 | 새 풀 생성 | 대상 주소와 기대8·실제18 오류, 기존 상태·원시 가격 보존, 생성 이벤트 없음, 정상 재배포 대조 |
| 같은 파일 · `test_RejectsMissingDecimalsInEveryRole` | 호출은 성공하지만 빈 응답인 대역 | 자산·담보·가격 역할에 각각 연결 | 세 경우 모두 해당 주소의 `InvalidDecimalsMetadata` |
| [Borrow](test/LendingPoolBorrow.t.sol) · `test_BorrowFortyMovesCashAndRecordsOnlyDebt` | 정상 공급100·Bob 담보1·가격100 | Bob40 대출 | Bob 현금/부채40·풀60, 공급자 권리100·담보1·총발행량100 유지, 이벤트1회 |
| 같은 파일 · `test_PriceDropBelowExistingDebtRejectsWithoutUnderflow` | 부채40 뒤 가격50으로 변경 | 추가 raw1 대출 | 한도35·현재부채40·요청1의 정확한 오류, 직전 snapshot 유지 |
| [Repay](test/LendingPoolRepay.t.sol) · `test_RepayFifteenThenTwentyFiveAndReturnCollateral` | 정상 대출40 | 승인15→상환15, 승인25→상환25, 담보1 반환 | 단계별 현금75/100·부채25/0, 승인0, 마지막 WBTC 반환과 각 이벤트1회 |
| 같은 파일 · `test_ExcessRepayPreservesFundedRequest` | 부채40·Bob잔고50·승인50·총발행량110 | 상환50 | 정확한 초과상환 오류, 잔고/승인/부채/총발행량 보존 |
| 같은 파일 · `test_PriceAndMetadataFailureDoNotBlockPriceIndependentActions` | 정상 대출40 뒤 가격·metadata 조회 오류 주입 | 상환15+25·담보 추가/반환·공급자 출금/재공급 | 각 자체 규칙대로 성공/거절, 마지막 현금/A/S100·부채0. raw 조회도 원천 없이 성공 |
| [Liquidity](test/LendingPoolLiquidity.t.sol) · `test_DirectTransferSurplusStaysThroughBorrowWithdrawRepayAndNewSupply` / `test_DirectMintSurplusStaysThroughBorrowWithdrawRepayAndNewSupply` | 정상 공급100 뒤 직접20 | 대출70→출금40 거절/30 성공→상환70→출금70→새 공급10 | 위 잉여 표의 각 중간값·정확한 오류·각 정상 이벤트를 비교 |
| 같은 파일 · `test_AdditionalBorrowCannotSpendSurplusEvenWithEnoughCollateral` | C50/A100/D70, 담보2로 한도140 | 추가 대출40 | 담보 한도 내 요청이어도 사용 가능30 오류, 전체 관측값 보존 |
| 같은 Liquidity 파일 · `test_EmptyAccountingWithSurplusRejectsBorrowAndRecognizesOnlyNewSupply` | A/S/D0·현금20·Bob 담보1 | raw1 대출 거절 뒤 Charlie10 정상 공급 | 사용 가능0의 정확한 오류·상태 보존, 새 지분/권리10·현금30 |
| 같은 파일 · `test_BorrowUsesLowerActualCashAfterLoss` / `test_WithdrawalUsesLowerActualCashAfterLoss` | A100/D70·담보2에서 현금만10으로 조정, 총발행량80 | 각각11 거절 뒤10 대출/출금 | 현금 부족(10,11)·실패 snapshot 유지, 성공 뒤 현금0·A/D는 각각100/80 또는90/70 |
| 같은 파일 · `test_TotalDebtAboveAssetsRaisesAccountingErrorWithoutMutation` | 시험 하네스로 A100·D101 | 사용 가능 현금 조회와 양수 출금 | 정확한 장부 오류·유동성 조회를 제외한 snapshot 보존·풀 이벤트 없음 |
| [DebtFailure](test/LendingPoolDebtFailure.t.sol) · `test_BorrowTransferFalseRestoresAndRetries` / `test_RepayTransferRevertRestoresAndRetries` | 정상 자원과 실제 전송 뒤 장애 대역 | 실패 호출→장애 해제→동일 요청 | 정확한 SafeERC20/원본 오류·snapshot 복구·재시도1회와 이벤트1회 |
| [BorrowReentrancy](test/LendingPoolBorrowReentrancy.t.sol) · `testBorrowCatchesNestedRepayAndRecordsOuterBorrowOnce` | 토큰 주소도 정상 부채·잔고·승인raw1 보유 | Bob40 대출 중 토큰 주소가 상환raw1 | 정확한 잠금 오류·선증가 부채 관측·바깥 대출1회와 중첩 주소 상태 보존 |
| 같은 파일 · `testRepayCatchesNestedBorrowAndObservesDebtBeforeReduction` / `testRepayPropagatesNestedBorrowAndRestoresAllState` | 토큰 주소 담보raw2·한도raw1, Bob부채40·승인15 | Bob상환15 중 토큰 주소 대출raw1, 오류 잡기/전파 각각 | 수령 후·부채 감소 전 관측 / 전파 시 전체 장부·유한 승인·콜백 저장 복구 및 정상 재시도 |
| 같은 BorrowReentrancy 파일 · `testBorrowPropagatesNestedRepayAndRestoresAllState` | 중첩 상환 가능한 토큰 주소·Bob 담보1·대출40 요청 | 대출 중 중첩 오류 전파→콜백 해제→대출 재시도 | 선증가 부채·실제 이동·콜백 저장 복구, 재시도 대출/이벤트1회 |
| 같은 파일 · `testSupplyCatchesNestedBorrowAndRecordsOuterSupplyOnce` / `testWithdrawCatchesNestedRepayAndRecordsOuterWithdrawOnce` | 중첩 호출 자원과 Alice 공급/출금10 준비 | 기존 공급 중 대출raw1 / 출금 중 상환raw1 | 정확한 잠금 오류. 공급은 기록 증가 전, 출금은 기록 차감 후 관측; 바깥 요청만1회 반영 |
| 같은 파일 · `testNestedBorrowResourcesPermitNormalRawOneBorrow` / `testNestedRepayResourcesPermitNormalRawOneRepay` | 콜백을 끄고 위와 같은 토큰 주소 자원 준비 | 정상 대출raw1 / 상환raw1 | 실제 성공·개인/총부채1 또는0·상환 승인0·각 이벤트1회 |

대표 사례의 표가 나머지 모든 테스트의 상세 설명이나 사용자 이해 확인을 대신하지 않는다.
추가 가격·한도·승인·사용자 분리·현금 조정·기존 회귀의 함수에는 목적과 실패 경계를 담은 한국어 NatSpec이 있다.

| 역할 | 읽을 파일과 구분 |
| --- | --- |
| 제품 실행 코드 | [LendingPool](src/LendingPool.sol), [CollateralMath](src/libraries/CollateralMath.sol), [ShareMath](src/libraries/ShareMath.sol), [가격 인터페이스](src/interfaces/ICollateralPriceSource.sol). 풀 상태 변경과 순수 계산의 책임을 구분한다. |
| 로컬 시험 자산·가격 | [MockUSDC](src/mocks/MockUSDC.sol), [MockWBTC](src/mocks/MockWBTC.sol), [Mock 가격 원천](test/mocks/MockCollateralPriceSource.sol), [항상 실패하는 가격 원천](test/mocks/RevertingCollateralPriceSource.sol). 실제 USDC·BTC·오라클 연동이 아니다. |
| 테스트 준비·관측 | [BorrowTestBase](test/helpers/BorrowTestBase.sol)의 `_snapshot`은 전역8값과 Alice/Bob/Charlie/토큰 주소 각8값을 비교한다. 두 토큰 잔고/승인/총발행량, 공급 권리, 담보, 개인/총부채, 사용 가능 현금을 포함한다. |
| 실패·재진입·잘못된 연결 대역 | [FailingMockUSDC](test/mocks/FailingMockUSDC.sol), [DebtReentrantMockUSDC](test/mocks/DebtReentrantMockUSDC.sol), [MetadataMocks](test/mocks/MetadataMocks.sol). 실패 조건과 관측 시점을 시험에서만 만든다. |
| 기존 회귀와 시험용 하네스 | [기존 풀](test/LendingPool.t.sol), [지분](test/LendingPoolShares.t.sol), [담보](test/LendingPoolCollateral.t.sol), [담보 실패](test/LendingPoolCollateralFailure.t.sol), [담보 재진입](test/LendingPoolCollateralReentrancy.t.sol), [LendingPoolHarness](test/mocks/LendingPoolHarness.sol). 공통 재원 파일의 `InvalidDebtAccountingHarness`도 손상 장부 준비 전용이다. 하네스의 장부 setter는 일반 풀 API가 아니다. |
| 실행·자동 검사 | [foundry.toml](foundry.toml), [.github/workflows/test.yml](.github/workflows/test.yml). 형식·빌드·동작 검사를 실행하며 학습 확인이나 독립 리뷰를 대신하지 않는다. |

#14 신규 함수는 정밀도13·대출19·상환10·공통 재원11·전송 실패4·재진입8로65개다.
기존141개와 함께 로컬 전체206개가 통과했다(실패0·skip0). 형식·빌드 검사도 통과했다.
이 수는 테스트 함수/실행 항목의 수이며 한 함수 안의 입력 반복을 별도 함수로 더하지 않는다.
#13의141개 기록은 아래 해당 단계의 근거다. 독립 리뷰 결과는 별도로 기록하고, #14 원격 CI는 해당 head를 게시한 뒤 확인한다.

## 실행 환경

Git과 Foundry가 설치된 환경에서 프로젝트 파일과 서브모듈 고정 정보를 받은 뒤 루트에서 실행한다.

```sh
git submodule update --init --recursive
forge fmt --check
forge build
forge test --match-contract MockUSDCTest -vv
forge test --match-contract MockWBTCTest -vv
forge test --match-contract LendingPoolTest -vv
forge test --match-contract LendingPoolSharesTest -vv
forge test --match-contract ShareMathTest -vv
forge test --match-contract CollateralMathTest -vv
forge test --match-contract CollateralPriceSourceTest -vv
forge test --match-contract LendingPoolCollateralTest -vv
forge test --match-contract LendingPoolCollateralFailureTest -vv
forge test --match-contract LendingPoolCollateralReentrancyTest -vv
forge test --match-contract LendingPoolConfigurationTest -vv
forge test --match-contract LendingPoolBorrowTest -vv
forge test --match-contract LendingPoolRepayTest -vv
forge test --match-contract LendingPoolLiquidityTest -vv
forge test --match-contract LendingPoolDebtFailureTest -vv
forge test --match-contract LendingPoolBorrowReentrancyTest -vv
forge test
```

첫 실행에는 의존성과 Solidity 컴파일러를 받기 위한 네트워크 연결이 필요하다.
테스트는 로컬 EVM에서 실행되며 지갑·RPC·실제 USDC가 필요하지 않다.

| 항목 | 고정한 값 |
| --- | --- |
| Solidity | `0.8.37` |
| EVM 대상 | `cancun` |
| forge-std | `v1.16.1`, `620536fa5277db4e3fd46772d5cbc1ea0696fb43` |
| OpenZeppelin Contracts | `v5.7.0`, `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` |
| Foundry (로컬·CI) | 공식 릴리스 `v1.7.0`, commit `f83bad912a9dba7bf0371def1e70bb1896048356` |

컴파일러·EVM 대상·import 연결은 [foundry.toml](foundry.toml)에 있다.
서브모듈의 Git 고정 커밋과 [foundry.lock](foundry.lock)에 같은 의존성 커밋을 기록한다.
다른 작업 사본에서도 `git submodule update --init --recursive`로 그 커밋을 복원한다.

forge-std는 현재 설치된 Foundry에서 사용할 조합으로 고정했다.
[v1.17.0 릴리스](https://github.com/foundry-rs/forge-std/releases/tag/v1.17.0)는 새 `Vm.Gas` 구조 때문에 Foundry v1.8.3 이상을 권고한다.
EVM 대상은 컴파일러 기본값 변화에 영향을 받지 않도록 명시했다.

## PR 자동 검사

[Foundry CI](.github/workflows/test.yml)는 main으로 향하는 PR의 생성·새 커밋·재개와
main에 커밋이 반영될 때 실행한다. Ubuntu 24.04에서 고정된 서브모듈을 복원하고
Foundry `v1.7.0`을 설치한 뒤 아래 검사를 순서대로 수행한다.

1. `forge fmt --check`: Solidity 형식 검사
2. `forge build`: 계약과 테스트 컴파일
3. `forge test -vv`: 전체 테스트 실행

형식·빌드·테스트 중 하나라도 실패하면 해당 검사 작업이 실패한다.
테스트는 `src/`의 실제 계약을 테스트 EVM에 배포해 호출하며, 지갑·RPC 비밀값은 필요하지 않다.
PR의 Checks 탭에서 단계별 결과와 실패한 테스트 이름을 확인할 수 있다.
CI 설정은 #13에서 추가한 기존 경로를 유지한다. #14의 GitHub 실행 결과는 해당 head를 게시한 뒤 별도로 확인한다.

## #13에서 익힌 동작: 부채 없이 WBTC를 맡기고 돌려받는다

#13은 **WBTC 보관과 반환 권리**를 기존 USDC 공급 지분과 분리한다.
아래는 #13에서 다룬 **부채0인 담보 보관 예시**다. 현재 생성자는 `new LendingPool(usdc, wbtc, priceSource)`로
두 자산과 가격 원천을 고정한다. #14에서 대출·상환을 연결했어도 담보 입금 자체로 USDC를 받거나 공급 지분이 생기지는 않는다.

먼저 [LendingPoolCollateralTest](test/LendingPoolCollateral.t.sol)의
`test_DepositMovesWBTCAndCreditsOnlyCaller`와 `test_PartialAndFullReturnNeedNoNewApproval`을 읽는다.
Alice가 100 USDC를 정상 공급하고 Bob에게 2 WBTC를 발행한 준비에서 시작한다.

| 실행 | Bob 지갑 WBTC | 풀 WBTC | Bob 담보 기록 | Alice USDC 권리 / 풀 USDC |
| --- | ---: | ---: | ---: | ---: |
| 입금 전 | 2 | 0 | 0 | 100 / 100 |
| Bob이 1 WBTC 승인 후 입금 | 1 | 1 | 1 | 100 / 100 |
| 새 승인 없이 0.4 WBTC 반환 | 1.4 | 0.6 | 0.6 | 100 / 100 |
| 남은 0.6 WBTC 반환 | 2 | 0 | 0 | 100 / 100 |

위 표는 사람이 읽는 수량이다. WBTC 1은 raw `100_000_000`이고 0.4는 `40_000_000`이다.
USDC 100도 raw `100_000_000`이지만 단위는 USDC6이며 서로 다른 자산이다.
정상 입금은 승인량 중 요청한 수량만 소비하고, 반환은 승인을 소비하지 않는다.
무제한 승인은 고정 OpenZeppelin ERC20 규칙대로 max가 유지된다.

### 실제 토큰 이동과 담보 기록은 어떻게 연결되나

[LendingPool](src/LendingPool.sol)의 `depositCollateral`은 0을 거절한 뒤 다음 순서로 실행한다.

```solidity
collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
_collateralBalances[msg.sender] += amount;
```

첫 줄이 승인된 WBTC를 실제로 받은 다음 두 번째 줄이 외부 호출자의 담보 기록을 늘린다.
`collateralOf(user)`는 그 기록을 원시 수량으로 돌려준다. 추가 입금도 덮어쓰지 않고 누적한다.
`withdrawCollateral`은 현재 0 → 본인 부채0 → 본인 기록 이하 순으로 검사한 뒤 기록을 먼저 줄이고 본인에게 전송한다.
아래 기존 담보 사례들은 부채가0인 전제로 이 반환 동작을 읽는다.
정확한 기록량의 반환은 허용하고, 기록이 없는 다른 사용자는 풀에 WBTC가 충분해도 반환받지 못한다.

전송 실패가 바깥 호출까지 전파되면 그 호출에서의 상태 변화는 모두 되돌아간다.
예를 들어 담보1에서0.4를 반환하려고 기록을0.6으로 줄였어도 전송이 실패하면 기록은1로 돌아온다.
이미 별도 거래로 끝난 approve나 과거 입금까지 취소한다는 의미는 아니다.

### 검토할 전체 흐름

| 흐름 | 동작·거절·보존 | 코드와 검증 |
| --- | --- | --- |
| 두 자산 배포 회귀 | 정상 가격 원천을 추가해 asset/collateralAsset을 입력 주소로 고정. 각 0/코드 없음·같은 계약 거절 | LendingPool 생성자, 기존 USDC 배포 거절 회귀와 담보 테스트의 Constructor 사례 |
| 본인 입금·추가 입금·조회 | 실제 수령 뒤 기록 증가. 양수 최소 단위1도 그대로 처리 | depositCollateral/collateralOf, 담보 테스트의 Deposit·AdditionalDeposits 사례 |
| 본인 부분/전액 반환 | 기록 선차감 뒤 본인에게 요청량 지급. 새 승인 없이 가능 | withdrawCollateral, PartialAndFullReturn·ReturnsOneSmallestUnit·ReturnKeeps 사례 |
| 0·승인·권리 거절 | 0을 우선 거절하고 승인 부족·본인 기록 초과의 정확한 인수 비교 | 담보 테스트의 Zero·InsufficientAllowance·AboveOwnRecord 사례 |
| 담보/USDC 분리·직접 유입 | 담보는 USDC 잔고/지분을, USDC 동작은 0이 아닌 담보 기록을 보존. 직접 송금/발행은 기록 권리를 만들지 않음 | USDCSupplyAndWithdrawalPreserveNonzeroCollateral·DirectTransfer·DirectMint 사례 |
| 전송·잔고·산술 실패 | 실제 이동 후 false/revert·잔고 부족·시험 장부 overflow에서 토큰/승인/기록 복구. 장애 해제 후 동일 재시도 | [담보 실패 테스트](test/LendingPoolCollateralFailure.t.sol), [WBTC 실패 대역](test/mocks/FailingMockWBTC.sol) |
| 담보/USDC의 공통 잠금 | 기존 네 진입점의 대표 교차 호출. 현재 대출·상환도 같은 잠금을 사용. 중첩 오류를 잡으면 바깥1회, 전파하면 바깥도 복구 | [교차 재진입 테스트](test/LendingPoolCollateralReentrancy.t.sol), [두 토큰 콜백 대역](test/mocks/CollateralReentrantMocks.sol) |

<details>
<summary>테스트의 준비·실행·검증문을 따라 읽기</summary>

공통 준비는 [CollateralTestBase](test/helpers/CollateralTestBase.sol)다.
새 풀에 Alice200 USDC 중100을 정상 공급하고 Bob2 WBTC를 발행한다.
`_usdcState`는 두 사용자/풀 잔고·승인·발행량·인정자산/총·개인 지분·환산권리12값이다.
`_state`는 여기에 WBTC 잔고3·승인2·발행량1·개인 담보2를 더한20값을 비교한다.
콜백 토큰 자신의 양 자산 잔고·승인·공급 지분/권리·담보7값도 별도로 관측한다.
정상 이벤트는 풀 emitter·외부 호출자·이번 요청량·정확히1회인지 확인하고 토큰 Transfer와 구분한다.

| 테스트 묶음 | 준비와 실행 | 실제 확인하는 결과 |
| --- | --- | --- |
| 첫 입금·추가 입금·사용자 분리 | Bob1 입금 뒤0.2 추가, Alice는 별도0.3 입금 | Bob 기록1.2·Alice0.3, 풀1.5·발행량2.3 WBTC. 추가 이벤트는 이번0.2, USDC12값 유지 |
| 부분/전액·최소 단위·승인 정책 | Bob1 입금 뒤0.4/0.6 반환. 별도 raw1 왕복, 유한/무제한 승인 대조 | 지갑/풀/기록을 위 고정표와 비교. 입금은 유한 승인 소비·max 유지, 반환은 승인 유지 |
| 배포·0·권리·승인 거절 | 다른 입력은 정상으로 두고 0/코드 없는 담보·같은 계약, 0 요청·기록보다1 많은 반환·승인1 부족을 각각 호출 | 각 오류와 전체 인수, 호출 직전20값 보존·풀 성공 이벤트0회. 권리 부족은 충분한 풀 WBTC를 별도로 준비 |
| 양방향 장부 분리 | Alice도 담보를 가진 채 USDC10 추가 공급 후10 출금 | 중간 USDC 권리110·마지막100. 각 동작에서0이 아닌 Alice/Bob 담보·WBTC잔고/승인/발행량은 유지 |
| 직접 transfer / mint | 정상 담보1 뒤 풀에0.2 직접 유입, 정상1 전액 반환 | 본인·타인 기록 불변, 기록0 뒤 풀0.2만 남음. 추가1 raw 반환은 권리 오류. transfer의 발행량 유지와 mint의 증가를 별도 비교 |
| raw false 대조2개 | 풀을 거치지 않고 실패 대역의 실제 transferFrom/transfer를 직접 실행 | false여도 잔고 이동이 실제 남고 transferFrom만 유한 승인 소비. 담보 기록은0 |
| 풀 실패4종과 재시도 | Bob담보1·Alice0.3, 양 자산 승인 준비. 입금0.2 또는 반환0.4의 전송 뒤 false/revert, 장애를 끈 뒤 같은 요청 재시도 | SafeERC20 오류/원본 오류·20값 복구. 재시도는 요청1회·이벤트1회; 입금 승인0.8→0.6, 반환 승인0.8 유지 |
| Bob 잔고 부족 |1.39 발행 후0.4 입금, 새 승인1로 추가1 입금 시도 | 잔고0.99의 정확한 오류, 승인1·기존 담보0.4 복구 |
| 풀 실제 잔고 부족·복원 | 정상1 입금 후 시험에서만 풀 현금을0.5로 줄임.0.6 반환 실패 뒤0.5 재발행하고 재시도 | 조정 발행량1.5와 기존 기록1 보존. 복원 후 Bob1.6·풀/기록0.4·발행량2 |
| 담보 합산 overflow | 시험 전용 하네스에서 Bob 기록max, 잔고/승인 raw1로 입금 | 실제 전송 뒤 Panic(0x11), 토큰·승인·기록·USDC20값 복구. 일반 풀에는 장부 setter 없음 |
| 공통 잠금8경로 | 담보 입금/반환끼리와 USDC 공급/출금의 대표 양방향, 자기 경로 재호출 | 토큰 주소의 정상 공급/담보 권리1·각 잔고2·유한 승인1을 준비. 중첩 직전에도 충분한 재원인지 확인하고 정확한 잠금 오류·바깥1회 검증 |
| 전파된 잠금 오류2개 | 실제 담보 입금/반환 전송 뒤 중첩 오류를 바깥에 전파, 콜백을 끈 뒤 같은 요청 재시도 | 20값·토큰 자신의7값·콜백 설정/관측 저장까지 복구. 정상 재시도 성공과 잠금 해제 확인 |

담보 입금 콜백은 기록 증가 전, 반환 콜백은 기록 선차감 후를 관측한다.
기존1에서0.4 반환 중 관측 기록은0.6이다. 중첩 호출자는 Bob이 아니라 토큰 계약 자신이다.
이 권리와 잔고를 정상 준비해 잔고 부족 오류를 재진입 방어의 근거로 쓰지 않는다.
실패 경로는 풀 성공 이벤트가 발생하기 전 중단된다. 수집된 토큰 내부 로그만으로 실제 실패 거래의 영수증 로그를 판단하지 않는다.
기존 USDC 테스트·지분 하네스의 생성자는 #14에서 정상 가격 원천을 받는 세 인자로 이행했다. 기존 담보 회귀의 준비값은 유지한다.
이20값 snapshot에는 부채가 없으므로, 대출·상환 복구는 위 BorrowTestBase의 부채 포함 snapshot으로 별도 관측한다.

</details>

#13 당시 담보 테스트는 정상/거절18개·실패9개·재진입10개였다.
당시 기존104개와 함께 전체141개가 통과했고 실패/skip은0개이며 형식 검사·빌드·diff 공백 검사도 통과했다.
이는 #13 작업본의 실행 근거다. 현재 #14의 최종 검사 수나 사용자 이해·독립 리뷰 완료로 재사용하지 않는다.

현재 생성자는 주소/코드 존재/서로 다름에 더해 실제 자산 정밀도6/8·가격8을 검사한다. 잘못된 연결은 배포 단계에서 거절한다.
임의 ERC20·세금/리베이스 토큰·실제 BTC 보관을 지원한다고 보장하지 않는다.
위 #13 예시는 무부채 담보 보관의 회귀이며, 현재 #14의 대출·상환과 부채0 반환 조건은 앞 절에서 함께 읽는다.
실제 Chainlink·시장가격·배포는 이번 검증 범위에 포함되지 않는다.

## Mock 가격 계산기를 읽는 순서

#12는 가격과 갱신시각을 검증한 뒤 **WBTC 담보의 USDC 가치와 그 70% 한도**를 계산한다.
이 계산기는 상태를 저장하지 않는 순수 계산으로 유지한다. 현재 #14의 `LendingPool.borrow`가
고정 원천에서 읽은 가격·갱신시각과 본인 담보를 `maxDebtDown`에 전달한다.
아래 가격은 테스트 입력이며 실제 시장가격이 아니다.

첫 예시는 **1 WBTC·가격 100 USDC → 가치 100 USDC·한도 70 USDC**다.
테스트는 [CollateralMathTest](test/CollateralMath.t.sol)의 `test_OneWBTCAtOneHundredUSDC`부터 읽는다.

| 값 | 사람이 읽는 수량 | 함수에 전달하는 정수 |
| --- | --- | ---: |
| WBTC 수량 | 1 WBTC, 소수점 8자리 | `100_000_000` |
| 가격 | 1 WBTC당 100 USDC, 소수점 8자리 직접호가 | `10_000_000_000` |
| 가치 / 한도 | 100 / 70 USDC, 소수점 6자리 | `100_000_000` / `70_000_000` |

갱신시각·현재시각을 각각 `10_000`초로 준비한다. [CollateralMath](src/libraries/CollateralMath.sol)는
가격 → 갱신시각 → 지난 시간 순으로 검사하고, 수량과 가격을 곱해 `10^10`으로 나눈다.
8자리 두 개를 곱한 16자리에서 USDC 6자리를 남기기 위한 배율이다.
그 뒤 먼저 내린 가치에 `7000 / 10000`을 적용해 다시 내린다.
두 곱셈은 기존 고정 OpenZeppelin `Math.mulDiv`를 사용하므로 중간 곱이 크더라도 최종 결과가 맞으면 계산할 수 있다.

### 왜 두 번 내리나

이 명세는 **먼저 USDC 최소 단위로 확정한 담보 가치에 70%를 적용**한다.
WBTC 최소 단위 3과 가격 150 USDC를 준비하면 다음 차이가 드러난다.
아래 숫자는 USDC 개수가 아니라 **최소 단위**이며, 최소 단위 1은 0.000001 USDC다.

| 단계 | 계산 | 반환하는 정수 |
| --- | --- | ---: |
| 담보 가치 | WBTC raw 3 × 가격 raw 15,000,000,000 ÷ 10,000,000,000 = 4.5 | 4 |
| 대출 한도 | 먼저 내린 4 × 70% = 2.8 | 2 |

계산을 합쳐 마지막에만 내리면 `4.5 × 70% = 3.15 → 3`이어서 결과가 달라진다.
두 번 내리는 것이 모든 프로토콜의 필수 규칙이라는 뜻은 아니다. 이번 구현은 이슈의 두 단계 계약을 유지하며,
`test_ValueAndLimitRoundDownInTwoSteps`가 결과 4와 2를 각각 직접 비교한다.
100 USDC처럼 나누어떨어지는 예시에서는 두 방식의 차이가 없다.

### 계산과 가격 원천의 역할

| 역할 | 입력 → 결과 | 위치 |
| --- | --- | --- |
| 원시 가격 계약 | metadata8과 부호 있는 가격·갱신시각 반환 | [ICollateralPriceSource](src/interfaces/ICollateralPriceSource.sol) |
| 테스트 가격 준비 | 가격만/시각만 독립 변경, 잘못된 값도 그대로 반환 | [MockCollateralPriceSource](test/mocks/MockCollateralPriceSource.sol) |
| 순수 계산 | 원시 가격·시각 검증 → 가치 내림 → 70% 한도 내림 | [CollateralMath](src/libraries/CollateralMath.sol)의 `collateralValueDown`, `maxDebtDown` |
| 시험 호출 경계 | 원천을 한 번 읽어 반환값과 현재시각을 계산기에 전달 | [CollateralPriceSourceTest](test/CollateralPriceSource.t.sol)의 테스트 전용 harness |
| 원천 장애 | 조회 즉시 `PriceSourceUnavailable()` 발생 | [RevertingCollateralPriceSource](test/mocks/RevertingCollateralPriceSource.sol) |

계산기는 `internal pure`이며 토큰·가격 원천·`block.timestamp`를 직접 읽지 않는다.
#12 테스트에서는 원천을 읽는 시험용 wrapper가 실제 현재시각을 전달한다. wrapper는 생산 풀 API가 아니다.
현재 풀의 `borrow`도 같은 계산기에 가격·갱신시각·`block.timestamp`를 전달한다.
Mock 원천이 음수나 미래시각을 반환하는 것은 정상 동작이며, 그 값을 평가에 사용할 수 있는지는 계산기가 거절한다.
가격 설정 시 갱신시각을 자동으로 현재시각으로 바꿔 오래된 가격을 숨기지 않는다.

### 잘못된 입력은 계산 전에 거절한다

| 순서 | 입력 | 관측하는 오류/결과 |
| --- | --- | --- |
| 1 | 가격 0·음수·int256 최솟값 | `InvalidPrice(입력 가격)` |
| 2 | 갱신시각 0 또는 현재시각보다 미래 | `InvalidPriceTimestamp(갱신시각, 현재시각)` |
| 3 | 갱신 후 정확히 3600초 / 3601초 | 계산 허용 / `StalePrice(갱신시각, 현재시각)` |
| 4 | 각 단계의 최종 정수 결과가 uint256 범위 초과 | 정확한 `Panic(0x11)` 전파 |

담보가 0이어도 위 가격·시각 검사를 생략하지 않는다. 유효한 입력의 담보 0은 가치·한도가 모두 0이다.
양수를 확인한 뒤 가격을 uint256으로 변환하고, 미래시각을 거절한 뒤 경과시간을 뺀다.
`maxDebtDown`은 먼저 가치 계산을 호출하므로 동일한 오류 순서와 첫 단계 범위 제한을 유지한다.
실패는 오류를 잡아 0 한도로 바꾸지 않고 호출자에게 전파하며, 계산기 자체는 상태를 바꾸지 않는다.

<details>
<summary>#12 테스트의 준비·실행·실제 확인</summary>

[CollateralMathTest](test/CollateralMath.t.sol)는 매 테스트 새 외부 harness를 준비한다.
정상 값은 이슈의 고정 정수와 비교하고, 오류는 `vm.expectRevert` 다음에 harness의 external 메서드를 실제 호출한다.
같은 기대 오류를 가치·한도 두 함수에서 각각 전체 인수까지 비교한다.

| 테스트 묶음 | 준비·실행 | 실제 확인 |
| --- | --- | --- |
| 1 WBTC·0.5 WBTC·최소 단위 3·담보 0 | 유효한 가격·시각, 고정 수량 입력 | 가치/한도 각각 100m/70m, 50m/35m, 4/2, 0/0 |
| 비양수 가격·오류 순서 | 가격 0/-1/int256.min, 담보0+가격0+시각0 포함 | 각 가격의 `InvalidPrice`, 담보0도 가격 오류를 우선 |
| 시간과 우선순위 | 현재10000, 갱신6400/6399/0/10001, 담보0도 별도 준비 | 3600초 허용·3601초 거절, 0/미래시각은 timestamp 오류. 두 함수 모두 같은 인수 |
| 큰 중간 곱과 최종 범위 | 담보 uint256.max, 가격10,000,000,000 / 10,000,000,001 | 첫 입력의 가치 max와 고정 70% 한도 성공, 두 번째는 가치부터 범위 초과해 두 함수 모두 Panic(0x11) |

[CollateralPriceSourceTest](test/CollateralPriceSource.t.sol)는 다음 원천/연결 사례를 별도로 확인한다.

| 준비·실행 | 실제 확인 |
| --- | --- |
| 생성자에서 가격10b·시각6400 주입 후 interface 조회 | 주입한 두 정수 그대로 반환 |
| 가격만15b로 변경 / 이어 시각만0으로 변경 | 바꾸지 않은 나머지 값 보존 |
| 생성자·setter의 잘못된 원시값 표 | (0,0), (-1,6400), (int256.min,10001), (15b,10001)을 현재10000에서도 그대로 반환 |
| 100·150 USDC 가격의 원천을 wrapper로 각각 조회해 1 WBTC 한도 계산 | 70m·105m, 각 원천의 실제 `latestPrice()` 호출 대상·calldata·정확히1회 확인 |
| 오래된 시각6399의 원천을 wrapper에 연결 | StalePrice(6399,10000), 원시 가격·시각 보존. 소비자가 시각을 덮어쓰지 않음 |
| 조회 시 오류를 내는 원천을 wrapper에 연결 | 실제 조회와 정확한 원천 오류 전파. 0 반환이나 오류 삼킴으로 통과하지 않음 |

이 검사는 로컬 원천 모형·계산·시험 wrapper의 연결이다. 실제 Chainlink·시장가격·RPC를 호출하지 않는다.
토큰 이동·승인·부채·담보 기록은 없고, 외부 연동이나 가격 조회의 재진입 방어를 검증한 것으로 확대하지 않는다.
#12의 wrapper 검사와 #14의 실제 풀 대출 검사는 별도 근거다. 후자는 위 대출 테스트에서 토큰 이동·담보·부채·공급자 장부까지 관측한다.

</details>

## MockWBTC를 읽는 순서

#11은 **소수점 8자리 토큰과 테스트 잔고 발행**만 추가한다.
실제 BTC를 보관하거나 BTC와 교환하는 기능은 없다. LendingPool은 USDC 공급과 WBTC 담보를 분리한다.
WBTC 담보 입금·반환은 [#13](https://github.com/0Chord/lending-protocol/issues/13)에서 연결했다.

먼저 [MockWBTC](src/mocks/MockWBTC.sol)의 `decimals()`를 읽고,
[MockWBTCTest](test/MockWBTC.t.sol)의 `test_DecimalsAreEight`에서 고정값 `8`과 비교하는 검증문을 확인한다.
같은 정수 `100_000_000`도 MockWBTC에서는 **1 WBTC**, 기존 MockUSDC에서는 **100 USDC**다.
소수점 설정은 표시 방법만 정하며, `mint` 입력이나 잔고를 자동으로 환산하지 않는다.

다음은 새 토큰에서 Alice에게 1 WBTC를 발행하는 흐름이다.

```solidity
function mint(address to, uint256 amount) external {
    _mint(to, amount);
}
```

호출자가 `mint(Alice, 100_000_000)`을 실행하면 상속한 ERC20의 `_mint`가 수령자를 검사한다.
정상 주소라면 Alice 잔고와 총발행량을 각각 `100_000_000` 늘리고,
0 주소에서 Alice에게 발행했다는 `Transfer` 이벤트를 남긴다. Bob의 잔고는 그대로다.
이 함수는 누구나 호출하는 테스트 잔고 준비 수단이며, 승인·실제 BTC 입금·풀 예치 기록과는 별개다.

각 테스트의 `setUp()`은 새 토큰을 배포하므로 다른 테스트의 잔고를 이어받지 않는다.
Alice와 Bob은 테스트용 주소다. 아래 기대값은 모두 이슈에서 정한 **WBTC 정수 최소 단위**다.

| 테스트 | 준비 → 실행 | 실제 비교하는 결과 |
| --- | --- | --- |
| `test_DecimalsAreEight` | 새 토큰 → `decimals()` 조회 | `8` |
| `test_MintCreditsOnlyRecipientAndIncreasesTotalSupply` | Alice·Bob·총발행량 0 → Alice에게 `100_000_000` 발행 | Alice `100_000_000`, Bob `0`, 총발행량 `100_000_000`. 토큰 주소의 Transfer가 정확히 1회이며 from 0·to Alice·수량도 일치 |
| `test_MintAddsToExistingBalances` | Alice `25_000_000`·Bob `7_000_000` → Alice에게 `100_000_000` 추가 | Alice `125_000_000`, Bob `7_000_000`, 총발행량 `132_000_000` |
| `test_MintToZeroAddressRevertsWithoutChangingSupply` | Alice `25_000_000` → 0 주소에 `100_000_000` 발행 시도 | `ERC20InvalidReceiver(address(0))`. Alice `25_000_000`, Bob·0 주소 `0`, 총발행량 `25_000_000` 유지, 실패 요청의 로그 0개 |
| `test_NonDeployerCanMintTestBalance` | 새 토큰 → 배포자가 아닌 Bob이 Alice에게 `50_000_000` 발행 | Alice `50_000_000`, Bob `0`, 총발행량 `50_000_000` |

0 주소 발행은 `_mint`가 장부를 바꾸기 전에 거절한다. 예외를 잡고 성공으로 진행하지 않는다.
이 실패 시험은 기존 값 보존을 확인하며, 이미 이동한 토큰의 복구를 시험하는 것은 아니다.
성공 테스트는 실제 로그의 발행 주소·서명·수령자·수량·횟수를 비교한다.
테스트에서 쓰는 Bob 호출자 설정은 새 토큰을 발행하는 것이 아니라 호출 주체를 바꾼다.

위 검사는 로컬 Mock의 단위·발행 연결을 확인한다. 실제 WBTC의 BTC 준비금·발행 권한·교환 서비스 연동이나
이 #11 토큰 자체의 테스트만으로 담보·가격·대출 기능을 검증하지 않는다. 기존 MockUSDC·풀·지분 테스트도 별도로 유지한다.

## 먼저 읽을 동작: 지분을 저장하고 예치금을 계산한다

#7 계산기를 실제 공급·출금에 연결했다. 저장하는 값은 **내 지분 수량**, 예치금 조회가 보여주는 값은 **그 지분의 USDC 가치**다.
구현은 [LendingPool](src/LendingPool.sol)의 `shares`, `supply`, `withdraw`, `deposits`다.

```solidity
mapping(address => uint256) public shares;

function deposits(address user) public view returns (uint256) {
    return ShareMath.toAssetsDown(shares[user], _accountedAssets, totalShares);
}
```

공급하면 계산한 지분을 더하고, 출금하면 필요한 지분을 줄인다. `deposits`는 저장된 지분을 읽어 USDC로 환산하며 상태를 바꾸지 않는다.
예를 들어 내 지분3개·전체6개·인정자산10 USDC라면 조회 결과는5 USDC다.
인정자산은 정상 공급·출금으로 기록한 금액이며, 실제 풀 현금과 구분한다. 직접 송금은 현금만 늘린다.

먼저 새 풀에서 Alice200 → 공급100 → 출금40을 읽는다. 첫 비율은1:1이고 아래 표는 사람이 읽는 USDC/지분 단위다.

| 확인할 값 | 공급 후 | 출금 후 |
| --- | ---: | ---: |
| Alice 토큰 | 100 USDC | 140 USDC |
| 풀 현금 | 100 USDC | 60 USDC |
| Alice 지분 / 전체 지분 | 각각100개 | 각각60개 |
| 인정자산 / 조회한 Alice 예치금 | 각각100 USDC | 각각60 USDC |

[첫 출금 테스트](test/LendingPool.t.sol)의 `test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval`은 두 시점의 자산·총지분·Alice 지분과 토큰·승인0·총발행량200·Bob 상태0을 직접 비교한다.
첫 공급 테스트도 같은 기록과 USDC 성공 이벤트1회를 확인한다. `amount`와 이벤트 금액은 계속 USDC다.
비율이 다른 상황은 [새 연결 테스트](test/LendingPoolShares.t.sol)에서만 준비하며, 현재 풀에 수익·손실을 인정하는 기능은 없다.

아래 공급·출금의 기존 예시는 부채0의 첫1:1 상태다. 그 예시의 예치금은 `deposits`가 계산한 USDC 값이며 별도 금액 원장을 저장하는 뜻이 아니다.
다른 비율의 반올림·거절·복구는 뒤의 접이식 테스트 안내에서 필요한 사례를 읽는다.

## MockUSDC를 읽는 순서

| 흐름 | 시작과 결과 | 코드·검증 위치 |
| --- | --- | --- |
| 소수점 설정 | `decimals()` 조회 → `6` | [MockUSDC](src/mocks/MockUSDC.sol), `test_DecimalsAreSix` |
| 테스트 토큰 지급 | `mint(Alice, 100_000_000)` → Alice 잔고·총발행량 증가 | `mint`, `test_MintCreditsOnlyRecipientAndIncreasesTotalSupply` |
| 추가 지급 | 기존 잔고에 수량을 더하고 다른 주소의 잔고 유지 | `test_MintAddsToExistingBalances` |
| 잘못된 수령자 | 0 주소로 발행 → 오류, 기존 잔고·총발행량 유지 | `test_MintToZeroAddressRevertsWithoutChangingSupply` |

테스트는 모두 [test/MockUSDC.t.sol](test/MockUSDC.t.sol)에 있다.
`setUp()`은 각 테스트마다 새 MockUSDC를 배포한다. 테스트 사이에 잔고를 공유하지 않는다.
`ALICE`와 `BOB`은 테스트용 주소이며 별도 지갑은 필요하지 않다.

### 첫 단위: 소수점 6자리

새 토큰에서 `decimals()`를 조회하고 그 반환값이 `6`인지 직접 비교한다.
MockUSDC는 ERC20의 설정을 다음과 같이 바꾼다.

```solidity
function decimals() public pure override returns (uint8) {
    return 6;
}
```

이 함수는 표시할 소수점 자릿수를 반환한다. 잔고를 자동으로 곱하거나 나누지 않는다.
따라서 100 USDC 지급 시 호출자가 `100_000_000`이라는 정수 최소 단위를 전달한다.

### 지급 테스트의 준비·실행·확인

| 테스트 | 준비 | 실행 | 실제 확인하는 결과 |
| --- | --- | --- | --- |
| `test_MintCreditsOnlyRecipientAndIncreasesTotalSupply` | 새 토큰, Alice 잔고·총발행량 0 | Alice에게 `100_000_000` 발행 | Alice `100_000_000`, Bob `0`, 총발행량 `100_000_000` |
| `test_MintAddsToExistingBalances` | Alice `25_000_000`, Bob `7_000_000` 지급 | Alice에게 `100_000_000` 추가 발행 | Alice `125_000_000`, Bob `7_000_000`, 총발행량 `132_000_000` |
| `test_MintToZeroAddressRevertsWithoutChangingSupply` | Alice에게 `25_000_000` 지급 | 0 주소에 `100_000_000` 발행 시도 | `ERC20InvalidReceiver(address(0))` 오류, Alice `25_000_000`, 0 주소 `0`, 총발행량 `25_000_000` 유지 |

기대 금액은 명세의 고정 예시에서 정했다. 실제 함수의 반환값이나 `decimals()`로 예상 금액을 다시 계산하지 않는다.
지급 함수의 핵심은 OpenZeppelin ERC20의 `_mint(to, amount)` 호출이다.
정상 호출에서는 수령자의 잔고와 총발행량이 늘어난다. 0 주소는 ERC20이 상태 변경 전에 거절한다.

## 공급 기능을 읽는 순서

공급은 새 토큰을 발행하지 않는다. Alice가 가진 토큰을 풀로 옮기고 그 사람의 공급 권리를 별도 장부에 더한다.
구현은 [LendingPool](src/LendingPool.sol), 테스트는 [LendingPoolTest](test/LendingPool.t.sol)에 있다.
먼저 아래 정상 공급 하나를 읽고, 나머지 흐름은 표에서 필요한 부분으로 내려간다.

### Alice의 토큰 이동과 예치 기록은 같은 공급 호출에 묶인다

준비: 새 토큰·풀을 만들고 Alice에게만 200 USDC를 발행한다. Alice는 풀에 100 USDC의 유한 승인을 준다.
`approve`는 토큰 이동이나 예치 기록 증가를 일으키지 않는다. 그다음 Alice가 `supply(100_000_000)`을 호출한다.

| 관측값 | 공급 직전 | 공급 성공 후 |
| --- | ---: | ---: |
| Alice 토큰 | 200 USDC | 100 USDC |
| 풀 토큰 | 0 | 100 USDC |
| Alice 예치 기록 | 0 | 100 USDC |
| Alice → 풀 승인량 | 100 USDC | 0 |
| 총발행량 | 200 USDC | 200 USDC |
| Bob 토큰·예치 기록 | 각각 0 | 각각 0 |

실제 핵심 코드는 다음과 같다. 100 USDC의 정수 최소 단위는 `100_000_000`이다.

```solidity
function supply(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();
    uint256 mintedShares = ShareMath.toSharesDown(amount, _accountedAssets, totalShares);
    if (mintedShares == 0) revert ZeroShares();
    asset.safeTransferFrom(msg.sender, address(this), amount);
    _accountedAssets += amount;
    totalShares += mintedShares;
    shares[msg.sender] += mintedShares;
    emit Supplied(msg.sender, amount);
}
```

Alice의 호출에서 `msg.sender`는 Alice이고 `address(this)`는 풀이다.
토큰 계약에서는 풀이 승인 사용 주체(spender)로 호출한다. Alice가 풀에 준 승인을 사용해 Alice의 잔고를 줄이고 풀의 잔고를 늘린다.
공급 전 비율로 지분을 계산하고 전송 성공 후 인정자산에 USDC 금액, 총지분·Alice 지분에 계산한 지분을 더한다.
`deposits(Alice)`는 그 기록의 환산 결과다. 내부 지분은 새 ERC20이나 토큰 발행량이 아니다.

`test_SupplyMovesTokensAndCreditsOnlyCaller`는 위 표의 값을 실제 검증문으로 비교한다.
`_assertOneSupplyEvent`는 토큰의 Transfer 로그와 구분해 풀에서 발생한 `Supplied(Alice, 100_000_000)`가 정확히 한 번인지 확인한다.

### 공급이 실패하면 직전 상태가 남는다

승인과 공급은 사용자의 별도 거래다. 공급 실패가 이미 성공한 approve를 취소하는 것은 아니다.
실패한 supply 안에서 차감한 승인량은 supply 직전 값으로 돌아간다.

예를 들어 잔고 99·승인 100에서 공급 100을 요청하면, ERC20은 승인을 먼저 차감한 뒤 잔고 부족 오류를 낸다.
그 오류가 전파되어 해당 공급의 변경을 복구하므로 잔고 99·승인 100과 기존 예치 기록이 유지된다.
풀은 토큰 오류를 잡고 성공으로 진행하지 않는다. false 반환은 SafeERC20이 오류로 바꾸고, 토큰의 명시적 오류는 그대로 전파한다.

전송 실패 테스트는 먼저 40 USDC 공급을 완료하고 새 승인 100을 준 상태에서 시작한다.
[실패 토큰](test/mocks/FailingMockUSDC.sol)은 실제 전송·승인 차감 후 false를 반환하거나 지정 오류를 낸다.
공급 실패 뒤 Alice 토큰 160·풀 토큰 40·Alice 예치 40·승인 100이 유지되는지 검사한다.
`test_FalseTokenControlActuallyMovesTokensBeforeReturningFalse`는 풀 밖에서 모형을 직접 호출해 false와 실제 잔고 변경이 함께 발생함을 대조한다.
따라서 아무것도 하지 않는 모형을 보고 복구를 검증했다고 해석하지 않는다.

### 새 테스트의 준비·실행·실제 확인

공통 `setUp()`은 각 테스트마다 새 토큰·풀과 Alice의 200 USDC만 준비한다. 서로 다른 테스트의 상태를 공유하지 않는다.
`_approveAndSupply`는 지정한 사용자의 승인과 공급을 준비하는 함수다.
`_snapshot`과 `_assertStateUnchanged`는 검사할 호출 직전의 Alice·Bob 토큰, 풀 토큰, 양쪽 예치 기록·승인, 총발행량을 비교한다.
실패 보존 검사는 기존8개에 인정자산·총지분·두 사용자 지분을 더한12개 값을 확인한다.
아래 숫자는 별도 표시가 없으면 USDC이며, 실제 입력과 기대값은 고정한 정수 최소 단위로 작성했다.

| 테스트 | 준비 → 실행 | 실제 확인 |
| --- | --- | --- |
| `test_SupplyMovesTokensAndCreditsOnlyCaller` | Alice 200·승인 100 → 공급 100 | 위 표의 7개 관측값과 풀의 공급 이벤트 1회 |
| `test_ConstructorFixesAsset` | 토큰 주소로 풀 생성 → 자산 조회 | 설정한 토큰 주소와 같음 |
| `test_ConstructorRejectsZeroAsset` | 0 주소 → 풀 생성 시도 | `InvalidAsset(0)` 오류 |
| `test_ConstructorRejectsAssetWithoutCode` | 코드 없는 Alice 주소 → 풀 생성 시도 | `InvalidAsset(Alice)` 오류 |
| `test_AdditionalSupplyAddsToExistingDeposit` | 100 공급 → 추가 승인·공급 20 | Alice 80·풀/예치 120·승인 0·발행량 200·Bob 예치 0, 두 번째 공급 이벤트는 누적 120이 아닌 요청 20으로 1회 |
| `test_DifferentUsersKeepSeparateDeposits` | Alice 200·Bob 30 → Alice 100, Bob 30 공급 | 예치 각각 100/30·풀 130, Alice 토큰 100·Bob 0, 양쪽 승인 0·발행량 230 |
| `test_SupplyAcceptsOneSmallestUnit` | Alice 200 → 최소 단위 1 승인·공급 | Alice 199_999_999·풀/예치 1·승인 0·발행량 200_000_000 |
| `test_ZeroSupplyRevertsWithoutChangingState` | 기존 예치 40·새 승인 100 → 공급 0 | `ZeroAmount()`와 호출 직전12개 상태 보존 |
| `test_InsufficientAllowanceRevertsWithoutChangingState` | 기존 예치 40, Alice 토큰을 200으로 준비·승인 99 → 공급 100 | `ERC20InsufficientAllowance(pool, 99, 100)`와 직전 상태 보존 |
| `test_InsufficientBalanceRestoresSpentAllowanceAndExistingDeposit` | 기존 공급 101 후 잔고 99·승인 100 → 공급 100 | `ERC20InsufficientBalance(Alice, 99, 100)`, 승인 100·기존 예치 101을 포함한 직전 상태 보존 |
| `test_FalseTokenControlActuallyMovesTokensBeforeReturningFalse` | 장애 토큰 Alice 200·테스트 주소에 승인 100 → Bob에게 직접 전송 | 반환 false, Alice/Bob 각각 100·승인 0·발행량 200. 풀 공급을 거치지 않는 모형 대조 |
| `test_FalseTransferRollsBackTokenChangesAndKeepsExistingDeposit` | 기존 공급 40·승인 100 → 전송 뒤 false | 정확한 `SafeERC20FailedOperation(token)`과 직전 상태 보존, 기존 예치 40 |
| `test_RevertingTransferBubblesExactErrorAndPreservesState` | 기존 공급 40·승인 100 → 전송 중 지정 오류 | `InjectedTransferFailure()` 전파와 직전 상태 보존 |
| `test_DirectTransferDoesNotCreateDepositOrInflateLaterSupply` | Alice 200 → 풀로 직접 전송 10 → 공급 100 | 직접 전송 직후 예치 0·풀 10·공급 이벤트 없음, 이후 Alice 90·풀 110·예치 100·발행량 200 |
| `test_DirectMintDoesNotChangeExistingDeposits` | 기존 공급 40 → 풀에 직접 발행 10 | Alice 토큰 160·풀 50·예치 40·Bob 예치 0·발행량 210·공급 이벤트 없음 |
| `test_ReentryIsRejectedWhileOuterSupplySucceedsOnce` | 콜백 토큰에 자체 잔고·승인 최소 단위 1, Alice 200·승인 100 → 공급 100 중 재호출 | 콜백 시도·정확한 guard 오류·바깥 공급만 1회 성공, 토큰 주소의 잔고·승인 1·예치 0 유지 |

전송 전 공급→공급 모형은 [ReentrantMockUSDC](test/mocks/ReentrantMockUSDC.sol)다. 전송 후 다른 경로·장부 관측은 아래의 Cross 모형으로 구분한다.
토큰이 중첩 호출하면 그 호출자는 Alice가 아니라 토큰 주소다. 충분한 자체 잔고·승인과 양수 금액을 준비해 승인·잔고 부족으로 인한 거짓 통과를 막는다.
중첩 오류를 잡아 바깥 전송을 계속하므로 테스트는 콜백 실행과 오류를 조회할 수 있다.
재진입 실패와 별도로 Alice의 토큰/예치 100·풀 토큰 100·승인 0·Bob 상태 0, 총발행량 200_000_001, 공급 이벤트 1회를 확인한다.
추가된 최소 단위 1은 준비에서 발행한 토큰이며 공급이 새로 발행한 수량이 아니다.

## 출금 기능을 읽는 순서

출금은 요청한 USDC를 본인에게 돌려주면서 그 금액에 필요한 지분을 올림해 차감한다.
제품 코드는 [LendingPool.withdraw](src/LendingPool.sol#L236), 검증 코드는 [LendingPoolTest](test/LendingPool.t.sol)에 있다.
먼저 부채0인 첫 40 출금과 실패 복구를 읽고, 나머지 경계는 아래 테스트 표로 이어간다.
현재 출금의 현금 한도는 대출과 같은 `availableLiquidity()`이며, 아래 기존 무부채·무잉여 예시에서는 실제 현금과 같다.

| 흐름 | 시작 → 결과 |
| --- | --- |
| 정상 출금 | 본인 예치·사용 가능 현금이 충분함 → 기록 차감·토큰 반환·출금 이벤트 1회 |
| 요청 거절 | 0 → 본인 예치 부족 → 사용 가능 현금 부족 순으로 검사 → 정확한 오류, 상태 보존 |
| 토큰 실패 | 기록을 줄인 뒤 transfer에서 false/revert → 해당 출금의 모든 변경 복구 |
| 중첩 호출 | 전송 중 supply/withdraw 재호출 → 공통 잠금으로 중첩 동작 거절 |
| 직접 유입 | 풀에 직접 transfer/mint → 현금만 증가, 출금 권리는 생기지 않음 |

### 첫 40 출금: 새 승인이 없어도 토큰을 돌려받는다

준비(Given): Alice 초기 토큰 200에서 정상 승인·공급 100을 마친다. Alice 토큰·예치·풀 현금은 각각 100이고 공급 승인은 0이다.
실행(When): Alice가 새 approve 없이 `withdraw(40_000_000)`을 호출한다.
확인(Then): `test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval`이 다음 고정값을 비교한다.

| 관측값 | 출금 직전 | 성공 후 |
| --- | ---: | ---: |
| Alice 토큰 | 100 | 140 |
| Alice 예치 | 100 | 60 |
| 풀 토큰 | 100 | 60 |
| Alice → 풀 승인 | 0 | 0 |
| 총발행량 | 200 | 200 |
| Bob 토큰·예치 | 각각 0 | 각각 0 |

표는 USDC 단위이며 실제 테스트에서는 6자리 정수 최소 단위를 사용한다.
풀 emitter·출금 서명·indexed Alice·요청액 40·정확히 1회도 별도로 검사한다. 준비 공급의 이벤트는 로그 기록 전에 끝낸다.

```solidity
function withdraw(uint256 amount) external nonReentrant {
    if (amount == 0) revert ZeroAmount();
    uint256 deposited = deposits(msg.sender);
    if (amount > deposited) revert InsufficientDeposit(deposited, amount);
    uint256 available = availableLiquidity();
    if (amount > available) revert InsufficientLiquidity(available, amount);

    uint256 burnedShares = ShareMath.toSharesUp(amount, _accountedAssets, totalShares);
    uint256 remainingAssets = _accountedAssets - amount;
    if (burnedShares == totalShares && remainingAssets != 0) revert ResidualAssets(remainingAssets);
    _accountedAssets = remainingAssets;
    totalShares -= burnedShares;
    shares[msg.sender] -= burnedShares;
    asset.safeTransfer(msg.sender, amount);
    emit Withdrawn(msg.sender, amount);
}
```

`msg.sender`는 출금을 요청한 Alice다. 풀은 자기 토큰을 보내므로 사용자의 승인을 쓰는 transferFrom 대신 transfer를 호출한다.
`safeTransfer`는 그 transfer가 false를 반환하면 오류로 바꾸고, 토큰이 낸 오류도 전파한다.
기록은 외부 토큰 호출 전에 차감한다. 공급·출금은 같은 `nonReentrant` 잠금을 사용한다.

### 왜 먼저 줄인 예치가 전송 실패 때 복구되는가

예치 차감과 토큰 호출은 하나의 withdraw 실행 안에 있다. 풀에서 오류를 잡고 성공으로 바꾸지 않으므로
오류가 호출자까지 전파되면 그 출금에서 바뀐 예치 기록과 하위 토큰 호출의 상태가 모두 되돌아간다.
앞선 별도 거래의 공급 100은 취소되지 않는다.

`test_FalseWithdrawalTokenControlActuallyTransfersBeforeReturningFalse`는 풀 밖에서 실패 모형을 직접 호출한다.
Alice 200에서 Bob에게 40을 보내면 반환값은 false이지만 Alice 160·Bob 40이 남는다. 모형이 실제 전송을 하는 대조다.

`test_FalseWithdrawalRestoresDebitedDepositAndTransferredTokensThenAllowsRetry`는 이를 풀에 연결한다.

1. 준비: 장애를 끈 모형으로 정상 공급 100을 완료하고 양쪽 승인을 7/9 최소 단위로 남긴다.
2. 실패 실행: transfer 장애를 켜고 40 출금한다. 모형은 실제로 토큰을 보낸 뒤 false를 반환한다.
3. 실패 확인: 정확한 `SafeERC20FailedOperation(token)` 오류와 함께 Alice 토큰 100·예치 100·풀 100, 양쪽 승인·Bob 상태·총량이 직전 값으로 돌아온다.
4. 재시도: 장애를 끄고 다시 40 출금한다. Alice 140·예치 60·풀 60·승인 7/9·총량 200과 출금 이벤트 1회를 확인한다.

명시적 revert도 별도 테스트에서 `InjectedTransferFailure()` 원문과 직전12개 상태 보존을 확인한다.
[FailingMockUSDC](test/mocks/FailingMockUSDC.sol)의 transferFrom 장애는 기존 공급용, transfer 장애는 출금용으로 따로 설정한다.
장애 설정은 테스트 모형에만 있다.

### 출금 테스트의 준비·실행·실제 확인

공통 준비는 위 공급 테스트와 같으며 출금 권리는 정상 `_approveAndSupply`로 만든다.
아래 숫자는 USDC 단위이고 최소 단위·승인 7/9는 별도로 표시했다. 각 테스트는 새 토큰·풀에서 독립적으로 시작한다.

| 테스트 | 준비 → 실행 | 실제 확인 |
| --- | --- | --- |
| `test_WithdrawMovesTokensAndDebitsOnlyCallerWithoutNewApproval` | 공급 100·승인 0 → 40 출금 | 위 첫 출금 표와 요청액 40 이벤트 1회 |
| `test_AdditionalWithdrawalDebitsRemainingDepositAndEmitsRequestedAmount` | 100 공급·40 출금 → 추가 20 | Alice 160·예치/풀 40·총량 200·승인 0, 두 번째 이벤트는 요청 20으로 1회 |
| `test_WithdrawAcceptsFullDeposit` | 공급 100 → 100 출금 | Alice 200·예치/풀 0·승인 0·총량 200 |
| `test_WithdrawAcceptsExactlyRemainingDepositAndCash` | 공급 100·40 출금 → 남은 60 출금 | 직전 예치/현금 60 확인 후 Alice 200·예치/풀 0·총량 200 |
| `test_WithdrawAcceptsOneSmallestUnit` | 공급 100 → 최소 단위 1 출금 | Alice 100_000_001·예치/풀 99_999_999·승인 0·총량 200_000_000 |
| `test_ZeroWithdrawalTakesPriorityWhenDepositAndCashAreZero` | 예치/현금 0 → 0 출금 | `ZeroAmount()` 우선, 직전12개 상태 유지 |
| `test_ZeroWithdrawalKeepsPreviousWithdrawalAndApprovals` | 공급 100·출금 40·양쪽 승인 7/9 → 0 출금 | 금액 오류와 기존 출금 결과·승인 보존 |
| `test_ExcessWithdrawalRejectsDepositBeforeLiquidityAndPreservesState` | 예치/현금 60 → 61 출금 | `InsufficientDeposit(60, 61)` 우선, 직전 상태 유지 |
| `test_IlliquidWithdrawalRejectsWholeRequestAndPreservesAdjustedState` | 공급 100 후 현금만 50으로 조정 → 60 요청 | `InsufficientLiquidity(50, 60)`와 조정 후 상태 보존, 부분 지급 없음 |
| `test_WithdrawAcceptsExactCashLimitBelowDeposit` | 예치 100·조정된 현금 50 → 50 출금 | Alice 150·예치 50·풀 0·승인 0·조정 총량 150 |
| `test_WithdrawalWithoutOwnDepositPreservesOtherUserFunds` | Alice 예치 100·Bob 예치 0 → Bob이 1 요청 | `InsufficientDeposit(0, 1)`, 직전 상태 유지 |
| `test_WithdrawalKeepsOtherDepositorAndExistingApprovals` | Alice/Bob 100/30 공급·승인 7/9 → Alice 40 출금 | Alice 토큰140·예치60, Bob 토큰0·예치30, 풀90·승인7/9·총량230 |
| `test_DirectDonorCannotWithdrawWithoutDeposit` | Alice 공급100·Bob 직접 송금10 → Bob이1 요청 | 풀110·총량210·Bob 권리0 먼저 확인 후 예치금 오류·상태 보존 |
| `test_DirectMintCannotCreateWithdrawalRight` | Alice 공급100·풀에 직접 발행10 → Bob이1 요청 | 위와 같은 권리 부재·정확한 오류·상태 보존 |
| `test_FalseWithdrawalTokenControlActuallyTransfersBeforeReturningFalse` | 모형 Alice200 → Bob에게40 직접 전송 | false와 실제 Alice160·Bob40·총량200 |
| `test_FalseWithdrawalRestoresDebitedDepositAndTransferredTokensThenAllowsRetry` | 정상 공급100 → false 출금40 → 장애 해제·재시도40 | 실패 직전 상태 복구 후 정상 출금 결과·이벤트1회 |
| `test_RevertingWithdrawalBubblesExactErrorAndPreservesState` | 정상 공급100 → transfer의 지정 오류 | 정확한 토큰 오류 전파·직전12개 상태 보존 |

현금 부족 준비의 `deal(token, pool, 50_000_000, true)`는 테스트 도구의 ERC20 저장소 조정이다.
예치 100은 유지하지만 풀 잔고 100→50의 차이만큼 총발행량도 200→150이 된다. 조정 직후 값을 먼저 확인하고
그 시점을 snapshot으로 삼는다. 정상 공급·출금으로 현금 부족을 만들었다고 주장하지 않는다.

### 중첩 호출을 잡는 경우와 전파하는 경우

기존 `ReentrantMockUSDC`는 공급 → 공급을 확인한다. 새 [CrossReentrantMockUSDC](test/mocks/CrossReentrantMockUSDC.sol)는
실제 transferFrom/transfer를 마친 뒤 토큰 주소가 최소 단위 1의 공급 또는 출금을 한 번 재호출한다.
테스트 모형이며 생산 토큰에 이런 콜백을 추가하지 않는다.

준비: 토큰 주소에 최소 단위 2를 발행하고 콜백을 끈 정상 supply로 1을 예치한다.
따라서 자체 잔고1·예치1이 남고, 콜백을 켤 때 자체 승인1을 준다.
중첩 호출자는 Alice가 아니라 토큰 주소다. 권리·잔고·승인이 모두 있어야 잠금 대신 다른 부족 오류로 통과하는 일을 막을 수 있다.
총발행량은 200_000_002이며 Alice 100 공급 후 풀은 자체 예치 1을 포함해 100_000_001이다.

| 테스트 | 실행 | 실제 확인 |
| --- | --- | --- |
| `test_SupplyRejectsNestedWithdrawalWithFundedDeposit` | Alice 공급100 중 토큰이 출금1 최소 단위 재호출 | 시도·정확한 guard 오류, Alice 토큰/예치100·풀100_000_001·공급 이벤트1회·출금 이벤트 없음, 자체 잔고/예치/승인1 보존 |
| `test_WithdrawRejectsNestedSupplyAndExposesDebitedDeposit` | Alice 출금40 중 토큰이 공급1 재호출 | guard 오류를 잡아 Alice140·예치60·풀60_000_001·출금 이벤트1회·공급 이벤트 없음, 콜백이 읽은 Alice 예치60 |
| `test_WithdrawRejectsNestedWithdrawalWhileOuterSucceedsOnce` | Alice 출금40 중 토큰이 출금1 재호출 | 중첩만 정확한 guard 오류, 바깥 출금40만 반영·이벤트1회·자체 잔고/권리/승인1 유지 |
| `test_PropagatedNestedWithdrawalRestoresTokensDepositAndCallbackState` | 실제 전송 후 중첩 출금 오류를 바깥으로 전파 | 바깥도 같은 guard 오류, Alice100·예치100·풀100_000_001·직전12개 상태·자체 잔고/예치/승인1 복구, attempted=false·오류 기록/관측값도 초기화 |
| `test_PropagatedNestedWithdrawalDuringSupplyRestoresTokensAllowanceAccountingAndCallbackState` | 정상 공급40·유한 승인100 뒤 실제 transferFrom 후 중첩 출금 오류 전파 | A/S40_000_001·Alice q40_000_000·유한 승인100_000_000·실제 토큰 이동과 관측값 복구 |

표의 Alice·예치 정수는 USDC, 풀 값의 언더스코어 표기는 최소 단위다.
오류를 잡는 세 사례는 attempted·nestedSucceeded=false·오류 bytes와 바깥 1회분을 함께 확인한다.
공급 중 콜백은 바깥 지분 증가 전 장부를 관측한다. 출금 중 콜백은 A/S/q가 모두 차감된 장부를 관측한다.
Cross 모형은 환산 예치뿐 아니라 인정자산·총지분·관측 사용자 지분·토큰 자체 지분도 기록한다. 전파 실패 뒤 이 관측값들도0으로 복구된다.

오류를 전파한 마지막 사례는 그 콜백의 attempted 저장까지 취소된다. 실패 후 attempted=true를 기대하면 EVM 복구와 모순된다.
정확한 guard 오류가 바깥으로 나오는 것과 직전 상태 복구를 확인하며, 오류를 잡는 사례의 관측과 구분한다.

## 지분 환산을 읽는 순서

[#7](https://github.com/0Chord/lending-protocol/issues/7)은 USDC와 지분을 환산하는 계산기다.
[ShareMath](src/libraries/ShareMath.sol)는 internal pure 라이브러리이며 토큰 이동·지분 발행·저장소 변경을 하지 않는다.
LendingPool은 [#8](https://github.com/0Chord/lending-protocol/issues/8)에서 이 internal 계산을 공급·출금·조회에 연결한다. 별도 라이브러리 배포는 필요 없다.

A는 풀에서 인정한 USDC 자산, S는 총지분이다. 모든 인수·반환값은 정수 최소 단위다.
USDC·지분을 소수점 6자리로 표현하면 자산 10 USDC·총지분 6개는 A=10_000_000, S=6_000_000이다.
이 비율은 계산 테스트의 가정이며 현재 풀에 수익을 만드는 기능이 있다는 뜻은 아니다.

| 읽을 흐름 | 계산·코드 | 확인할 결과 |
| --- | --- | --- |
| USDC → 지분 | `toSharesDown` / `toSharesUp`: 금액×S÷A | 공급 지분 내림 / 출금 차감 지분 올림 |
| 지분 → USDC | `toAssetsDown`: 지분×A÷S | USDC 가치 내림 |
| 장부·정수 경계 | `_isEmptyAccounting`, 고정 OpenZeppelin `Math.mulDiv` | 초기 1:1 / 잘못된 장부 오류 / 최종 정수 범위 초과 오류 |

### 첫 테스트는 실제 계산 결과를 미리 정한 정답과 비교한다

준비: A=10_000_000, S=6_000_000이고 환산할 USDC는 1_000_001이다.
실행: 공급용 내림과 출금용 올림 함수를 각각 호출한다.
확인: [첫 테스트](test/ShareMath.t.sol)의 `test_ShareConversionsRoundInOppositeDirections`는 아래 두 값을 비교한다.

```solidity
assertEq(ShareMath.toSharesDown(1_000_001, 10_000_000, 6_000_000), 600_000);
assertEq(ShareMath.toSharesUp(1_000_001, 10_000_000, 6_000_000), 600_001);
```

`assertEq(실제 결과, 기대값)`는 두 값이 다르면 실패한다.
정확한 계산은 600_000.6이므로 내림은 600_000, 올림은 600_001이다. 지분 개수로는 0.600000개·0.600001개다.
핵심 구현은 `Math.mulDiv(assets, totalShares, accountedAssets, Math.Rounding.Floor)`이며 올림 함수는 `Ceil`을 사용한다.
이 테스트의 통과는 두 계산 결과가 정답과 같았다는 뜻이다. 실제 USDC 공급·출금이나 토큰 이동을 실행한 것은 아니다.
4 USDC처럼 정확히 나누어떨어지면 두 방향 모두 2.4지분(2_400_000)이며 3지분으로 올리지 않는다.

### 장부 검사와 계산 범위

세 함수 모두 입력 수량 처리 전에 장부를 검사한다. A/S 중 한쪽만 0이면 입력이 0이어도
`InvalidAccountingState(A, S)`로 거절한다. 둘 다 0이면 초기 1:1 계산으로 입력을 그대로 반환한다.
빈 장부의 수학적 반환값이 실제 보유 지분·출금 권리를 만들지는 않는다. 두 장부 값이 양수이면 입력 0은 0이다.

`Math.mulDiv`는 중간 곱이 uint256을 넘더라도 최종 정수 결과가 범위 안이면 계산한다.
최종 내림 또는 올림 결과가 uint256 범위를 넘으면 정확한 `Panic(uint256)` 코드 `0x11`이 전파된다.
지분0이나 총지분 전체가 반환되는 계산은 성공한다. 실제 거래의0 금액·개인 권리·현금·잔여 자산 검사는 이를 호출하는 LendingPool이 수행한다.

<details>
<summary>나머지 테스트의 준비·실행·실제 확인 결과</summary>

테스트는 [ShareMathTest](test/ShareMath.t.sol)에 있다. 아래 D/U/V는 각각 `toSharesDown` / `toSharesUp` / `toAssetsDown`이고 M은 `type(uint256).max`다.
정상 계산은 internal 함수를 직접 사용한다. 오류는 같은 라이브러리를 호출하는 시험 전용 `ShareMathHarness`를 새로 배포해 외부 호출에서 관측한다.
이 wrapper는 계산을 복제하지 않는다. 다른 테스트용 토큰·외부 서비스·RPC는 사용하지 않는다.
각 행의 숫자는 전부 정수 최소 단위이며 기대값은 명세의 고정 예시다.

| 테스트 | 준비·실행 | 실제 assertion |
| --- | --- | --- |
| `test_AssetConversionRoundsDown` | A10_000_000/S6_000_000에서 지분2_400_000, A10/S6에서 지분1을 V로 환산 | 각각4_000_000·1 |
| `test_EmptyAccountingUsesOneToOneForAllInputs` | A=S=0, 입력0/1/100_000_000/M을 D/U/V에 적용 | 세 함수 모두 입력 그대로 |
| `test_ZeroInputWithValidAccountingReturnsZero` | A10/S6, 입력0을 D/U/V에 적용 | 모두0 |
| `test_MissingAssetsRevertsEvenForZeroInput` | A0/S1, 입력0·1을 D/U/V에 적용 | 정확한 오류 종류와 인수(0,1) |
| `test_MissingSharesRevertsEvenForZeroInput` | A1/S0, 입력0·1을 D/U/V에 적용 | 정확한 오류 종류와 인수(1,0) |
| `test_ExactShareConversionsPreserveFractionalShares` | A=S=100_000_000에서 금액40_000_000, A10_000_000/S6_000_000에서 금액4_000_000을 D/U로 환산 | 각각40_000_000·2_400_000 |
| `test_SmallestAssetMayConvertToZeroShares` | A10/S6에서 금액1을 D/U로 환산 | D0·U1, 계산 자체 성공 |
| `test_LastTotalSharesIsACalculationResult` | A10_000_000/S6_000_000에서 금액9_999_999를 U로 환산 | 총지분과 같은6_000_000 반환 |
| `test_IntermediateProductCanOverflowWhenResultFits` | A=S=2에서 입력M을 D/U/V로 환산 | 중간 곱2M에도 모두M |
| `test_FloorCanReturnMaxBeforeCeilOverflows` | A=M−2/S=M−1에서 금액M−1을 D/U로 환산 | D=M 성공, U만 정확한 Panic(0x11) |
| `test_ShareConversionsRejectOverflowingResults` | A=M−1/S=M에서 금액M을 D/U로 환산 | 둘 다 정확한 Panic(0x11) |
| `test_AssetConversionRejectsOverflowingResult` | A=M/S=M−1에서 지분M을 V로 환산 | 정확한 Panic(0x11) |

첫 테스트를 포함해 테스트 함수는 13개다. 빈 장부·잘못된 장부의 고정 반복 입력을 별도 테스트 함수 수로 세지 않는다.
오류 테스트는 아무 revert나 인정하지 않고 전체 오류 데이터와 Panic 코드를 비교한다.
순수 계산 검증이며 #8의 토큰 전송·장부 저장·재진입 방어를 미리 검증한 것이 아니다.

</details>

## 풀에 연결한 뒤 확인할 나머지 상황

공급·출금은 기존 USDC 입력을 유지하고 `shares`로 권리를 기록한다. 전송 실패가 전파되면 자산·총지분·개인 지분과 토큰 상태가 함께 복구된다.
정수 반올림 때문에 지분 합은 총지분과 같아도, 내림한 USDC 권리의 합은 인정자산보다 작을 수 있다.
첫1:1 상태에서 정상 공급·출금만 하면1:1이 유지된다. 아래의 다른 비율은 시험용 준비이며 실제 수익·손실 인정 API는 없다.

<details>
<summary>직접 송금·반올림·거절·실패 복구 테스트의 입력과 실제 확인</summary>

새 사례는 [LendingPoolSharesTest](test/LendingPoolShares.t.sol) 23개다. 기존 [LendingPoolTest](test/LendingPool.t.sol) 37개에도 자산·지분 관측을 더하고 공급 오류 전파 대표1개를 추가했다.
`_state`는 자산·총지분·두 지분·두 환산권리·두 토큰 잔고·현금·두 승인·총발행량12개를 비교한다. 잘못된 장부는 권리 조회도 오류이므로 `_rawState`의 권리를 제외한10개를 비교한다.

비1:1의 `_prepareRatio`는 총발행량0인 새 토큰에서 정상 공급으로 지분을 만든다. 직접 mint가 인정자산을 바꾸지 않았는지 먼저 검사한 다음,
[시험용 풀](test/mocks/LendingPoolHarness.sol)의 `setAccountedAssetsForTest`로만 가정 비율을 준비한다. setter는 일반 LendingPool에 없다.
재진입 모형 역시 로컬 EVM의 실제 토큰 이동 후 콜백이며 외부 네트워크·실제 USDC 연동 검증은 아니다.
표의 언더스코어 없는 작은 수와 M도 모두 정수 최소 단위다. M은 uint256 최댓값이다.

| 테스트 | 준비·실행 | 실제 확인 |
| --- | --- | --- |
| `test_ZeroShareSupplyPreservesAllState` | A10/S1에서 Bob1 공급 | 정확한 ZeroShares, 승인1을 포함한12값 유지 |
| `test_LastSharesWithResidualAssetRevert` | A10_000_000/S6_000_000의 전 소유자가9_999_999 출금 | ResidualAssets(1),12값 유지 |
| `test_DirectTransferLeavesSurplusAcrossExitAndRestart` | 100 공급→직접 transfer20→기부자1 출금 거절→기존 소유자 전액 출금→새10 공급 | 권리100 유지, 전액 출금 뒤 잉여20·빈 장부, 새 권리10·현금30 |
| `test_DirectMintLeavesSurplusAcrossExitAndRestart` | 같은 순서에서 직접 mint20 | 같은 권리·거절·재시작 결과와 총발행량230 |
| `test_InitialDonationDoesNotBelongToFirstSupplier` | 빈 풀 직접 mint20→Alice100 공급 | 인정자산/총지분/Alice 지분/권리100, 현금120 |
| `test_NonUnitSupplyUsesPreTransferRate` | A10_000_000/S6_000_000에서 Bob4_000_000 공급 | Bob q2_400_000,A14_000_000/S8_400_000, 권리Alice10_000_000/Bob4_000_000, USDC 이벤트1회 |
| `test_RoundedSupplyPreservesSharesAndFloorsClaims` | 같은 비율에서 Bob1_000_001 공급 | q600_000,A11_000_001/S6_600_000, 권리 합11_000_000, 이벤트는1_000_001 |
| `test_NonUnitWithdrawalBurnsExactFractionalShares` | A10_000_000/S6_000_000에서4_000_000 출금 | A/현금6_000_000,S/q3_600_000, 지급·이벤트4_000_000 |
| `test_SmallestWithdrawalRoundsShareBurnUp` | 같은 비율에서1 출금 | q1 차감, A/현금9_999_999,S/q5_999_999, 지급1 |
| `test_FullNonUnitWithdrawalClearsAccounting` | 같은 비율에서10_000_000 전액 출금 | A/S/q/현금0, 지급10_000_000 |
| `test_InsufficientCashTakesPriorityOverResidualAssets` | 현금만9_000_000으로 낮춘 뒤9_999_999 출금 | 정확한 현금 부족 오류, 조정 총량을 포함한12값 유지 |
| `test_PersonalClaimIsCheckedInsteadOfTotalShares` | A10_000_000/S6_000_000, 두 사람 q각3_000_000에서Alice6_000_000 출금 | 개인 권리5_000_000 오류,12값 유지 |
| `test_OtherSharesStayFixedWhileConvertedClaimChanges` | A10/S6/q각3에서 Alice2 출금 | A8/S4/qAlice1/qBob3, Bob 환산권리5→6 |
| `test_RoundedClaimsNeedNotSumToAccountedAssets` | A10/S6/qAlice1/qBob5 | 지분 합6, 권리Alice1/Bob8·합9, A10 |
| `test_ZeroSharesTakesPriorityOverMissingAllowance` | 지분0 공급과 승인0이 겹침 | ZeroShares가 먼저,12값 유지 |
| `test_ZeroSharesTakesPriorityOverTokenFailure` | 지분0 공급과 실제 전송 뒤 revert 모형이 겹침 | 토큰 오류 대신 ZeroShares,12값 유지 |
| `test_MissingAssetsRejectsPositiveCallsAndAllClaimQueries` | A0/S1·Alice q1/Bob q0 | 양수 공급/출금·두 권리 조회는 정확한 장부 오류,0 요청은 ZeroAmount 우선·원시10값 유지 |
| `test_MissingSharesRejectsPositiveCallsAndAllClaimQueries` | A1/S0·두 q0 | 같은 오류 우선순위와 원시 상태 보존 |
| `test_SupplyAccountingOverflowRestoresTransferAndAllowance` | 정상 M 공급 뒤 현금/총량0으로 조정→Alice mint1·유한 승인1→공급1 | 정확한 Panic(0x11), A/S/q/권리M·현금0·Alice1·승인1·총량1 복구 |
| `test_NonUnitFalseSupplyRestoresStateAndAllowsRetry` | 비1:1 공급 전송 후 false→장애 해제·같은 공급 재시도 | 첫 시도 정확한 토큰 오류·12값 복구, 재시도 Bob q2_400_000·승인0 |
| `test_NonUnitFalseWithdrawalRestoresStateAndAllowsRetry` | 비1:1 선차감·전송 후 false→장애 해제·같은 출금 | 복구 후 재시도 A6_000_000/S/q3_600_000·지급4_000_000 |
| `test_NonUnitCaughtReentryLeavesOneOuterWithdrawal` | A10/S6/qAlice5/qToken1에서 외부 출금2 중 중첩 출금1 | 중첩만 잠금 오류, A8/S4/qAlice3/qToken1·권리Alice6·실제 지급2·이벤트1회 |
| `test_NonUnitPropagatedReentryRestoresAccountingAndCallbackState` | 같은 모형이 중첩 오류를 전파 | 바깥도 잠금 오류,12값과 토큰 주소 권리·지분·잔고·승인 및 모든 공개 콜백 기록 복구 |

마지막 두 모형은 토큰 주소 자체의 지분1·환산권리1·승인1·잔고1과 풀 현금10을 먼저 확인한다. 중첩 출금1은 잠금이 없다면 실행할 수 있으므로 다른 부족 오류를 방어로 오해하지 않는다.
정상 재진입 모형의 전송 전/후 시점을 구분하고, 오류를 전파하면 `attempted`와 관측값 저장도 함께 취소됨을 확인한다.
공급 중 전파 대표는 기존 회귀 파일에서 유한 승인100_000_000과 새 회계·토큰·콜백 상태의 복구를 확인한다.
테스트 기대값은 명세 고정 예시이며 실제 환산 함수를 정답 생성에 재사용하지 않는다.

</details>

## 이번 코드의 경계

MockUSDC의 `mint`는 누구나 호출할 수 있는 테스트 준비 기능이다.
토큰 발행에는 실제 자산 입금이 없으며, 풀의 예치 권리를 만들지 않는다.
풀은 대출 자산 MockUSDC6·담보 MockWBTC8·Mock 가격 원천8을 배포 때 고정한다. 본인 공급·출금·담보 입금/반환·원금 대출/상환을 다룬다.
자산 변경·대리 공급/차입/상환·수령자 지정·풀의 이자 누적·청산·잉여 회수·구제 함수는 없다. #19의 순수 이자 계산은 아직 풀에 연결하지 않았다. 가격 하락만으로 부채를 삭제하거나 손실을 보전하지 않는다.
실제 USDC의 운영 기능, 전송 수수료, 리베이스도 구현하지 않는다. 배포는 이번 작업 범위에 포함하지 않는다.

풀에 직접 전송·발행한 토큰은 예치 권리를 만들지 않는다. 직접 전송 10 후 정상 공급 100이면 풀 현금은 110이고 예치 권리는 100이다.
따라서 직접 송금이 있는 경우까지 풀 현금과 예치 합이 항상 같다고 가정하지 않는다.
생성자의 코드 존재·6/8/8 metadata 검사는 모든 ERC20의 안전성이나 가격의 진실성을 보장하지 않는다.
재진입 검증도 임의의 악성 자산 지원을 의미하지 않는다. 실제 외부 서비스·시장가격의 정확성은 이번 로컬 Mock 범위 밖이다.

테스트는 단위 연결·공급 권리·담보·원금 부채·공통 재원의 정상·거절·전송 실패와 대표 재진입 경로를 다룬다.
#19에서는 이와 별도로 단리 누적·완제 견적·이자 우선 배분·정산 올림·산술 범위를 검증한다.
작성된 사례·실제 실행 결과·독립 검토 완료는 구분하며, 로컬 검사 통과를 사용자 이해나 독립 리뷰 완료로 읽지 않는다.
OpenZeppelin의 모든 ERC20 동작이나 실제 USDC 연동을 검증하는 범위는 아니다.
생성되는 `out/`, `cache/`, `broadcast/`는 버전 관리에서 제외한다.

구현·검증·독립 리뷰와 사용자의 코드 이해 확인은 각각 구분한다.
PR은 사용자가 주요 동작과 실패 흐름, 설명 자료를 확인한 뒤 게시한다.
