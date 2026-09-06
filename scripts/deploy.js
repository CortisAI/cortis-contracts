// Deploys CortisPassport then CortisEngagement, wires them together,
// prints addresses and writes them to deployments/opbnb.json.
//
// SAFE TO RUN against the in-memory hardhat network to prove it works:
//   npx hardhat run scripts/deploy.js
//
// To deploy for real on opBNB (only when funded + reviewed):
//   npx hardhat run scripts/deploy.js --network opbnb
//
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const net = hre.network.name;
  console.log(`Network: ${net}`);
  console.log(`Deployer: ${deployer.address}`);

  const bal = await hre.ethers.provider.getBalance(deployer.address);
  console.log(`Deployer balance: ${hre.ethers.formatEther(bal)} BNB`);

  // 1) Passport (soulbound ERC721)
  const Passport = await hre.ethers.getContractFactory("CortisPassport");
  const passport = await Passport.deploy(deployer.address);
  await passport.waitForDeployment();
  const passportAddr = await passport.getAddress();
  console.log(`CortisPassport deployed:   ${passportAddr}`);

  // 2) Engagement (Ownable)
  const Engagement = await hre.ethers.getContractFactory("CortisEngagement");
  const engagement = await Engagement.deploy(deployer.address);
  await engagement.waitForDeployment();
  const engagementAddr = await engagement.getAddress();
  console.log(`CortisEngagement deployed: ${engagementAddr}`);

  // 3) Wire engagement -> passport for attestation ownership checks
  const tx = await engagement.setPassport(passportAddr);
  await tx.wait();
  console.log(`engagement.setPassport(${passportAddr}) ✓`);

  // 4) Persist addresses
  const out = {
    network: net,
    chainId: 204,
    deployer: deployer.address,
    passport: passportAddr,
    engagement: engagementAddr,
    deployedAt: new Date().toISOString(),
  };
  const dir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${net === "opbnb" ? "opbnb" : net}.json`);
  fs.writeFileSync(file, JSON.stringify(out, null, 2));
  console.log(`Addresses written to ${file}`);

  console.log("\n── Paste into app/public/js/contracts.js ADDRESSES ──");
  console.log(`  passport:   "${passportAddr}",`);
  console.log(`  engagement: "${engagementAddr}",`);
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
