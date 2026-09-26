# PriceBalancer — 거래소 간 가격 맞추기

같은 토큰 페어가 SERIES9 DEX, Uniswap, PancakeSwap 에 각각 풀로 있으면 가격이 조금씩
벌어집니다. `PriceBalancer` 는 싼 곳에서 사서 비싼 곳에 파는 거래를 한 트랜잭션 안에서
실행해서, 그 차이를 이익으로 회수하며 가격을 다시 붙여 놓습니다.

- 컨트랙트: [`src/PriceBalancer.sol`](../src/PriceBalancer.sol)
- 키퍼(주기 실행): [`script/Rebalance.s.sol`](../script/Rebalance.s.sol), [`script/keeper.sh`](../script/keeper.sh)
- 배포: [`script/DeployBalancer.s.sol`](../script/DeployBalancer.s.sol)
- 테스트: [`test/PriceBalancer.t.sol`](../test/PriceBalancer.t.sol)

## 1. 지원하는 풀

| 종류 (`VenueKind`) | 대상 | 수수료 |
|---|---|---|
| `Series9Spot` | SERIES9 `SpotPool` (레지스트리에 등록된 것만) | 풀에서 읽음 |
| `UniswapV2` | Uniswap V2, PancakeSwap V2 등 V2 포크 페어 | **직접 입력** — Uniswap V2 `3000`, PancakeSwap V2 `2500` (ppm) |
| `UniswapV3` | Uniswap V3, PancakeSwap V3 풀 | 풀에서 읽음 |

V2 페어는 수수료를 조회할 방법이 없어서 등록할 때 넣어야 합니다. 너무 낮게 넣으면 페어의
K 검사에서 거래가 되돌아가고(손실 없음), 너무 높게 넣으면 페어에 먼지만 조금 남습니다.

PancakeSwap V3 는 콜백 이름(`pancakeV3SwapCallback`)과 `slot0` 의 한 필드 타입이 Uniswap
과 달라서, 둘 다 받도록 처리해 두었습니다.

**지원하지 않는 것**: Uniswap V4 와 PancakeSwap Infinity 는 싱글톤 PoolManager 구조라 ABI 가
완전히 다릅니다. 필요하면 어댑터를 따로 추가해야 합니다.

## 2. 동작 원리

리밸런스 한 번은 두 풀을 도는 왕복 거래입니다.

1. `firstVenue` 에서 `tokenIn` → 상대 토큰 (상대 토큰이 가장 싼 곳)
2. `secondVenue` 에서 받은 상대 토큰 전부 → `tokenIn` (상대 토큰이 가장 비싼 곳)

끝나고 `tokenIn` 이 `minProfit` 이상 늘지 않았거나, 상대 토큰이 조금이라도 줄었으면 전체가
되돌아갑니다.

### 얼마나 거래하나

이익이 최대가 되는 수량에서 두 풀의 한계가격은 수수료만큼만 차이 나게 됩니다. 이게 손해
없이 가격을 붙일 수 있는 한계입니다. 그보다 더 밀면 수수료가 차익보다 커지므로 하지
않습니다. 즉 **가격은 "완전히 동일"이 아니라 "수수료 대역 안"으로 맞춰집니다**
(0.3% 풀 두 개면 대략 0.6% 이내).

- **V2 계열끼리** (SERIES9 ↔ V2): 닫힌 식으로 정확히 계산 — `quoteOptimalAmountIn`
  두 풀을 가상 준비금 `ra = a1·b2/(b2+g2·b1)`, `rb = g2·b1·a2/(b2+g2·b1)` 인 하나의 곡선으로
  합치면 최적 수량은 `x = (√(g1·ra·rb) − ra) / g1`.
- **V3 가 끼면**: V3 는 틱을 넘나들어 닫힌 식이 없어서, 실제 스왑을 실행해 보고 되돌리는
  시뮬레이션으로 삼분탐색합니다 — `findOptimalAmountIn`. view 가 아니므로 `eth_call` 로
  부르세요. 반복 1회에 왕복 2번이라 30회면 가스 수백만~천만 단위가 들지만, 키퍼는 이걸
  로컬 포크에서만 돌리므로 온체인 비용은 없습니다.

## 3. 권한

| 역할 | 할 수 있는 것 |
|---|---|
| owner (Safe) | 풀 등록/삭제 `setVenue`, 키퍼 지정 `setOperator`, 재고 인출 `withdraw`, 리밸런스 |
| operator (키퍼 핫키) | `rebalance` 만 |
| 누구나 | 가격 조회, 수량 계산 (시뮬레이션은 항상 되돌려짐) |

- 등록된 풀만 호출합니다. 키퍼 키가 털려도 가짜 풀로 재고를 빼낼 수 없습니다.
- 매 리밸런스는 두 토큰 잔고가 줄지 않아야 성공하므로, 털린 키로 할 수 있는 건 가스
  낭비 정도입니다.
