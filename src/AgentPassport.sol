// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {IAgentPassport, IERC5192} from "./interfaces/ICortis.sol";

/**
 * @title AgentPassport
 * @notice Non-transferable ERC-721 binding one specialist agent to one owner
 *         smart account. ERC-5192 permanently locked; there is no unlock path.
 *
 * @dev Design notes that differ from a normal NFT and are deliberate:
 *
 *      - Every transfer path reverts, including safeTransferFrom, approve and
 *         setApprovalForAll. Approval is disabled rather than merely useless so
 *         that an owner cannot be socially engineered into signing something
 *         that looks like it grants control.
 *
 *      - Recovery is NOT a transfer. An owner who loses a device changes the
 *         signer configuration of their Kernel smart account; the passport
 *         address never moves. This is why there is no admin transfer hatch:
 *         a hatch would be the single most valuable target in the system and
 *         it would buy nothing that account-level recovery does not already
 *         give.
 *
 *      - Deactivation burns nothing. History is the product. A deactivated
 *         passport keeps its engagement record and simply stops counting
 *         against the active-roster cap.
 */
contract AgentPassport is ERC721, AccessControl, Pausable, EIP712, IAgentPassport, IERC5192 {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    bytes32 public constant MINT_VOUCHER_TYPEHASH = keccak256(
        "MintVoucher(address owner,uint16 templateId,bytes32 specializationHash,uint256 nonce,uint48 deadline)"
    );

    uint256 public constant MAX_ACTIVE_PER_OWNER = 5;

    uint256 private _nextAgentId = 1;

    mapping(uint256 agentId => Passport) private _passports;
    mapping(uint256 agentId => bytes32) public specializationHash;
    mapping(address owner => uint256) private _activeCount;
    mapping(address owner => uint256) public voucherNonce;
    mapping(bytes32 voucherHash => bool) public voucherUsed;

    error TransferDisabled();
    error ApprovalDisabled();
    error RosterFull(address owner, uint256 active);
    error VoucherExpired(uint48 deadline);
    error VoucherReplayed(bytes32 voucherHash);
    error BadVoucherSigner(address recovered);
    error BadVoucherNonce(uint256 expected, uint256 supplied);
    error NotPassportOwner(uint256 agentId, address caller);
    error AlreadyInactive(uint256 agentId);
    error UnknownPassport(uint256 agentId);
    error ZeroRoleAddress();

    constructor(address timelock, address issuer, address guardian)
        ERC721("Cortis Agent Passport", "CORTIS-AP")
        EIP712("CortisAgentPassport", "1")
    {
        // L-03: reject zero addresses for every required initial role holder so
        // deployment can never succeed with an inaccessible admin/issuer/guardian.
        if (timelock == address(0) || issuer == address(0) || guardian == address(0)) {
            revert ZeroRoleAddress();
        }
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(ISSUER_ROLE, issuer);
        _grantRole(GUARDIAN_ROLE, guardian);
    }

    // ---------------------------------------------------------------- minting

    /**
     * @notice Mint a passport against an off-chain eligibility voucher.
     * @dev The voucher is what carries device risk, account age and abuse
     *      signals on-chain without putting any of them on-chain. The signature
     *      commits to the owner, so a leaked voucher is useless to anyone else.
     */
    function mint(uint16 templateId, bytes32 specialization, uint256 nonce, uint48 deadline, bytes calldata signature)
        external
        whenNotPaused
        returns (uint256 agentId)
    {
        if (block.timestamp > deadline) revert VoucherExpired(deadline);
        if (nonce != voucherNonce[msg.sender]) revert BadVoucherNonce(voucherNonce[msg.sender], nonce);

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(MINT_VOUCHER_TYPEHASH, msg.sender, templateId, specialization, nonce, deadline))
        );
        if (voucherUsed[digest]) revert VoucherReplayed(digest);

        address signer = ECDSA.recover(digest, signature);
        if (!hasRole(ISSUER_ROLE, signer)) revert BadVoucherSigner(signer);

        uint256 active = _activeCount[msg.sender];
        if (active >= MAX_ACTIVE_PER_OWNER) revert RosterFull(msg.sender, active);

        voucherUsed[digest] = true;
        unchecked {
            voucherNonce[msg.sender] = nonce + 1;
            _activeCount[msg.sender] = active + 1;
            agentId = _nextAgentId++;
        }

        _passports[agentId] = Passport({
            owner: msg.sender,
            mintedAt: uint32(block.timestamp),
            templateId: templateId,
            active: true,
            deactivatedAt: 0
        });
        specializationHash[agentId] = specialization;

        _mint(msg.sender, agentId);
        emit Locked(agentId);
        emit PassportMinted(agentId, msg.sender, templateId, digest);
    }

    // ------------------------------------------------------------- lifecycle

    /// @notice Retire a passport. History is retained; the roster slot is freed.
    function deactivate(uint256 agentId) external {
        Passport storage p = _requirePassport(agentId);
        if (p.owner != msg.sender) revert NotPassportOwner(agentId, msg.sender);
        if (!p.active) revert AlreadyInactive(agentId);

        p.active = false;
        p.deactivatedAt = uint32(block.timestamp);
        unchecked {
            _activeCount[msg.sender] -= 1;
        }
        emit PassportDeactivated(agentId, msg.sender);
    }

    /**
     * @notice Re-specialise an existing passport in place.
     * @dev This is the escape valve that keeps the roster fixed. Owners who
     *      want a different specialist update the one they have instead of
     *      minting an endless stream of agents.
     */
    function respecialize(uint256 agentId, bytes32 newSpecialization) external whenNotPaused {
        Passport storage p = _requirePassport(agentId);
        if (p.owner != msg.sender) revert NotPassportOwner(agentId, msg.sender);
        if (!p.active) revert AlreadyInactive(agentId);

        bytes32 previous = specializationHash[agentId];
        specializationHash[agentId] = newSpecialization;
        emit PassportRespecialized(agentId, previous, newSpecialization);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /// @dev Unpause is admin-only by design: the guardian is a circuit breaker,
    ///      not an operator. Restoring service is a timelocked decision.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    function passportOf(uint256 agentId) external view returns (Passport memory) {
        return _passports[agentId];
    }

    function isActive(uint256 agentId) external view returns (bool) {
        return _passports[agentId].active;
    }

    function activeCountOf(address owner) external view returns (uint256) {
        return _activeCount[owner];
    }

    function totalMinted() external view returns (uint256) {
        unchecked {
            return _nextAgentId - 1;
        }
    }

    function locked(uint256 agentId) external view returns (bool) {
        _requireOwned(agentId);
        return true;
    }

    // -------------------------------------------------------- soulbound guard

    /// @dev The single chokepoint for every ERC-721 balance change. Mints pass
    ///      (from == 0); everything else reverts, including burns, so a
    ///      passport can never leave the address it was issued to.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        from = _ownerOf(tokenId);
        if (from != address(0)) revert TransferDisabled();
        return super._update(to, tokenId, auth);
    }

    function approve(address, uint256) public pure override {
        revert ApprovalDisabled();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert ApprovalDisabled();
    }

    /// @dev L-01: restore ERC-721 existence validation. getApproved must revert
    ///      for an unminted token id; a live soulbound passport still reports the
    ///      zero approval it can never grant.
    function getApproved(uint256 tokenId) public view override returns (address) {
        _requireOwned(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) public pure override returns (bool) {
        return false;
    }

    // ------------------------------------------------------------- internals

    function _requirePassport(uint256 agentId) private view returns (Passport storage p) {
        p = _passports[agentId];
        if (p.owner == address(0)) revert UnknownPassport(agentId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, AccessControl) returns (bool) {
        return interfaceId == type(IERC5192).interfaceId || super.supportsInterface(interfaceId);
    }
}
