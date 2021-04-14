module.exports = async ({
  getNamedAccounts,
  deployments
}) => {
  const { deploy } = deployments;
  const { deployer } = await getNamedAccounts();
  // Factory
  await deploy('BActions', {
    from: deployer,
    log: true,
    args: [],
    deterministicDeployment: true,
  });
};