// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Kernel} from "@kernel/Kernel.sol";
import {IDittoEntryPoint} from "./IDittoEntryPoint.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";

contract DittoEntryPoint is AccessControl, IDittoEntryPoint {
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");

    address public automationRegistry;
    Workflow[] private workflows;
    mapping(address vaultAddress => mapping(uint256 workflowId => uint256))
        private vaultWorkflowToIndex; // starts from index 1

    constructor(address _automationRegistry) {
        automationRegistry = _automationRegistry;
    }

    // Registers a workflow associated with a vault
    function registerWorkflow(uint256 workflowId) external override {
        address vaultAddress = msg.sender;
        if (vaultWorkflowToIndex[vaultAddress][workflowId] != 0) {
            revert DittoEntryPoint__WorkflowAlreadyRegistered();
        }

        workflows.push(
            Workflow({vaultAddress: vaultAddress, workflowId: workflowId})
        );
        vaultWorkflowToIndex[vaultAddress][workflowId] = workflows.length;

        emit DittoEntryPointRegistered(vaultAddress, workflowId);
    }

    // Executes a workflow
    function runWorkflow(
        address vaultAddress,
        uint256 workflowId
    ) external override onlyRole(EXECUTOR_ROLE) {
        if (vaultWorkflowToIndex[vaultAddress][workflowId] == 0) {
            revert DittoEntryPoint__WorkflowNotRegistered();
        }

        IAutomationRegistry.AutomationDetail
            memory automation = IAutomationRegistry(automationRegistry)
                .getAutomation(vaultAddress, workflowId);
        Kernel(payable(vaultAddress)).execute(
            automation.execMode,
            automation.executionCalldata
        );

        emit DittoEntryPointRun(vaultAddress, workflowId);
    }

    // Cancels a workflow and removes it from active workflows
    function cancelWorkflow(uint256 workflowId) external override {
        address vaultAddress = msg.sender;
        if (vaultWorkflowToIndex[vaultAddress][workflowId] == 0) {
            revert DittoEntryPoint__WorkflowNotRegistered();
        }

        delete workflows[vaultWorkflowToIndex[vaultAddress][workflowId] - 1];
        vaultWorkflowToIndex[vaultAddress][workflowId] = 0;

        emit DittoEntryPointCancelled(vaultAddress, workflowId);
    }

    function queryWorkflows(
        uint256 from,
        uint256 count
    ) external view returns (Workflow[] memory result, uint256 totalCount) {
        totalCount = workflows.length;

        if (count > workflows.length - from) {
            count = workflows.length - from;
        }
        result = new Workflow[](count);
        for (uint256 i = 0; i < count; ++i) {
            result[i] = workflows[from + i];
        }
    }

    function isRegisteredWorkflow(
        address vaultAddress,
        uint256 workflowId
    ) external view returns (bool) {
        return vaultWorkflowToIndex[vaultAddress][workflowId] > 0;
    }
}
