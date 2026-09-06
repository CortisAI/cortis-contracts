require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

// Never hardcode a private key. Deployer key + RPC come from env only.
const DEPLOYER_PRIVATE_KEY = process.env.DEPLOYER_PRIVATE_KEY || "";
const OPBNB_RPC =
  process.env.OPBNB_RPC || "https://opbnb-mainnet-rpc.bnbchain.org";
const OPBNBSCAN_API_KEY = process.env.OPBNBSCAN_API_KEY || "";

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    hardhat: {},
    opbnb: {
      url: OPBNB_RPC,
      chainId: 204,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : [],
    },
  },
  // opbnbscan verification (Etherscan-compatible). Fill OPBNBSCAN_API_KEY to verify.
  etherscan: {
    apiKey: {
      opbnb: OPBNBSCAN_API_KEY,
    },
    customChains: [
      {
        network: "opbnb",
        chainId: 204,
        urls: {
          apiURL: "https://api-opbnb.bscscan.com/api",
          browserURL: "https://opbnb.bscscan.com",
        },
      },
    ],
  },
};
