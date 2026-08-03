# SERIES9DEX

Series9 탈중앙화 거래소. ANY/ANY ERC-20 페어에 대한 AMM 현물 풀, 완전 온체인 오더북, 선물(perp) 풀을 제공합니다.

설계 명세는 [`docs/DEX.md`](docs/DEX.md) 참고.

## 컨트랙트

| 컨트랙트 | 파일 | 역할 |
|----------|------|------|
| `DexRegistry` | [`src/DexRegistry.sol`](src/DexRegistry.sol) | 페어/풀 등록 및 조회 (UUPS) |
| `SpotPool` | [`src/SpotPool.sol`](src/SpotPool.sol) | AMM 현물 풀, LP 토큰 |
| `SpotPoolFactory` | [`src/SpotPoolFactory.sol`](src/SpotPoolFactory.sol) | 현물 풀 배포 |
| `Orderbook` | [`src/Orderbook.sol`](src/Orderbook.sol) | 온체인 지정가 오더북 |
| `PerpPool` | [`src/PerpPool.sol`](src/PerpPool.sol) | 선물 포지션/담보 |
| `PerpPoolFactory` | [`src/PerpPoolFactory.sol`](src/PerpPoolFactory.sol) | 선물 풀 배포 |
| `ProtocolTreasury` | [`src/ProtocolTreasury.sol`](src/ProtocolTreasury.sol) | 프로토콜 수수료 수취 (UUPS) |

수수료: 풀 생성자가 `lpFee`를 설정하고, 그중 0.1%가 `ProtocolTreasury`로, 나머지 99.9%가 LP에게 분배됩니다.

## 개발

```bash
git clone --recurse-submodules https://github.com/PIXELZX0/SERIES9DEX.git
forge build
forge test
forge snapshot --check   # .gas-snapshot 대조
```

## 배포

```bash
forge script script/DeployDex.s.sol:DeployDex \
  --rpc-url "$MONAD_RPC_URL" --private-key "$PRIVATE_KEY" --broadcast
```

## 관련 레포

- [SERIES9](https://github.com/PIXELZX0/SERIES9) — SER9 토큰 + 스테이킹
- [SERIES9Identity](https://github.com/PIXELZX0/SERIES9Identity) — Identity NFT + 지갑
- [SERIES9_Front](https://github.com/PIXELZX0/SERIES9_Front) — 웹 프론트엔드
