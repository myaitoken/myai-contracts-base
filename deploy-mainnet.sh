#!/usr/bin/env bash
# MyAi Contract Deployment — Base Mainnet
# Usage: DEPLOYER_PRIVATE_KEY=0x... bash deploy-mainnet.sh
set -euo pipefail
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "Usage: DEPLOYER_PRIVATE_KEY=0x<your-key> bash deploy-mainnet.sh"
  exit 1
fi
echo "Deploying MyAi contracts to Base mainnet..."
DEPLOYER_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" \
  BASE_RPC_URL="https://mainnet.base.org" \
  npx hardhat run scripts/deploy.js --network base
echo ""
echo "Add the printed addresses to:"
echo "  - /home/jason/myai-coordinator/.env  (ESCROW_ADDRESS, REPUTATION_ADDRESS, GOVERNANCE_ADDRESS)"
echo "  - /opt/billing/.env                  (same vars)"
echo "Then restart: systemctl restart myai-coordinator && pm2 restart myai-payment-watcher --update-env"
