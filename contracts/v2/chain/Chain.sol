// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./ArbSys.sol";

// @title Chain
// @dev Wrap the calls to retrieve chain variables to handle differences
// between chain implementations
library Chain {
    // if the ARBITRUM_CHAIN_ID changes, a new version of this library
    // and contracts depending on it would need to be deployed
    uint256 public constant ARBITRUM_CHAIN_ID = 42161;
    uint256 public constant ARBITRUM_SEPOLIA_CHAIN_ID = 421614;

    ArbSys public constant arbSys = ArbSys(address(100));

    // @dev return the current block's timestamp
    // @return the current block's timestamp
    function currentTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    // @dev return the current block's number
    // @return the current block's number
    function currentBlockNumber() internal view returns (uint256) {
        if (shouldUseArbSysValues()) {
            return arbSys.arbBlockNumber();
        }

        return block.number;
    }

    // @dev return the current block's hash
    // @return the current block's hash
    function getBlockHash(uint256 blockNumber) internal view returns (bytes32) {
        if (shouldUseArbSysValues()) {
            return arbSys.arbBlockHash(blockNumber);
        }

        return blockhash(blockNumber);
    }

    function shouldUseArbSysValues() internal view returns (bool) {
        return block.chainid == ARBITRUM_CHAIN_ID || block.chainid == ARBITRUM_SEPOLIA_CHAIN_ID;
    }
}
