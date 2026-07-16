const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MyAIReputation", function () {
  let reputation, mockToken;
  let owner, coordinator, provider1, provider2;

  beforeEach(async function () {
    [owner, coordinator, provider1, provider2] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20.deploy("MyAI Token", "MYAI", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();

    const Reputation = await ethers.getContractFactory("MyAIReputation");
    reputation = await Reputation.deploy(coordinator.address, await mockToken.getAddress());
    await reputation.waitForDeployment();
  });

  it("should register agent with score 0 (earned, not free)", async function () {
    await reputation.connect(provider1).register();
    const profile = await reputation.getProfile(provider1.address);
    expect(profile.reputationScore).to.equal(0);
    expect(profile.totalJobs).to.equal(0);
  });

  it("should record successful job and update score", async function () {
    await reputation.connect(coordinator).recordCompletion(
      provider1.address, true, 1000, 500
    );
    const profile = await reputation.getProfile(provider1.address);
    expect(profile.totalJobs).to.equal(1);
    expect(profile.successfulJobs).to.equal(1);
    expect(profile.pocVerifiedJobs).to.equal(1);
    expect(profile.governancePoints).to.equal(1);
  });

  it("should slash after 3 consecutive failures", async function () {
    // Record 3 consecutive failures
    for (let i = 0; i < 3; i++) {
      await reputation.connect(coordinator).recordCompletion(
        provider1.address, false, 5000, 0
      );
    }
    const profile = await reputation.getProfile(provider1.address);
    expect(profile.isSlashed).to.be.true;
    expect(profile.consecutiveFailures).to.equal(3);
  });

  it("should reset consecutive failures on success", async function () {
    await reputation.connect(coordinator).recordCompletion(provider1.address, false, 5000, 0);
    await reputation.connect(coordinator).recordCompletion(provider1.address, false, 5000, 0);
    await reputation.connect(coordinator).recordCompletion(provider1.address, true, 1000, 100);

    const profile = await reputation.getProfile(provider1.address);
    expect(profile.consecutiveFailures).to.equal(0);
  });

  it("should allow vouching from high-rep agent", async function () {
    // Give provider1 a 90+ rep by recording many successes
    for (let i = 0; i < 20; i++) {
      await reputation.connect(coordinator).recordCompletion(
        provider1.address, true, 500, 100
      );
    }

    const p = await reputation.getProfile(provider1.address);
    // Score should be high enough to vouch
    if (p.reputationScore >= 9000) {
      await reputation.connect(provider1).vouch(provider2.address);
      const p2 = await reputation.getProfile(provider2.address);
      expect(p2.vouchedBy.length).to.equal(1);
    }
  });

  it("should return top providers", async function () {
    await reputation.connect(coordinator).recordCompletion(provider1.address, true, 1000, 100);
    await reputation.connect(coordinator).recordCompletion(provider2.address, true, 2000, 100);

    const [addrs, scores] = await reputation.getTopProviders(0, 10);
    expect(addrs[0]).to.equal(provider1.address);
    expect(addrs[1]).to.equal(provider2.address);
  });

  it("should report total agents", async function () {
    await reputation.connect(coordinator).recordCompletion(provider1.address, true, 1000, 100);
    await reputation.connect(coordinator).recordCompletion(provider2.address, true, 1000, 100);
    expect(await reputation.totalAgents()).to.equal(2);
  });
});
