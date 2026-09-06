const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CortisPassport (soulbound)", function () {
  let passport, owner, alice, bob;

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();
    const Passport = await ethers.getContractFactory("CortisPassport");
    passport = await Passport.deploy(owner.address);
    await passport.waitForDeployment();
  });

  it("mints a passport to the caller and emits PassportMinted", async function () {
    await expect(passport.connect(alice).mintPassport("COR-AAA111", "ipfs://a"))
      .to.emit(passport, "PassportMinted")
      .withArgs(alice.address, 1n, "COR-AAA111");

    expect(await passport.ownerOf(1)).to.equal(alice.address);
    expect(await passport.agentIdOf(1)).to.equal("COR-AAA111");
    expect(await passport.tokenURI(1)).to.equal("ipfs://a");
    expect(await passport.passportsOf(alice.address)).to.equal(1n);
    expect(await passport.totalMinted()).to.equal(1n);
  });

  it("lets one wallet hold multiple passports (one per agent) with incrementing ids", async function () {
    await passport.connect(alice).mintPassport("COR-A", "ipfs://1");
    await passport.connect(alice).mintPassport("COR-B", "ipfs://2");
    await passport.connect(alice).mintPassport("COR-C", "ipfs://3");

    expect(await passport.passportsOf(alice.address)).to.equal(3n);
    expect(await passport.ownerOf(2)).to.equal(alice.address);
    expect(await passport.agentIdOf(3)).to.equal("COR-C");
    expect(await passport.totalMinted()).to.equal(3n);
  });

  it("blocks transferFrom between two wallets (soulbound)", async function () {
    await passport.connect(alice).mintPassport("COR-A", "ipfs://1");
    await expect(
      passport.connect(alice).transferFrom(alice.address, bob.address, 1)
    ).to.be.revertedWithCustomError(passport, "SoulboundNonTransferable");
  });

  it("blocks safeTransferFrom between two wallets (soulbound)", async function () {
    await passport.connect(alice).mintPassport("COR-A", "ipfs://1");
    await expect(
      passport
        .connect(alice)
        ["safeTransferFrom(address,address,uint256)"](alice.address, bob.address, 1)
    ).to.be.revertedWithCustomError(passport, "SoulboundNonTransferable");
  });

  it("blocks approve and setApprovalForAll", async function () {
    await passport.connect(alice).mintPassport("COR-A", "ipfs://1");
    await expect(
      passport.connect(alice).approve(bob.address, 1)
    ).to.be.revertedWithCustomError(passport, "SoulboundNonTransferable");
    await expect(
      passport.connect(alice).setApprovalForAll(bob.address, true)
    ).to.be.revertedWithCustomError(passport, "SoulboundNonTransferable");
  });

  it("allows the owner to burn their own passport and decrements count", async function () {
    await passport.connect(alice).mintPassport("COR-A", "ipfs://1");
    await expect(passport.connect(alice).burnPassport(1))
      .to.emit(passport, "PassportBurned")
      .withArgs(alice.address, 1n);
    expect(await passport.passportsOf(alice.address)).to.equal(0n);
    await expect(passport.ownerOf(1)).to.be.reverted;
  });

  it("prevents a non-owner from burning a passport", async function () {
    await passport.connect(alice).mintPassport("COR-A", "ipfs://1");
    await expect(
      passport.connect(bob).burnPassport(1)
    ).to.be.revertedWithCustomError(passport, "NotPassportOwner");
  });
});
