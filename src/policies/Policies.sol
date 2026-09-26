// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IFeePolicy} from "../interfaces/ICortis.sol";

/**
 * @title NullFeePolicy
 * @notice The pre-TGE fee policy. Always zero.
 *
 * @dev Deployed rather than left as address(0) so that the wiring, the
 *      timelocked swap procedure and the integration tests all exercise the
 *      same code path they will use at TGE. The first time a policy address is
 *      set should not be on mainnet with real money behind it.
 */
contract NullFeePolicy is IFeePolicy {
    function attestationFee(uint256) external pure returns (uint256) {
        return 0;
    }
}
