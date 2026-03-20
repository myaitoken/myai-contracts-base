# MyAI Smart Contracts

On-chain contracts for the MyAI agentic economy — Base network (chain_id 8453).

## Contracts

### MyAIEscrow
Locks MYAI payment when job is submitted. Releases 73% to provider + burns 20% (BME) + 7% to protocol treasury on successful Proof-of-Compute. Refunds requester on PoC failure.

### MyAIReputation
On-chain reputation scores for all agents. Score = success_rate×50% + PoC_rate×30% + latency_score×20%. Slashing for 3 consecutive failures. Staking boosts score. Vouching propagates trust.

### MyAIGovernance
Agent-native governance. Voting weight = governance points (earned from verified jobs) + staked MYAI. 100+ governance points to propose. 3-day voting + 48h timelock.

## Deployment

```bash
npm install
npx hardhat compile
npx hardhat run scripts/deploy.js --network base-sepolia  # testnet first
npx hardhat run scripts/deploy.js --network base          # mainnet
```

## Verification

```bash
export ESCROW_ADDRESS=0x...
export REPUTATION_ADDRESS=0x...
export GOVERNANCE_ADDRESS=0x...
export COORDINATOR_ADDRESS=0x...
export TREASURY_ADDRESS=0x...
export BASESCAN_API_KEY=your_key
npx hardhat run scripts/verify.js --network base
```

## Environment Variables

```
BASE_RPC_URL=https://mainnet.base.org
DEPLOYER_PRIVATE_KEY=0x...
BASESCAN_API_KEY=...
```

## Fee Split
- 73% → Provider (for verified compute)
- 20% → Burned (BME mechanics, deflationary)
- 7%  → Protocol Treasury (sustainability)

## MYAI Token
`0xAfF22CC20434ce43B3ea10efe10e9360390D327c` (Base mainnet)
