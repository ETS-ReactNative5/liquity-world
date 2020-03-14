import { Wallet } from "ethers";
import { task, usePlugin, BuidlerConfig } from "@nomiclabs/buidler/config";
import { NetworkConfig } from "@nomiclabs/buidler/types";

import { deployAndSetupContracts, setSilent } from "./test/utils/deploy";
import { Liquity, Trove } from "./src/Liquity";
import { Decimal } from "./utils";
import { CDPManagerFactory } from "./types/ethers/CDPManagerFactory";
import { PoolManagerFactory } from "./types/ethers/PoolManagerFactory";
import { PriceFeedFactory } from "./types/ethers/PriceFeedFactory";
import { NameRegistryFactory } from "./types/ethers/NameRegistryFactory";
import { LiquityContractAddresses, addressesOf } from "./src/contracts";

usePlugin("@nomiclabs/buidler-web3");
usePlugin("@nomiclabs/buidler-truffle5");
usePlugin("@nomiclabs/buidler-waffle");

const generateRandomAccounts = (numberOfAccounts: number) => {
  const accounts = new Array<string>(numberOfAccounts);

  for (let i = 0; i < numberOfAccounts; ++i) {
    accounts[i] = Wallet.createRandom().privateKey;
  }

  return accounts;
};

const deployerAccount = "0x543ab4105a87fa14619bad9b85b6e989412b2f30380a3f36f49b9327b5967fb1";
const devChainRichAccount = "0x4d5db4107d237df6a3d58ee5f70ae63d73d7658d4026f2eefd2f204c81682cb7";

const infuraApiKey = "ad9cef41c9c844a7b54d10be24d416e5";

const infuraNetwork = (name: string): { [name: string]: NetworkConfig } => ({
  [name]: {
    url: `https://${name}.infura.io/v3/${infuraApiKey}`,
    accounts: [deployerAccount]
  }
});

const config: BuidlerConfig = {
  defaultNetwork: "buidlerevm",
  networks: {
    dev: {
      url: "http://localhost:8545",
      accounts: [deployerAccount, devChainRichAccount, ...generateRandomAccounts(10)]
    },
    ...infuraNetwork("ropsten"),
    ...infuraNetwork("rinkeby"),
    ...infuraNetwork("goerli"),
    ...infuraNetwork("kovan")
  },
  paths: {
    artifacts: "../contracts/artifacts",
    cache: "../contracts/cache"
  }
};

const addressesOnNetwork: { [network: string]: LiquityContractAddresses } = {
  dev: {
    activePool: "0x788b1f7A4976279305E43A08a5419F95B3B5545a",
    cdpManager: "0x086063A27f505b8eA5a0E65F2A34B26197ef419C",
    clvToken: "0x9FB0a538EC610e4fafb7d50338d417E6643463CB",
    defaultPool: "0x3B7af23BB5B69951c677D39dAe0809C7f3231E50",
    nameRegistry: "0xa650242F20F748bB861067FDe7B7766Ac17f3e64",
    poolManager: "0x35b7c50900b5B188536138f43cc6E1b978abF009",
    priceFeed: "0x74d37CE7E7210401a3432F8c49590723b3e211D2",
    sortedCDPs: "0x2142F04f584076a1783f6d86159bac83D10256d9",
    stabilityPool: "0xdB00Fbb08Fa75c77324661Cf46625d7399e954aB"
  },
  ropsten: {
    activePool: "0xc9E61022f5dBDF504a58afa76aacC4220079A9a4",
    cdpManager: "0x28c941d6A29b86036C18249C175CE2084f3983e7",
    clvToken: "0x44027D91b96edEC05fA68FAB4a63f4FafF8a3215",
    defaultPool: "0xfb34D074b790BbDFC33D8ded25429E911D04F46e",
    nameRegistry: "0x2068AeCa3506ad11E6271c2EF243a3288b9aF58E",
    poolManager: "0x9cfdce391bEFe2cf01ce6F3dAb4A44fC0DE272BE",
    priceFeed: "0x6dAC2E9E108E3CeA3cF52f3229C85491E4fddAdB",
    sortedCDPs: "0xe6a00Af68CB07c1fF7Bb1fd5Ec7fdC3ea562F018",
    stabilityPool: "0xF51951d51886ecd7b553C585238bb5Ab252400cB"
  },
  rinkeby: {
    activePool: "0x710E14FBbaC14D819Be9a21E2089ebfdb8e3a95E",
    cdpManager: "0x907CC782Eb562BDce0191be0ceC8Cace3F00E081",
    clvToken: "0xD2E0086c18548ece90ffC48586D2f5Ef21b39A51",
    defaultPool: "0x9f8303f5D0fADc491EF92618aEDeCdbb228bd91f",
    nameRegistry: "0xC8A56BbA9d51214c5F09D4553e10895ff4777402",
    poolManager: "0x5ADc1B1ba342597c1525f5D551F614B9D250925E",
    priceFeed: "0x92E8FF4272e15983246418770FD076830Ff2E745",
    sortedCDPs: "0xdedDCEA0E907472A91430633B7f7dF0FAf78eD61",
    stabilityPool: "0x13eb8b14Da95b061F641eCeDc2EF1728e45972ad"
  },
  goerli: {
    activePool: "0x1C4C34CEba6Db2Cf7F02D74D3A6A3501D0E5e76B",
    cdpManager: "0x710E14FBbaC14D819Be9a21E2089ebfdb8e3a95E",
    clvToken: "0x907CC782Eb562BDce0191be0ceC8Cace3F00E081",
    defaultPool: "0xD2E0086c18548ece90ffC48586D2f5Ef21b39A51",
    nameRegistry: "0x9f8303f5D0fADc491EF92618aEDeCdbb228bd91f",
    poolManager: "0xC8A56BbA9d51214c5F09D4553e10895ff4777402",
    priceFeed: "0x5ADc1B1ba342597c1525f5D551F614B9D250925E",
    sortedCDPs: "0x92E8FF4272e15983246418770FD076830Ff2E745",
    stabilityPool: "0xdedDCEA0E907472A91430633B7f7dF0FAf78eD61"
  },
  kovan: {
    activePool: "0x8Aded274EB4B31a740945f0933eA2d0757350921",
    cdpManager: "0xecbc0A33CBf929DadD1D64B5E7A6247041402314",
    clvToken: "0x7A088435468F894A7Bb59fE9B92700570E0f884c",
    defaultPool: "0xEddE64C273aC266FC2758652b0BBaeE565808d34",
    nameRegistry: "0x3aC1A85a427227C83A3aE95Accd2022Fa1d6352A",
    poolManager: "0xABA1eD61d4224831FE0e96F1054DD989FDd42310",
    priceFeed: "0x5C3B80A5A5517567905a77d5DbBDeB455b174C5b",
    sortedCDPs: "0x6B681d4C1F835E236639F46929530a92a90768B1",
    stabilityPool: "0xa77975FaCaA6dC5E8e436D39CdA52A4D398D10B2"
  }
};

