const HDWalletProvider = require('truffle-hdwallet-provider');
const fs = require('fs');
require('dotenv').config();
const mnemonic = process.env.MNEMONIC

module.exports = {
  plugins: [
    'truffle-plugin-verify'
  ],
  api_keys: {
    bscscan: process.env.BSCSCANAPIKEY
  },
  networks: {
    development: {
      host: 'localhost', // Localhost (default: none)
      port: 9545, // Standard Ethereum port (default: none)
      network_id: '*', // Any network (default: none)
      gas: 6721975
    },
    coverage: {
      host: 'localhost',
      network_id: '*',
      port: 8555,
      gas: 0xfffffffffff,
      gasPrice: 0x01
    },
    testnet: {
      provider: () => new HDWalletProvider(mnemonic, `https://data-seed-prebsc-1-s1.binance.org:8545`),
      network_id: 97,
      confirmations: 10,
      timeoutBlocks: 200,
      skipDryRun: true
    },
    bsc: {
      provider: () => new HDWalletProvider(mnemonic, `https://bsc-dataseed1.binance.org`),
      network_id: 56,
      confirmations: 10,
      timeoutBlocks: 200,
      skipDryRun: true
    },
  },

  // Set default mocha options here, use special reporters etc.
  mocha: {
    // timeout: 100000
  },

  // Configure your compilers
  compilers: {
    solc: {
      version: '0.6.12',
      settings: { // See the solidity docs for advice about optimization and evmVersion
        optimizer: {
          enabled: true,
          runs: 200,
        },
        evmVersion: 'istanbul',
      },
    },
  },
  api_keys: {
    etherscan: 'SAUVZ118TAJY1IWST3PB6E9W1AHXGY1USA',
    bscscan: 'SAUVZ118TAJY1IWST3PB6E9W1AHXGY1USA',
  }
}