// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ExecMode} from "@kernel/types/Types.sol";

interface IAutomationExecutor {
    struct AutomationDetail {
        bool enabled;
        ExecMode execMode;
        bytes executionCalldata;
    }
    function createAutomation(
        address vaultAddress,
        ExecMode execMode,
        bytes calldata executionCalldata
    ) external returns (uint256 workflowId);

    function registerWorkflow(
        address vaultAddress,
        uint256 workflowId
    ) external;

    function executeWorkflow(address vaultAddress, uint256 workflowId) external;

    error AutomationExecutor__AlreadyRegistered();
    error AutomationExecutor__NotRegistered();
    error AutomationExecutor__Unauthorized();

    event AutomationAdded(address vaultAddress, uint256 workflowId);
}
