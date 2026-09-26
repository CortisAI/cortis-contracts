// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {AgentPassport} from "../src/AgentPassport.sol";
import {CortisEngagement} from "../src/CortisEngagement.sol";
import {NullFeePolicy} from "../src/policies/Policies.sol";

/**
 * Foundry suite for the simplified (proof-free) Cortis engagement core.
 *
 * The attestor / attested-run / boost machinery was removed by product
 * decision: on-chain points are a public, farmable engagement score and reward
 * eligibility is decided off-chain. What remains and is tested here:
 *   - soulbound AgentPassport (transfer/approve disabled, voucher mint, roster)
 *   - per-agent daily check-in (flat +1, streak tracking, one-per-day)
 *   - wallet daily check-in with the accelerating 23*streak + 2*streak^2 curve
 *   - map / workflow / deploy activity events (zero points)
 *   - guardian pause / admin unpause
 */
contract CortisEngagementTest is Test {
    AgentPassport passport;
    CortisEngagement engagement;

    address timelock = makeAddr("timelock");
    address guardian = makeAddr("guardian");
    address owner = makeAddr("owner");
    address other = makeAddr("other");
    address walletA = makeAddr("walletA");

    uint256 issuerKey = 0xA11CE00000000000000000000000000000000000000000000000000000000001;
    address issuer;

    bytes32 constant MINT_VOUCHER_TYPEHASH = keccak256(
        "MintVoucher(address owner,uint16 templateId,bytes32 specializationHash,uint256 nonce,uint48 deadline)"
    );

    function setUp() public {
        issuer = vm.addr(issuerKey);

        passport = new AgentPassport(timelock, issuer, guardian);
        NullFeePolicy fees = new NullFeePolicy();
        // NullFeePolicy is retained for TGE wiring parity but is unused by the
        // simplified engagement core; deploy it to keep the artifact set intact.
        fees;
        engagement = new CortisEngagement(timelock, guardian, address(passport));

        vm.warp(1_800_000_000);
    }

    // ------------------------------------------------------------ soulbound

    function test_passportCannotBeTransferred() public {
        uint256 id = _mint(owner, 1);
        vm.prank(owner);
        vm.expectRevert(AgentPassport.TransferDisabled.selector);
        passport.transferFrom(owner, other, id);
    }

    function test_passportCannotBeApproved() public {
        uint256 id = _mint(owner, 1);
        vm.startPrank(owner);
        vm.expectRevert(AgentPassport.ApprovalDisabled.selector);
        passport.approve(other, id);
        vm.expectRevert(AgentPassport.ApprovalDisabled.selector);
        passport.setApprovalForAll(other, true);
        vm.stopPrank();
    }

    function test_passportReportsLocked() public {
        uint256 id = _mint(owner, 1);
        assertTrue(passport.locked(id));
    }

    function test_nameAndSymbol() public view {
        assertEq(passport.name(), "Cortis Agent Passport");
        assertEq(passport.symbol(), "CORTIS-AP");
    }

    function test_rosterCapIsFive() public {
        for (uint16 i = 0; i < 5; i++) {
            _mint(owner, i + 1);
        }
        assertEq(passport.activeCountOf(owner), 5);
        (uint16 t, bytes32 spec, uint256 n, uint48 d, bytes memory sig) = _voucher(owner, 6, 5);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPassport.RosterFull.selector, owner, 5));
        passport.mint(t, spec, n, d, sig);
    }

    function test_deactivationFreesASlotButKeepsHistory() public {
        uint256 id = _mint(owner, 1);
        for (uint16 i = 0; i < 4; i++) {
            _mint(owner, i + 2);
        }
        vm.prank(owner);
        passport.deactivate(id);
        assertEq(passport.activeCountOf(owner), 4);
        assertEq(passport.ownerOf(id), owner, "history erased");
        _mint(owner, 7); // slot reusable
    }

    function test_voucherCannotBeReplayed() public {
        (uint16 templateId, bytes32 spec, uint256 nonce, uint48 deadline, bytes memory sig) = _voucher(owner, 1, 0);
        vm.prank(owner);
        passport.mint(templateId, spec, nonce, deadline, sig);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AgentPassport.BadVoucherNonce.selector, 1, 0));
        passport.mint(templateId, spec, nonce, deadline, sig);
    }

    function test_voucherIsBoundToItsOwner() public {
        (uint16 templateId, bytes32 spec, uint256 nonce, uint48 deadline, bytes memory sig) = _voucher(owner, 1, 0);
        vm.prank(other);
        vm.expectRevert();
        passport.mint(templateId, spec, nonce, deadline, sig);
    }

    // -------------------------------------------------------- agent check-in

    function test_oneAgentCannotCheckInTwiceOnTheSameDay() public {
        uint256 id = _mint(owner, 1);
        vm.prank(owner);
        engagement.checkIn(id);
        uint32 today = uint32(block.timestamp / 1 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(CortisEngagement.AgentAlreadyCheckedInToday.selector, id, today));
        engagement.checkIn(id);
    }

    function test_sameOwnerCanCheckInSeveralPassportsOnTheSameDay() public {
        uint256[] memory ids = new uint256[](5);
        for (uint16 i = 0; i < 5; i++) {
            ids[i] = _mint(owner, i + 1);
        }
        for (uint256 i = 0; i < 5; i++) {
            vm.prank(owner);
            engagement.checkIn(ids[i]);
            assertTrue(engagement.checkedInToday(ids[i]));
            assertEq(engagement.stateOf(ids[i]).points, 1);
        }
    }

    function test_anotherOwnerCannotCheckInTheAgent() public {
        uint256 id = _mint(owner, 1);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(CortisEngagement.NotPassportOwner.selector, id, other));
        engagement.checkIn(id);
    }

    function test_streakIncrementsOnlyOnConsecutiveAgentActiveDays() public {
        uint256 id = _mint(owner, 1);
        for (uint256 d = 0; d < 4; d++) {
            vm.prank(owner);
            engagement.checkIn(id);
            vm.warp(block.timestamp + 1 days);
        }
        CortisEngagement.AgentState memory s = engagement.stateOf(id);
        assertEq(s.currentStreak, 4);
        assertEq(s.bestStreak, 4);
        assertEq(s.checkInCount, 4);
    }

    function test_agentStreakResetsAfterAGap() public {
        uint256 id = _mint(owner, 1);
        vm.prank(owner);
        engagement.checkIn(id);
        vm.warp(block.timestamp + 3 days);
        vm.prank(owner);
        engagement.checkIn(id);

        CortisEngagement.AgentState memory s = engagement.stateOf(id);
        assertEq(s.currentStreak, 1, "streak survived a gap");
        assertEq(s.bestStreak, 1);
    }

    function test_agentCheckInAwardsExactlyOnePoint() public {
        uint256 id = _mint(owner, 1);
        for (uint256 d = 0; d < 30; d++) {
            vm.prank(owner);
            engagement.checkIn(id);
            vm.warp(block.timestamp + 1 days);
        }
        assertEq(engagement.stateOf(id).points, 30);
    }

    // ------------------------------------------------------- wallet check-in

    function test_walletCheckInDayOneAwardsBase() public {
        vm.prank(walletA);
        engagement.checkIn();
        CortisEngagement.WalletState memory w = engagement.walletStateOf(walletA);
        assertEq(w.currentStreak, 1);
        assertEq(w.points, 25, "day 1 = 23*1 + 2*1^2 = 25");
        assertTrue(engagement.walletCheckedInToday(walletA));
    }

    function test_walletCheckInCannotBeTwiceSameDay() public {
        vm.prank(walletA);
        engagement.checkIn();
        uint32 today = uint32(block.timestamp / 1 days);
        vm.prank(walletA);
        vm.expectRevert(abi.encodeWithSelector(CortisEngagement.WalletAlreadyCheckedInToday.selector, walletA, today));
        engagement.checkIn();
    }

    function test_walletCurveAccelerates() public {
        // 7 consecutive days: award = 23*streak + 2*streak^2.
        // Total = 23*(1+..+7) + 2*(1+4+9+16+25+36+49) = 23*28 + 2*140 = 924.
        uint64 expectedTotal;
        for (uint16 d = 1; d <= 7; d++) {
            vm.prank(walletA);
            engagement.checkIn();
            expectedTotal += uint64(23) * d + uint64(2) * d * d;
            vm.warp(block.timestamp + 1 days);
        }
        CortisEngagement.WalletState memory w = engagement.walletStateOf(walletA);
        assertEq(w.currentStreak, 7);
        assertEq(w.points, expectedTotal);
        assertEq(w.points, 924, "23*28 + 2*140");
        // Day 7 single-day award is 259.
        assertEq(uint64(23) * 7 + uint64(2) * 7 * 7, 259);
    }

    function test_walletAwardIsCapped() public {
        // Push a long streak and confirm the per-day award saturates at the cap.
        for (uint16 d = 1; d <= 70; d++) {
            vm.prank(walletA);
            engagement.checkIn();
            vm.warp(block.timestamp + 1 days);
        }
        (uint64 award, uint16 streakAfter) = engagement.walletNextCheckInAward(walletA);
        assertEq(streakAfter, 71);
        // 23*71 + 2*71^2 = 1633 + 10082 = 11715 > 10000 cap.
        assertEq(award, 10_000, "award saturates at CHECKIN_MAX_AWARD");
    }

    function test_walletStreakResetsAfterGap() public {
        vm.prank(walletA);
        engagement.checkIn();
        vm.warp(block.timestamp + 3 days);
        vm.prank(walletA);
        engagement.checkIn();
        CortisEngagement.WalletState memory w = engagement.walletStateOf(walletA);
        assertEq(w.currentStreak, 1, "gap resets streak");
        // Second check-in lands back on streak 1 => award 25 again.
        assertEq(w.points, 50, "25 (day1) + 25 (reset day)");
    }

    function test_walletNextAwardPreview() public {
        (uint64 award, uint16 streakAfter) = engagement.walletNextCheckInAward(walletA);
        assertEq(streakAfter, 1);
        assertEq(award, 25);
    }

    // ----------------------------------------------------------- engagement

    function test_walletActivityEventsAwardNoPoints() public {
        vm.startPrank(walletA);
        engagement.mapMe();
        engagement.generateWorkflow();
        engagement.deployAgent();
        vm.stopPrank();
        CortisEngagement.WalletState memory w = engagement.walletStateOf(walletA);
        assertEq(w.mapCount, 1);
        assertEq(w.workflowCount, 1);
        assertEq(w.deployCount, 1);
        assertEq(w.points, 0);
    }

    function test_agentActivityEventsAwardNoPoints() public {
        uint256 id = _mint(owner, 1);
        vm.startPrank(owner);
        engagement.mapMe(id);
        engagement.generateWorkflow(id, keccak256("wf"));
        vm.stopPrank();
        CortisEngagement.AgentState memory s = engagement.stateOf(id);
        assertEq(s.mapCount, 1);
        assertEq(s.workflowCount, 1);
        assertEq(s.points, 0);
    }

    // ---------------------------------------------------------------- pause

    function test_guardianCanPauseAdminCanUnpause() public {
        vm.prank(guardian);
        engagement.pause();
        vm.prank(walletA);
        vm.expectRevert();
        engagement.checkIn();

        vm.prank(timelock);
        engagement.unpause();
        vm.prank(walletA);
        engagement.checkIn();
        assertEq(engagement.walletStateOf(walletA).points, 25);
    }

    function test_nonGuardianCannotPause() public {
        vm.prank(other);
        vm.expectRevert();
        engagement.pause();
    }

    // --------------------------------------------------------------- config

    function test_constructorRejectsZeroAdmin() public {
        vm.expectRevert(CortisEngagement.InvalidConfiguration.selector);
        new CortisEngagement(address(0), guardian, address(passport));
    }

    function test_constructorRejectsZeroGuardian() public {
        vm.expectRevert(CortisEngagement.InvalidConfiguration.selector);
        new CortisEngagement(timelock, address(0), address(passport));
    }

    function test_constructorRejectsNonContractPassport() public {
        vm.expectRevert(CortisEngagement.InvalidConfiguration.selector);
        new CortisEngagement(timelock, guardian, address(0xdead));
    }

    function test_rolesAssignedToAdminAndGuardian() public view {
        assertTrue(engagement.hasRole(engagement.DEFAULT_ADMIN_ROLE(), timelock));
        assertTrue(engagement.hasRole(engagement.GUARDIAN_ROLE(), guardian));
    }

    // --------------------------------------------------------------- helpers

    function _mint(address to, uint16 tid) internal returns (uint256 id) {
        (uint16 t, bytes32 spec, uint256 n, uint48 d, bytes memory sig) = _voucher(to, tid, passport.voucherNonce(to));
        vm.prank(to);
        id = passport.mint(t, spec, n, d, sig);
    }

    function _voucher(address to, uint16 tid, uint256 nonce)
        internal
        view
        returns (uint16 templateId, bytes32 spec, uint256 n, uint48 deadline, bytes memory sig)
    {
        templateId = tid;
        spec = keccak256(abi.encodePacked("spec", tid));
        n = nonce;
        deadline = uint48(block.timestamp + 1 hours);

        bytes32 structHash = keccak256(abi.encode(MINT_VOUCHER_TYPEHASH, to, templateId, spec, n, deadline));
        bytes32 digest = _domainDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(issuerKey, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _domainDigest(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("CortisAgentPassport")),
                keccak256(bytes("1")),
                block.chainid,
                address(passport)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
