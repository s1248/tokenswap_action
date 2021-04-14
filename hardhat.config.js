require('@nomiclabs/hardhat-waffle');
require('@nomiclabs/hardhat-ethers');
require('@nomiclabs/hardhat-etherscan');
require('hardhat-deploy');
// require('hardhat-deploy');
// This is a sample Hardhat task. To learn how to create your own go to
// https://hardhat.org/guides/create-task.html
task('accounts', 'Prints the list of accounts', async () => {
  const accounts = await ethers.getSigners();

  for (const account of accounts) {
    console.log(account.address);
  }
});

module.exports = {
  solidity: {
    version: "0.6.12",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1000,
      },
    },
  },
  defaultNetwork: 'hardhat',
  namedAccounts: {
    deployer: {
      default: 0,
    },
  },
  networks: {
    bsc: {
      url: 'https://bsc-dataseed1.binance.org',
      accounts: ['private-key-here']
    },
    testnet: {
      url: 'https://data-seed-prebsc-1-s1.binance.org:8545',
      accounts: ['private-key-here']
    },
    kovan: {
      url: 'https://eth-kovan.alchemyapi.io/v2/voa3n4HdJlkxy5fwfVZ4OhSwxGzv01y2',
      accounts: ['private-key-here'],
      live: true,
      saveDeployments: true,
    }
  },
  etherscan: {
    apiKey: 'VU7SX55SS1NJ1S85HDKN1REWYZTRCC9ZGZ'
  },
};