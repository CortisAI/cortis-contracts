// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title CortisPassport
 * @notice Soulbound (non-transferable) ERC721 that represents a deployed Cortis agent.
 *         One wallet may hold MULTIPLE passports — one per agent. Minting is the real
 *         "deploy / commit the agent" action. Bound to the owner wallet forever
 *         (transfers are blocked; owner may optionally burn their own passport).
 *
 * @dev    Pre-TGE this contract carries no token logic. Sybil resistance comes from
 *         gas cost + a bound on-chain identity only. The $COR token (BSC, at TGE) is
 *         intentionally NOT referenced here.
 */
contract CortisPassport is ERC721, Ownable {
    // ─────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Incrementing token id counter (first minted id is 1).
    uint256 private _nextId = 1;

    /// @notice tokenId => human/agent identifier string supplied at mint time.
    mapping(uint256 => string) public agentIdOf;

    /// @notice tokenId => metadata URI supplied at mint time.
    mapping(uint256 => string) private _tokenURIs;

    /// @notice owner => number of passports currently held.
    mapping(address => uint256) public passportsOf;

    // ─────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Emitted when a new passport is minted.
    /// @param owner   The wallet that now owns the passport.
    /// @param tokenId The freshly minted token id.
    /// @param agentId The agent identifier string bound to this passport.
    event PassportMinted(address indexed owner, uint256 indexed tokenId, string agentId);

    /// @notice Emitted when an owner burns their own passport.
    event PassportBurned(address indexed owner, uint256 indexed tokenId);

    // ─────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Thrown on any attempt to transfer a soulbound passport between wallets.
    error SoulboundNonTransferable();

    /// @dev Thrown when a non-owner tries to burn a passport.
    error NotPassportOwner();

    // ─────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────

    constructor(address initialOwner)
        ERC721("Cortis Passport", "CORTIS")
        Ownable(initialOwner)
    {}

    // ─────────────────────────────────────────────────────────────────────
    // Minting
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @notice Mint a soulbound passport to the caller for a specific agent.
     * @dev    Anyone may mint (gas-only). One wallet can hold many passports.
     * @param agentId Off-chain agent identifier (e.g. "COR-AB12CD"). Stored on-chain.
     * @param uri     Metadata URI for this passport token.
     * @return tokenId The newly minted token id.
     */
    function mintPassport(string calldata agentId, string calldata uri)
        external
        returns (uint256 tokenId)
    {
        tokenId = _nextId++;
        agentIdOf[tokenId] = agentId;
        _tokenURIs[tokenId] = uri;
        _safeMint(msg.sender, tokenId);
        emit PassportMinted(msg.sender, tokenId, agentId);
    }

    /**
     * @notice Burn a passport you own. Optional exit path for a bound identity.
     * @param tokenId The passport to burn.
     */
    function burnPassport(uint256 tokenId) external {
        if (ownerOf(tokenId) != msg.sender) revert NotPassportOwner();
        _burn(tokenId);
        delete agentIdOf[tokenId];
        delete _tokenURIs[tokenId];
        emit PassportBurned(msg.sender, tokenId);
    }

    // ─────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Total number of passports ever minted (including any burned).
    function totalMinted() external view returns (uint256) {
        return _nextId - 1;
    }

    /// @inheritdoc ERC721
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _tokenURIs[tokenId];
    }

    // ─────────────────────────────────────────────────────────────────────
    // Soulbound enforcement
    // ─────────────────────────────────────────────────────────────────────

    /**
     * @dev Overrides ERC721._update to make tokens non-transferable.
     *      - Mint  (from == 0) is allowed.
     *      - Burn  (to   == 0) is allowed.
     *      - Any transfer between two non-zero addresses reverts.
     *      Also maintains the per-owner passport count.
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);

        if (from != address(0) && to != address(0)) {
            revert SoulboundNonTransferable();
        }

        address previousOwner = super._update(to, tokenId, auth);

        if (from == address(0)) {
            // mint
            passportsOf[to] += 1;
        } else if (to == address(0)) {
            // burn
            passportsOf[from] -= 1;
        }

        return previousOwner;
    }

    // Explicitly disable approvals — they only enable transfers, which are blocked.
    // Kept as no-op reverts for clarity; the _update guard is the real enforcement.
    function approve(address, uint256) public pure override {
        revert SoulboundNonTransferable();
    }

    function setApprovalForAll(address, bool) public pure override {
        revert SoulboundNonTransferable();
    }
}
