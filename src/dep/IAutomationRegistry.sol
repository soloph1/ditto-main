// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ExecMode} from "@kernel/types/Types.sol";

interface IAutomationRegistry {
    struct AutomationDetail {
        ExecMode execMode;
        bytes executionCalldata;
    }
    function addAutomation(
        ExecMode execMode,
        bytes calldata executionCalldata
    ) external returns (uint256 workflowId);

    function getAutomation(
        address vaultAddress,
        uint256 workflowId
    ) external view returns (AutomationDetail memory);

    error AutomationRegistry__NotFound();

    event AutomationAdded(address vaultAddress, uint256 workflowId);
}
