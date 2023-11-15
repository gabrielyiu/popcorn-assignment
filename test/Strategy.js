const { expect } = require("chai");

describe("Strategy", () => {
  let owner;
  let strategy;
  
  before(async() => {
      [owner] = await ethers.getSigners();

      const Strategy = await ethers.getContractFactory("Strategy");
      strategy = await Strategy.deploy();
  });
});
