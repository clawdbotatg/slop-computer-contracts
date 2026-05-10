// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./DeployHelpers.s.sol";
import { SlopComputer } from "../contracts/SlopComputer.sol";

/**
 * @notice Deploy script for SlopComputer.
 *
 * On the local Anvil chain (31337) we deploy with the deployer as owner so
 * the SE2 frontend can exercise owner-only methods. On every other chain the
 * owner is hardcoded to atg.eth and the script reverts the deploy if that's
 * ever not the case post-construction — a belt-and-suspenders guard against
 * accidental misdeploys.
 *
 * Examples:
 *   yarn deploy --file DeploySlopComputer.s.sol
 *   yarn deploy --file DeploySlopComputer.s.sol --network mainnet
 */
contract DeploySlopComputer is ScaffoldETHDeploy {
    /// @notice atg.eth — the host wallet, intended owner on every live network.
    address constant ATG_ETH = 0x34aA3F359A9D614239015126635CE7732c18fDF3;

    error WrongOwner(address expected, address actual);

    function run() external ScaffoldEthDeployerRunner {
        bool isLocal = block.chainid == 31337;
        address initialOwner = isLocal ? deployer : ATG_ETH;

        SlopComputer sc = new SlopComputer(initialOwner);

        // Hard guarantee for live networks. If the constructor or constant ever
        // drifts, the broadcast reverts before the deploy can be confirmed.
        if (!isLocal && sc.owner() != ATG_ETH) {
            revert WrongOwner(ATG_ETH, sc.owner());
        }

        console.logString("SlopComputer deployed at:");
        console.logAddress(address(sc));
        console.logString("Owner:");
        console.logAddress(sc.owner());
    }
}
