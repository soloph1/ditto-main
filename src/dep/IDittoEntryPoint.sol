// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

// Interface for the DittoEntryPoint DEP contract
interface IDittoEntryPoint {
    // Defines the structure for tracking workflows in the system
    struct Workflow {
        address vaultAddress; // Address of the vault (SCA) associated with the workflow
        uint256 workflowId; // Unique identifier for the workflow
    }

    // Registers a workflow associated with a vault
    function registerWorkflow(uint256 workflowId) external;

    // Executes a workflow
    function runWorkflow(address vaultAddress, uint256 workflowId) external;

    // Cancels a workflow and removes it from active workflows
    function cancelWorkflow(uint256 workflowId) external;

    error DittoEntryPoint__WorkflowAlreadyRegistered();
    error DittoEntryPoint__WorkflowNotRegistered();

    event DittoEntryPointRegistered(
        address indexed vaultAddress,
        uint256 workflowId
    );
    event DittoEntryPointCancelled(
        address indexed vaultAddress,
        uint256 workflowId
    );
    event DittoEntryPointRun(address indexed vaultAddress, uint256 workflowId);
}
