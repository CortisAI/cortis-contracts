const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 24 * 60 * 60;

describe("CortisEngagement", function () {
  let engagement, passport, owner, alice, bob;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const Passport = await ethers.getContractFactory("CortisPassport");
    passport = await Passport.deploy(owner.address);
    await passport.waitForDeployment();

    const Engagement = await ethers.getContractFactory("CortisEngagement");
    engagement = await Engagement.deploy(owner.address);
    await engagement.waitForDeployment();

    await engagement.setPassport(await passport.getAddress());
  });

  describe("checkIn", function () {
    it("allows first check-in, sets streak=1, totalCheckIns=1, awards points", async function () {
      await expect(engagement.connect(alice).checkIn())
        .to.emit(engagement, "CheckedIn")
        .withArgs(alice.address, 1n, 1n, 12n); // 10 base + 1*2 streakBonus

      expect(await engagement.streak(alice.address)).to.equal(1n);
      expect(await engagement.totalCheckIns(alice.address)).to.equal(1n);
      expect(await engagement.points(alice.address)).to.equal(12n);
    });

    it("reverts a second check-in inside the 24h window", async function () {
      await engagement.connect(alice).checkIn();
      await expect(
        engagement.connect(alice).checkIn()
      ).to.be.revertedWithCustomError(engagement, "CheckInTooSoon");
    });

    it("allows a second check-in after 24h and increments the streak", async function () {
      await engagement.connect(alice).checkIn();
      await time.increase(DAY + 60);
      await engagement.connect(alice).checkIn();

      expect(await engagement.streak(alice.address)).to.equal(2n);
      expect(await engagement.totalCheckIns(alice.address)).to.equal(2n);
      // points: first 12 + second (10 + 2*2=14) = 26
      expect(await engagement.points(alice.address)).to.equal(26n);
    });

    it("resets the streak if the gap exceeds 48h", async function () {
      await engagement.connect(alice).checkIn(); // streak 1
      await time.increase(DAY + 60);
      await engagement.connect(alice).checkIn(); // streak 2
      await time.increase(3 * DAY); // > 48h gap
      await engagement.connect(alice).checkIn(); // streak resets to 1

      expect(await engagement.streak(alice.address)).to.equal(1n);
      expect(await engagement.totalCheckIns(alice.address)).to.equal(3n);
    });

    it("is wallet-scoped (independent per user)", async function () {
      await engagement.connect(alice).checkIn();
      await engagement.connect(bob).checkIn();
      expect(await engagement.totalCheckIns(alice.address)).to.equal(1n);
      expect(await engagement.totalCheckIns(bob.address)).to.equal(1n);
      // alice still gated, bob independent
      await expect(
        engagement.connect(alice).checkIn()
      ).to.be.revertedWithCustomError(engagement, "CheckInTooSoon");
    });

    it("timeUntilNextCheckIn returns 0 before first check-in and ~24h after", async function () {
      expect(await engagement.timeUntilNextCheckIn(alice.address)).to.equal(0n);
      await engagement.connect(alice).checkIn();
      const remaining = await engagement.timeUntilNextCheckIn(alice.address);
      expect(remaining).to.be.greaterThan(BigInt(DAY - 10));
      expect(remaining).to.be.lessThanOrEqual(BigInt(DAY));
    });
  });

  describe("attestMap / attestWorkflow", function () {
    const mapHash = ethers.keccak256(ethers.toUtf8Bytes("map-json"));
    const wfHash = ethers.keccak256(ethers.toUtf8Bytes("workflow-json"));

    beforeEach(async function () {
      // alice owns passport #1
      await passport.connect(alice).mintPassport("COR-A", "ipfs://a");
    });

    it("attestMap emits and awards points for the passport owner (unlimited per day)", async function () {
      await expect(engagement.connect(alice).attestMap(1, mapHash))
        .to.emit(engagement, "MapAttested");
      await expect(engagement.connect(alice).attestMap(1, mapHash))
        .to.emit(engagement, "MapAttested");
      expect(await engagement.points(alice.address)).to.equal(10n); // 5 + 5
    });

    it("attestWorkflow emits and awards points for the passport owner", async function () {
      await expect(engagement.connect(alice).attestWorkflow(1, wfHash))
        .to.emit(engagement, "WorkflowAttested");
      expect(await engagement.points(alice.address)).to.equal(5n);
    });

    it("reverts attestMap for a passport the caller does not own", async function () {
      await expect(
        engagement.connect(bob).attestMap(1, mapHash)
      ).to.be.revertedWithCustomError(engagement, "NotAgentOwner");
    });

    it("reverts attestWorkflow for a passport the caller does not own", async function () {
      await expect(
        engagement.connect(bob).attestWorkflow(1, wfHash)
      ).to.be.revertedWithCustomError(engagement, "NotAgentOwner");
    });

    it("reverts when passport contract is not set", async function () {
      const Engagement = await ethers.getContractFactory("CortisEngagement");
      const fresh = await Engagement.deploy(owner.address);
      await fresh.waitForDeployment();
      await expect(
        fresh.connect(alice).attestMap(1, mapHash)
      ).to.be.revertedWithCustomError(fresh, "PassportNotSet");
    });
  });

  describe("owner config", function () {
    it("setPoints updates values and only owner can call", async function () {
      await expect(engagement.connect(alice).setPoints(1, 1, 1, 1)).to.be.reverted;
      await engagement.setPoints(20, 5, 7, 8);
      expect(await engagement.checkInPoints()).to.equal(20n);
      expect(await engagement.streakBonus()).to.equal(5n);
      expect(await engagement.attestMapPoints()).to.equal(7n);
      expect(await engagement.attestWorkflowPoints()).to.equal(8n);
    });

    it("setCorToken stores address (TGE-additive, no logic pre-TGE)", async function () {
      expect(await engagement.corToken()).to.equal(ethers.ZeroAddress);
      await engagement.setCorToken(bob.address);
      expect(await engagement.corToken()).to.equal(bob.address);
    });

    it("only owner can set passport", async function () {
      await expect(
        engagement.connect(alice).setPassport(await passport.getAddress())
      ).to.be.reverted;
    });
  });
});
