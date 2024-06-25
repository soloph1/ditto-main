// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ExecMode} from "@kernel/types/Types.sol";
import {CALLTYPE_SINGLE} from "@kernel/types/Constants.sol";
import {ExecLib} from "@kernel/utils/ExecLib.sol";
import {IExecutor} from "@kernel/interfaces/IERC7579Modules.sol";
import {IERC7579Account} from "@kernel/interfaces/IERC7579Account.sol";
import {IAutomationExecutor} from "./IAutomationExecutor.sol";
import {IDittoEntryPoint} from "./IDittoEntryPoint.sol";

/// @dev A user can manage several vaults from one executor.
contract AutomationExecutor is Ownable, IAutomationExecutor, IExecutor {
    mapping(address => bool) public override isInitialized;
    mapping(address => mapping(uint256 => AutomationDetail)) public automations;

    address public dittoEntryPoint;

    constructor(address _dittoEntryPoint) Ownable() {
        dittoEntryPoint = _dittoEntryPoint;
    }

    function createAutomation(
        address vaultAddress,
        ExecMode execMode,
        bytes calldata executionCalldata
    ) external override onlyOwner returns (uint256 workflowId) {
        workflowId = uint256(
            keccak256(abi.encode(vaultAddress, execMode, executionCalldata))
        );
        automations[vaultAddress][workflowId] = AutomationDetail({
            enabled: false,
            execMode: execMode,
            executionCalldata: executionCalldata
        });

        emit AutomationAdded(vaultAddress, workflowId);
    }

    function registerWorkflow(
        address vaultAddress,
        uint256 workflowId
    ) external override onlyOwner {
        if (automations[vaultAddress][workflowId].enabled) {
            revert AutomationExecutor__AlreadyRegistered();
        }
        automations[vaultAddress][workflowId].enabled = true;

        IERC7579Account(vaultAddress).executeFromExecutor(
            ExecLib.encodeSimpleSingle(),
            ExecLib.encodeSingle(
                dittoEntryPoint,
                0,
                abi.encodeWithSelector(
                    IDittoEntryPoint.registerWorkflow.selector,
                    workflowId,
                    address(this)
                )
            )
        );
    }

    /// @dev manual execution
    function execute(
        address vaultAddress,
        ExecMode execMode,
        bytes calldata executionCalldata
    ) external onlyOwner {
        IERC7579Account(vaultAddress).executeFromExecutor(
            execMode,
            executionCalldata
        );
    }

    function executeWorkflow(
        address vaultAddress,
        uint256 workflowId
    ) external override {
        AutomationDetail memory automation = automations[vaultAddress][
            workflowId
        ];
        if (dittoEntryPoint != msg.sender) {
            revert AutomationExecutor__Unauthorized();
        }
        if (!automation.enabled) {
            revert AutomationExecutor__NotRegistered();
        }

        IERC7579Account(vaultAddress).executeFromExecutor(
            automation.execMode,
            automation.executionCalldata
        );
    }

    function onInstall(bytes calldata) external payable override {
        isInitialized[msg.sender] = true;
    }

    function onUninstall(bytes calldata) external payable override {
        isInitialized[msg.sender] = false;
    }

    function isModuleType(
        uint256 moduleTypeId
    ) external pure override returns (bool) {
        return moduleTypeId == 2;
    }
}
