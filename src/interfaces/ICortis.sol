// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice ERC-5192 minimal soulbound interface.
interface IERC5192 {
    event Locked(uint256 tokenId);
    event Unlocked(uint256 tokenId);

    function locked(uint256 tokenId) external view returns (bool);
}

interface IAgentPassport {
    /// @dev Packed into one slot. specializationHash is the only mutable field:
    ///      an owner may re-specialise a passport, which updates the bound
    ///      identity rather than minting a new one.
    struct Passport {
        address owner; // 160
        uint32 mintedAt; //  32
        uint16 templateId; //  16
        bool active; //   8
        uint32 deactivatedAt; //  32  = 248 bits, one slot
    }

    event PassportMinted(uint256 indexed agentId, address indexed owner, uint16 indexed templateId, bytes32 voucherHash);
    event PassportDeactivated(uint256 indexed agentId, address indexed owner);
    event PassportRespecialized(uint256 indexed agentId, bytes32 previousHash, bytes32 newHash);

    function passportOf(uint256 agentId) external view returns (Passport memory);
    function isActive(uint256 agentId) external view returns (bool);
    function activeCountOf(address owner) external view returns (uint256);
}

interface IFeePolicy {
    /// @return feeAmount the COR fee for this action, in wei of COR.l2.
    ///         Action classes were removed in Revision 2 §13.5, so fees are a
    ///         function of the agent alone.
    function attestationFee(uint256 agentId) external view returns (uint256 feeAmount);
}
