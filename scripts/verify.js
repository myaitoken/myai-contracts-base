const hre = require("hardhat");

// Update these after deployment
const DEPLOYED = {
  MyAIEscrow:      process.env.ESCROW_ADDRESS     || "",
  MyAIReputation:  process.env.REPUTATION_ADDRESS || "",
  MyAIGovernance:  process.env.GOVERNANCE_ADDRESS || "",
};

const MYAI_TOKEN  = "0xAfF22CC20434ce43B3ea10efe10e9360390D327c";
const COORDINATOR = process.env.COORDINATOR_ADDRESS || "";
const TREASURY    = process.env.TREASURY_ADDRESS    || "";

async function main() {
  console.log("Verifying contracts on Basescan...");

  if (DEPLOYED.MyAIEscrow) {
    await hre.run("verify:verify", {
      address: DEPLOYED.MyAIEscrow,
      constructorArguments: [MYAI_TOKEN, COORDINATOR, TREASURY],
    });
    console.log("MyAIEscrow verified.");
  }

  if (DEPLOYED.MyAIReputation) {
    await hre.run("verify:verify", {
      address: DEPLOYED.MyAIReputation,
      constructorArguments: [COORDINATOR, MYAI_TOKEN],
    });
    console.log("MyAIReputation verified.");
  }

  if (DEPLOYED.MyAIGovernance) {
    await hre.run("verify:verify", {
      address: DEPLOYED.MyAIGovernance,
      constructorArguments: [DEPLOYED.MyAIReputation],
    });
    console.log("MyAIGovernance verified.");
  }
}

main().catch(console.error);
