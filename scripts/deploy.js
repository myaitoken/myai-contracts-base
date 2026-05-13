const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const MYAI_TOKEN  = "0xAfF22CC20434ce43B3ea10efe10e9360390D327c";
  const TREASURY    = "0xEECf384A2d4D0eaE2EA3980Fb2eDE753Dd6d4716";
  const COORDINATOR = deployer.address;

  const Escrow = await hre.ethers.getContractFactory("MyAIEscrow");
  const escrow = await Escrow.deploy(MYAI_TOKEN, COORDINATOR, TREASURY);
  await escrow.waitForDeployment();
  const escrowAddr = await escrow.getAddress();
  console.log("MyAIEscrow deployed:    ", escrowAddr);

  const Reputation = await hre.ethers.getContractFactory("MyAIReputation");
  const reputation = await Reputation.deploy(COORDINATOR, MYAI_TOKEN);
  await reputation.waitForDeployment();
  const reputationAddr = await reputation.getAddress();
  console.log("MyAIReputation deployed:", reputationAddr);

  const Governance = await hre.ethers.getContractFactory("MyAIGovernance");
  const governance = await Governance.deploy(reputationAddr);
  await governance.waitForDeployment();
  const governanceAddr = await governance.getAddress();
  console.log("MyAIGovernance deployed:", governanceAddr);

  console.log("\n=== Add to coordinator .env ===");
  console.log("ESCROW_ADDRESS=" + escrowAddr);
  console.log("REPUTATION_ADDRESS=" + reputationAddr);
  console.log("GOVERNANCE_ADDRESS=" + governanceAddr);
}

main().catch(console.error);
