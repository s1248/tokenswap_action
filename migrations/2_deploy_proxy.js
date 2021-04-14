const RightsManager = artifacts.require('RightsManager');
const SmartPoolManager = artifacts.require('SmartPoolManager');
const CRPFactory = artifacts.require('CRPFactory');
const KalancerSafeMath = artifacts.require('KalancerSafeMath');
const BActions = artifacts.require('BActions');
const BFactory = artifacts.require('BFactory');

module.exports = async function(deployer, network, accounts) {
    if (network === 'development' || network === 'soliditycoverage') {
        await deployer.deploy(RightsManager);
        await deployer.deploy(SmartPoolManager);
        await deployer.deploy(BFactory);
        await deployer.deploy(KalancerSafeMath);

        await deployer.link(KalancerSafeMath, CRPFactory);
        await deployer.link(RightsManager, CRPFactory);
        await deployer.link(SmartPoolManager, CRPFactory);

        await deployer.deploy(CRPFactory);

        await deployer.deploy(BActions, BFactory.address);
    } else if (network === 'testnet') {
        await deployer.deploy(BActions, '0x9B41FeB721bF9d3b3B2ae4F6ea40a73C05da84E1'); // BFactory
    } else {
        // MUST change this value
        // to BFactory address before deploy
        const KFactoryAddress = '0xF6e18c0ec06cc7d073FAa7C33dbD330307bC5D60'; // BFactory address
        // Guard to save BNB 
        if (!KFactoryAddress) {
          throw new Error('KFactoryAddress not included');
        }
      await deployer.deploy(BActions, KFactoryAddress); // BFactory
    }
}