- 소유권 이전은 2단계(`transferOwnership` → `acceptOwnership`)입니다.
- SERIES9 가 정지(`paused`)되면 SERIES9 풀을 거치는 리밸런스도 같이 멈춥니다.
- 업그레이드 경로가 없습니다. 바꾸려면 새로 배포하고 재고를 옮깁니다.

## 4. 운영 순서

### 4.1 배포

```bash
export PRIVATE_KEY=<배포 키>
export DEX_REGISTRY=0xE8249f2626605c7E063acf90f8E356a93c2968AC   # 메인넷 DexRegistry
export BALANCER_OWNER=<Safe 주소>
export KEEPER_ADDRESS=<키퍼 핫키 주소>

forge script script/DeployBalancer.s.sol:DeployBalancer \
  --rpc-url "$MONAD_RPC_URL" --broadcast --profile deploy
```

### 4.2 풀 등록 (Safe 에서)

한 페어에 대해 가격을 맞출 풀들을 등록합니다. **Uniswap / PancakeSwap 풀 주소는 각
프로젝트 공식 문서나 팩토리의 `getPair` / `getPool` 로 직접 확인하세요.** 여기엔 적어두지
않았습니다.

```text
setVenue(<SERIES9 SpotPool>,   1, 0)      // Series9Spot
setVenue(<Uniswap V2 pair>,    2, 3000)   // UniswapV2, 0.30%
setVenue(<PancakeSwap V2 pair>,2, 2500)   // UniswapV2, 0.25%
setVenue(<Uniswap V3 pool>,    3, 0)      // UniswapV3
setVenue(<PancakeSwap V3 pool>,3, 0)      // UniswapV3
```

### 4.3 재고 넣기

잔고를 컨트랙트로 그냥 전송하면 됩니다. 키퍼가 `TOKEN_IN` 으로 쓰는 쪽 토큰이 있어야
하고, 이익도 그 토큰으로 쌓입니다. 두 토큰을 다 넣어두면 양쪽 방향 모두 돌릴 수 있습니다.
한 번에 거래하는 양은 재고를 넘지 못하므로, 재고가 작으면 가격을 여러 틱에 걸쳐
나눠서 맞춥니다.

### 4.4 키퍼 실행

```bash
export RPC_URL=$MONAD_RPC_URL
export BALANCER=<PriceBalancer 주소>
export VENUES=<풀1>,<풀2>,<풀3>        # 같은 페어의 등록된 풀들
export TOKEN_IN=<재고 토큰>
export OPERATOR_PRIVATE_KEY=<키퍼 키>
export MIN_SPREAD_BPS=70               # 수수료 대역보다 조금 위로
export MIN_PROFIT=<가스비 이상의 최소 이익>

./script/keeper.sh                     # 기본 30초마다 (KEEPER_INTERVAL)
```

틱마다 모든 풀 가격을 읽고, 가장 벌어진 두 풀을 골라 수량을 계산한 뒤, 이익이 기준을
넘을 때만 `rebalance` 한 건을 보냅니다. 예상 이익의 90%(`PROFIT_SLIPPAGE_BPS=1000`)를
`minProfit` 으로 걸어서, 그 사이 누가 가격을 움직이면 거래가 되돌아갑니다.

`MIN_PROFIT` 은 가스비보다 크게 잡아야 적자 거래가 안 나옵니다. 컨트랙트는 토큰 기준으로만
이익을 확인하고 가스비는 모릅니다.

## 5. 한계와 주의점

- **재고 방식입니다.** 플래시 스왑을 쓰지 않으므로 거래할 토큰을 미리 넣어둬야 합니다.
  대신 흐름이 단순하고 외부 콜백 경로가 V3 하나뿐입니다.
- **가격 표기**: `priceX18` 는 token0 1개당 token1 (원시 단위, 1e18 배)입니다. 데시멀이
  다른 토큰이면 사람이 읽는 가격과 다릅니다. 풀끼리 비교에는 영향이 없습니다.
- **MEV**: 키퍼 트랜잭션은 공개 멤풀에 올라가므로 선행거래를 당할 수 있습니다.
  `minProfit` 이 손실은 막아주지만 기회는 뺏길 수 있습니다.
- V3 수량 탐색은 이익 곡선이 볼록(concave)하다는 전제의 삼분탐색입니다. 지원하는 곡선은
  모두 그렇지만, 반복 횟수가 적으면 최적값에서 조금 벗어날 수 있습니다.
- 수수료를 떼는 토큰(fee-on-transfer)은 잔고 차이로 계산하므로 동작은 하지만, 닫힌 식
  견적은 전송 수수료를 모르므로 실제보다 이익을 높게 봅니다. 그런 토큰은 탐색 쪽을 쓰세요.
