module.exports = async ({
  getNamedAccounts,
  deployments
}) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  // DSProxy
  await deploy('DSProxyFactory', {
    from: deployer,
    log: true,
    args: [],
    deterministicDeployment: true,
  });
};