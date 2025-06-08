const hre = require("hardhat");

async function main() {
  const AgentRegistry = await hre.ethers.getContractFactory("AgentRegistry");
  const agentRegistry = await AgentRegistry.deploy();
  await agentRegistry.deployed();

  console.log("AgentRegistry deployed to:", agentRegistry.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});