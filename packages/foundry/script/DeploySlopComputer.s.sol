// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { SlopComputer } from "../contracts/SlopComputer.sol";

/**
 * @notice Deploy script for SlopComputer.
 *
 * The contract owner defaults to atg.eth (0x34aA...8fDF3) for live networks,
 * but on the local Anvil chain we deploy with the deployer as owner so the
 * SE2 frontend can call owner-only methods out of the box.
 *
 * Examples:
 *   yarn deploy --file DeploySlopComputer.s.sol
 *   yarn deploy --file DeploySlopComputer.s.sol --network mainnet
 */
contract DeploySlopComputer is ScaffoldETHDeploy {
    address constant ATG_ETH = 0x34aA3F359A9D614239015126635CE7732c18fDF3;

    function run() external ScaffoldEthDeployerRunner {
        address initialOwner = block.chainid == 31337 ? deployer : ATG_ETH;
        new SlopComputer(initialOwner);
    }
}
