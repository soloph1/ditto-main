// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ExecMode} from "@kernel/types/Types.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";

contract AutomationRegistry is Ownable, IAutomationRegistry {
    mapping(address => AutomationDetail[]) public automations;

    constructor() Ownable() {}

    function addAutomation(
        ExecMode execMode,
        bytes calldata executionCalldata
    ) external override returns (uint256 workflowId) {
        address vaultAddress = msg.sender;
        automations[vaultAddress].push(
            AutomationDetail({
                execMode: execMode,
                executionCalldata: executionCalldata
            })
        );

        workflowId = automations[vaultAddress].length - 1;

        emit AutomationAdded(vaultAddress, workflowId);
    }

    function getAutomation(
        address vaultAddress,
        uint256 workflowId
    ) external view override returns (AutomationDetail memory) {
        if (workflowId > automations[vaultAddress].length) {
            revert AutomationRegistry__NotFound();
        }
        return automations[vaultAddress][workflowId];
    }
}
