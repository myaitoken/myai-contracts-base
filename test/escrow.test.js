const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("MyAIEscrow", function () {
  let escrow, mockToken;
  let owner, coordinator, requester, provider, treasury;
  const JOB_ID = ethers.encodeBytes32String("job-001");
  const AMOUNT  = ethers.parseEther("100");

  beforeEach(async function () {
    [owner, coordinator, requester, provider, treasury] = await ethers.getSigners();

    // Deploy a minimal ERC20 mock
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    mockToken = await MockERC20.deploy("MyAI Token", "MYAI", ethers.parseEther("1000000"));
    await mockToken.waitForDeployment();

    // Fund requester
    await mockToken.transfer(requester.address, ethers.parseEther("1000"));

    // Deploy escrow
    const Escrow = await ethers.getContractFactory("MyAIEscrow");
    escrow = await Escrow.deploy(
      await mockToken.getAddress(),
      coordinator.address,
      treasury.address
    );
    await escrow.waitForDeployment();

    // Approve escrow to spend requester's tokens
    await mockToken.connect(requester).approve(await escrow.getAddress(), AMOUNT);
  });

  it("should lock payment and emit PaymentLocked", async function () {
    await expect(
      escrow.connect(requester).lockPayment(JOB_ID, provider.address, AMOUNT)
    ).to.emit(escrow, "PaymentLocked")
     .withArgs(JOB_ID, requester.address, provider.address, AMOUNT);

    const e = await escrow.getEscrow(JOB_ID);
    expect(e.status).to.equal(0); // Locked
    expect(e.amount).to.equal(AMOUNT);
  });

  it("should release payment with correct splits", async function () {
    await escrow.connect(requester).lockPayment(JOB_ID, provider.address, AMOUNT);

    const pocHash = ethers.encodeBytes32String("poc-hash-001");
    await escrow.connect(coordinator).releasePayment(JOB_ID, pocHash);

    const providerBal = await mockToken.balanceOf(provider.address);
    const burnBal     = await mockToken.balanceOf("0x000000000000000000000000000000000000dEaD");
    const treasuryBal = await mockToken.balanceOf(treasury.address);

    expect(providerBal).to.equal(ethers.parseEther("73"));  // 73%
    expect(burnBal).to.equal(ethers.parseEther("20"));      // 20%
    expect(treasuryBal).to.equal(ethers.parseEther("7"));   // 7%
  });

  it("should refund requester on PoC failure", async function () {
    await escrow.connect(requester).lockPayment(JOB_ID, provider.address, AMOUNT);

    const balBefore = await mockToken.balanceOf(requester.address);
    await escrow.connect(coordinator).refundPayment(JOB_ID);
    const balAfter = await mockToken.balanceOf(requester.address);

    expect(balAfter - balBefore).to.equal(AMOUNT);
  });

  it("should prevent double-locking the same jobId", async function () {
    await escrow.connect(requester).lockPayment(JOB_ID, provider.address, AMOUNT);
    await mockToken.connect(requester).approve(await escrow.getAddress(), AMOUNT);
    await expect(
      escrow.connect(requester).lockPayment(JOB_ID, provider.address, AMOUNT)
    ).to.be.revertedWith("Job already escrowed");
  });

  it("should allow requester to claim expired escrow", async function () {
    await escrow.connect(requester).lockPayment(JOB_ID, provider.address, AMOUNT);

    // Fast-forward time
    await ethers.provider.send("evm_increaseTime", [3601]);
    await ethers.provider.send("evm_mine");

    await escrow.connect(requester).claimExpired(JOB_ID);
    const e = await escrow.getEscrow(JOB_ID);
    expect(e.status).to.equal(3); // Expired
  });
});
