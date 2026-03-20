const hre = require("hardhat");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with:", deployer.address);

  const MYAI_TOKEN  = "0xAfF22CC20434ce43B3ea10efe10e9360390D327c";
  const COORDINATOR = deployer.address; // Update to coordinator wallet
  const TREASURY    = deployer.address; // Update to treasury wallet

  // Deploy Escrow
  const Escrow = await hre.ethers.getContractFactory("MyAIEscrow");
  const escrow = await Escrow.deploy(MYAI_TOKEN, COORDINATOR, TREASURY);
  await escrow.waitForDeployment();
  console.log("MyAIEscrow deployed:", await escrow.getAddress());

  // Deploy Reputation
  const Reputation = await hre.ethers.getContractFactory("MyAIReputation");
  const reputation = await Reputation.deploy(COORDINATOR, MYAI_TOKEN);
  await reputation.waitForDeployment();
  console.log("MyAIReputation deployed:", await reputation.getAddress());

  // Deploy Governance
  const Governance = await hre.ethers.getContractFactory("MyAIGovernance");
  const governance = await Governance.deploy(await reputation.getAddress());
  await governance.waitForDeployment();
  console.log("MyAIGovernance deployed:", await governance.getAddress());

  console.log("\n=== Deployment Summary ===");
  console.log("MyAIEscrow:     ", await escrow.getAddress());
  console.log("MyAIReputation: ", await reputation.getAddress());
  console.log("MyAIGovernance: ", await governance.getAddress());
}

main().catch(console.error);