task("deploy", "Deploys the contracts to the network", async (_taskArgs, bre) => {
  const [deployer] = await bre.ethers.signers();

  setSilent(false);
  const contracts = await deployAndSetupContracts(bre.web3, bre.artifacts, deployer);

  console.log();
  console.log(addressesOf(contracts));
  console.log();
});

task(
  "update-pricefeed",
  "Deploys the latest version of PriceFeed then introduces it to other contracts",
  async (_taskArgs, bre) => {
    const [deployer] = await bre.ethers.signers();
    const addresses = addressesOnNetwork[bre.network.name];

    addresses.priceFeed = (await bre.artifacts.require("PriceFeed").new()).address;

    const priceFeed = PriceFeedFactory.connect(addresses.priceFeed, deployer);
    const cdpManager = CDPManagerFactory.connect(addresses.cdpManager, deployer);
    const poolManager = PoolManagerFactory.connect(addresses.poolManager, deployer);
    const nameRegistry = NameRegistryFactory.connect(addresses.nameRegistry, deployer);

    await priceFeed.setCDPManagerAddress(cdpManager.address);
    await cdpManager.setPriceFeed(priceFeed.address);
    await poolManager.setPriceFeed(priceFeed.address);
    await nameRegistry.updateAddress("PriceFeed", priceFeed.address);

    for (const [contractName, address] of Object.entries(addresses)) {
      console.log(`${contractName}: "${address}",`);
    }
  }
);

task(
  "deploy-warzone",
  "Deploys the contracts to the network then creates lots of Troves",
  // TODO: for some reason Buidler can't seem to handle much more than 40 accounts with an external
  // network, so this task must be called repeatedly (e.g. in an infinite loop) to actually create
  // many Troves.
  async (_taskArgs, bre) => {
    const [deployer, ...users] = await bre.ethers.signers();
    const addresses = addressesOnNetwork[bre.network.name];

    const liquity = await Liquity.connect(
      addresses.cdpManager,
      bre.waffle.provider,
      await deployer.getAddress()
    );

    const price = await liquity.getPrice();
    const priceAsNumber = parseFloat(price.toString(4));

    let i = 0;
    for (const user of users) {
      const userAddress = await user.getAddress();
      const collateral = 999 * Math.random() + 1;
      const debt = (priceAsNumber * collateral) / (3 * Math.random() + 1.11);

      const liquity = await Liquity.connect(addresses.cdpManager, bre.waffle.provider, userAddress);

      await deployer.sendTransaction({
        to: userAddress,
        value: Decimal.from(collateral).bigNumber
      });

      await liquity.createTrove(new Trove({ collateral, debt }), price);
      await liquity.depositQuiInStabilityPool(debt);

      if (++i % 10 === 0) {
        console.log(`Created ${i} Troves.`);
      }
    }
  }
);

export default config;
