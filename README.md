# Lending Protocol 학습 프로젝트

Solidity·Foundry로 공급·출금부터 작은 단위로 만드는 개인 학습 프로젝트다.
현재 구현 범위는 [이슈 #1](https://github.com/0Chord/lending-protocol/issues/1)의 테스트 환경·MockUSDC와
[#2](https://github.com/0Chord/lending-protocol/issues/2)의 본인 공급·예치 기록과
[#3](https://github.com/0Chord/lending-protocol/issues/3)의 본인 출금과
[#7](https://github.com/0Chord/lending-protocol/issues/7)의 지분 환산 계산이다. 테스트 전용 로컬 학습 프로젝트다.

## 실행 환경

Git과 Foundry가 설치된 환경에서 프로젝트 파일과 서브모듈 고정 정보를 받은 뒤 루트에서 실행한다.

```sh
git submodule update --init --recursive
forge fmt --check
forge build
forge test --match-contract MockUSDCTest -vv
forge test --match-contract LendingPoolTest -vv
forge test --match-contract ShareMathTest -vv
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
| 검증에 사용한 Foundry | `1.6.0-v1.7.0`, commit `f83bad912a9dba7bf0371def1e70bb1896048356` |

컴파일러·EVM 대상·import 연결은 [foundry.toml](foundry.toml)에 있다.
서브모듈의 Git 고정 커밋과 [foundry.lock](foundry.lock)에 같은 의존성 커밋을 기록한다.
다른 작업 사본에서도 `git submodule update --init --recursive`로 그 커밋을 복원한다.

forge-std는 현재 설치된 Foundry에서 사용할 조합으로 고정했다.
[v1.17.0 릴리스](https://github.com/foundry-rs/forge-std/releases/tag/v1.17.0)는 새 `Vm.Gas` 구조 때문에 Foundry v1.8.3 이상을 권고한다.
EVM 대상은 컴파일러 기본값 변화에 영향을 받지 않도록 명시했다.

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
    asset.safeTransferFrom(msg.sender, address(this), amount);
    deposits[msg.sender] += amount;
    emit Supplied(msg.sender, amount);
}
```

Alice의 호출에서 `msg.sender`는 Alice이고 `address(this)`는 풀이다.
토큰 계약에서는 풀이 승인 사용 주체(spender)로 호출한다. Alice가 풀에 준 승인을 사용해 Alice의 잔고를 줄이고 풀의 잔고를 늘린다.
전송이 성공한 뒤에만 `deposits[Alice]`에 같은 `amount`를 더한다. 이 기록은 새 ERC20이나 토큰 발행량이 아니다.

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
실패 보존 검사는 양쪽 승인까지 포함해 8개 값을 확인한다.
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
| `test_ZeroSupplyRevertsWithoutChangingState` | 기존 예치 40·새 승인 100 → 공급 0 | `ZeroAmount()`와 호출 직전 8개 상태 보존 |
| `test_InsufficientAllowanceRevertsWithoutChangingState` | 기존 예치 40, Alice 토큰을 200으로 준비·승인 99 → 공급 100 | `ERC20InsufficientAllowance(pool, 99, 100)`와 직전 상태 보존 |
| `test_InsufficientBalanceRestoresSpentAllowanceAndExistingDeposit` | 기존 공급 101 후 잔고 99·승인 100 → 공급 100 | `ERC20InsufficientBalance(Alice, 99, 100)`, 승인 100·기존 예치 101을 포함한 직전 상태 보존 |
| `test_FalseTokenControlActuallyMovesTokensBeforeReturningFalse` | 장애 토큰 Alice 200·테스트 주소에 승인 100 → Bob에게 직접 전송 | 반환 false, Alice/Bob 각각 100·승인 0·발행량 200. 풀 공급을 거치지 않는 모형 대조 |
| `test_FalseTransferRollsBackTokenChangesAndKeepsExistingDeposit` | 기존 공급 40·승인 100 → 전송 뒤 false | 정확한 `SafeERC20FailedOperation(token)`과 직전 상태 보존, 기존 예치 40 |
| `test_RevertingTransferBubblesExactErrorAndPreservesState` | 기존 공급 40·승인 100 → 전송 중 지정 오류 | `InjectedTransferFailure()` 전파와 직전 상태 보존 |
| `test_DirectTransferDoesNotCreateDepositOrInflateLaterSupply` | Alice 200 → 풀로 직접 전송 10 → 공급 100 | 직접 전송 직후 예치 0·풀 10·공급 이벤트 없음, 이후 Alice 90·풀 110·예치 100·발행량 200 |
| `test_DirectMintDoesNotChangeExistingDeposits` | 기존 공급 40 → 풀에 직접 발행 10 | Alice 토큰 160·풀 50·예치 40·Bob 예치 0·발행량 210·공급 이벤트 없음 |
| `test_ReentryIsRejectedWhileOuterSupplySucceedsOnce` | 콜백 토큰에 자체 잔고·승인 최소 단위 1, Alice 200·승인 100 → 공급 100 중 재호출 | 콜백 시도·정확한 guard 오류·바깥 공급만 1회 성공, 토큰 주소의 잔고·승인 1·예치 0 유지 |

재진입 모형은 [ReentrantMockUSDC](test/mocks/ReentrantMockUSDC.sol)에만 있다.
토큰이 중첩 호출하면 그 호출자는 Alice가 아니라 토큰 주소다. 충분한 자체 잔고·승인과 양수 금액을 준비해 승인·잔고 부족으로 인한 거짓 통과를 막는다.
중첩 오류를 잡아 바깥 전송을 계속하므로 테스트는 콜백 실행과 오류를 조회할 수 있다.
재진입 실패와 별도로 Alice의 토큰/예치 100·풀 토큰 100·승인 0·Bob 상태 0, 총발행량 200_000_001, 공급 이벤트 1회를 확인한다.
추가된 최소 단위 1은 준비에서 발행한 토큰이며 공급이 새로 발행한 수량이 아니다.

## 출금 기능을 읽는 순서

이번 변화는 풀 안의 토큰을 본인 지갑으로 돌려주면서 본인의 예치 권리를 같은 수량만큼 줄이는 것이다.
제품 코드는 [LendingPool.withdraw](src/LendingPool.sol#L60), 검증 코드는 [LendingPoolTest](test/LendingPool.t.sol)에 있다.
먼저 첫 40 출금과 실패 복구를 읽고, 나머지 경계는 아래 테스트 표로 이어간다.

| 흐름 | 시작 → 결과 |
| --- | --- |
| 정상 출금 | 본인 예치·현금이 충분함 → 기록 차감·토큰 반환·출금 이벤트 1회 |
| 요청 거절 | 0 → 본인 예치 부족 → 현금 부족 순으로 검사 → 정확한 오류, 상태 보존 |
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
    uint256 deposited = deposits[msg.sender];
    if (amount > deposited) revert InsufficientDeposit(deposited, amount);
    uint256 cash = asset.balanceOf(address(this));
    if (amount > cash) revert InsufficientLiquidity(cash, amount);

    deposits[msg.sender] = deposited - amount;
    asset.safeTransfer(msg.sender, amount);
    emit Withdrawn(msg.sender, amount);
}
```

`msg.sender`는 출금을 요청한 Alice다. 풀은 자기 토큰을 보내므로 사용자의 승인을 쓰는 transferFrom 대신 transfer를 호출한다.
`safeTransfer`는 그 transfer가 false를 반환하면 오류로 바꾸고, 토큰이 낸 오류도 전파한다.
기록은 외부 토큰 호출 전에 차감한다. 공급·출금은 같은 `nonReentrant` 잠금을 사용한다.

### 왜 먼저 줄인 예치가 전송 실패 때 복구되는가

사용자가 먼저 함께 확인하고 싶다고 답한 부분은 전송 실패 시 예치 복구다.
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

명시적 revert도 별도 테스트에서 `InjectedTransferFailure()` 원문과 직전 8개 상태 보존을 확인한다.
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
| `test_ZeroWithdrawalTakesPriorityWhenDepositAndCashAreZero` | 예치/현금 0 → 0 출금 | `ZeroAmount()` 우선, 직전 8개 상태 유지 |
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
| `test_RevertingWithdrawalBubblesExactErrorAndPreservesState` | 정상 공급100 → transfer의 지정 오류 | 정확한 토큰 오류 전파·직전 8개 상태 보존 |

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
| `test_PropagatedNestedWithdrawalRestoresTokensDepositAndCallbackState` | 실제 전송 후 중첩 출금 오류를 바깥으로 전파 | 바깥도 같은 guard 오류, Alice100·예치100·풀100_000_001·직전 8개 상태·자체 잔고/예치/승인1 복구, attempted=false·오류 기록/관측값도 초기화 |

표의 Alice·예치 정수는 USDC, 풀 값의 언더스코어 표기는 최소 단위다.
오류를 잡는 세 사례는 attempted·nestedSucceeded=false·오류 bytes와 바깥 1회분을 함께 확인한다.
공급 중 콜백은 바깥 예치 증가 전이므로 Alice 예치0을 관측한다. 출금 중 콜백은 예치 선차감 후의 60을 관측한다.

오류를 전파한 마지막 사례는 그 콜백의 attempted 저장까지 취소된다. 실패 후 attempted=true를 기대하면 EVM 복구와 모순된다.
정확한 guard 오류가 바깥으로 나오는 것과 직전 상태 복구를 확인하며, 오류를 잡는 사례의 관측과 구분한다.

## 지분 환산을 읽는 순서

[#7](https://github.com/0Chord/lending-protocol/issues/7)은 USDC와 지분을 환산하는 계산기다.
[ShareMath](src/libraries/ShareMath.sol)는 internal pure 라이브러리이며 토큰 이동·지분 발행·저장소 변경을 하지 않는다.
기존 LendingPool은 아직 이 계산기를 호출하지 않는다. 공급·출금·조회의 지분 회계 연결은 후속 [#8](https://github.com/0Chord/lending-protocol/issues/8)이다.

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
지분 0이나 총지분 전체가 반환되는 계산은 성공한다. 실제 거래의 0 금액·개인 권리·현금·잔여 자산 검사는 #8의 풀 책임이다.

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

## 이번 코드의 경계

MockUSDC의 `mint`는 누구나 호출할 수 있는 테스트 준비 기능이다.
토큰 발행에는 실제 자산 입금이 없으며, 풀의 예치 권리를 만들지 않는다.
풀은 배포한 자산 하나를 고정하며 본인 공급과 본인 지갑으로의 출금만 받는다. 자산 변경·타인 대신 공급·수령자 지정·이자·대출·구제 함수는 없다.
실제 USDC의 운영 기능, 전송 수수료, 리베이스도 구현하지 않는다. 배포는 이번 작업 범위에 포함하지 않는다.

풀에 직접 전송·발행한 토큰은 예치 권리를 만들지 않는다. 직접 전송 10 후 정상 공급 100이면 풀 현금은 110이고 예치 권리는 100이다.
따라서 직접 송금이 있는 경우까지 풀 현금과 예치 합이 항상 같다고 가정하지 않는다.
생성자의 코드 존재 검사는 모든 ERC20의 안전성을 보장하지 않는다. 재진입 검증도 임의의 악성 자산 지원을 의미하지 않는다.

테스트는 소수점 설정·지급 연결 및 공급·출금의 정상·거절·전송 실패 결과를 확인한다.
OpenZeppelin의 모든 ERC20 동작이나 실제 USDC 연동을 검증하는 범위는 아니다.
생성되는 `out/`, `cache/`, `broadcast/`는 버전 관리에서 제외한다.

구현·검증·독립 리뷰와 사용자의 코드 이해 확인은 각각 구분한다.
PR은 사용자가 주요 동작과 실패 흐름, 설명 자료를 확인한 뒤 게시한다.
