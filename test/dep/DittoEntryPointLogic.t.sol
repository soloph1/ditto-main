// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Kernel} from "@kernel/Kernel.sol";
import {KernelFactory} from "@kernel/factory/KernelFactory.sol";
import {ValidationId} from "@kernel/core/ValidationManager.sol";
import {MockValidator} from "@kernel/mock/MockValidator.sol";
import {MockPolicy} from "@kernel/mock/MockPolicy.sol";
import {MockSigner} from "@kernel/mock/MockSigner.sol";
import {IEntryPoint} from "@kernel/interfaces/IEntryPoint.sol";
import {IHook, IValidator, IPolicy, ISigner, IExecutor} from "@kernel/interfaces/IERC7579Modules.sol";
import {ValidatorLib} from "@kernel/utils/ValidationTypeLib.sol";
import {MODULE_TYPE_EXECUTOR} from "@kernel/types/Constants.sol";
import {ExecMode} from "@kernel/types/Types.sol";
import {Execution} from "@kernel/types/Structs.sol";
import {EntryPointLib} from "@kernel/sdk/TestBase/erc4337Util.sol";
import {ExecLib} from "@kernel/utils/ExecLib.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {AutomationExecutor} from "../../src/dep/AutomationExecutor.sol";
import {DittoEntryPoint} from "../../src/dep/DittoEntryPoint.sol";
import {IV3SwapRouter} from "../../src/vault/interfaces/external/IV3SwapRouter.sol";
import {FullDeploy, Registry, VaultProxyAdmin} from "../../script/FullDeploy.s.sol";

abstract contract KernelTest is Test {
    struct RootValidationConfig {
        IHook hook;
        bytes validatorData;
        bytes hookData;
    }
    ValidationId rootValidation;
    bytes[] initConfig;
    RootValidationConfig rootValidationConfig;
    MockValidator mockValidator;
    IValidator enabledValidator;

    IEntryPoint entrypoint;

    struct EnablePermissionConfig {
        IHook hook;
        bytes hookData;
        IPolicy[] policies;
        bytes[] policyData;
        ISigner signer;
        bytes signerData;
    }
    EnablePermissionConfig permissionConfig;

    // things to override on test
    function _setRootValidationConfig() internal virtual {
        mockValidator = new MockValidator();
        rootValidation = ValidatorLib.validatorToIdentifier(mockValidator);
    }

    function _setEnableValidatorConfig() internal virtual {
        enabledValidator = new MockValidator();
    }

    function _setEnablePermissionConfig() internal virtual {
        IPolicy[] memory policies = new IPolicy[](2);
        MockPolicy mockPolicy = new MockPolicy();
        MockPolicy mockPolicy2 = new MockPolicy();
        policies[0] = mockPolicy;
        policies[1] = mockPolicy2;
        bytes[] memory policyData = new bytes[](2);
        policyData[0] = "policy1";
        policyData[1] = "policy2";
        MockSigner mockSigner = new MockSigner();

        permissionConfig.policies = policies;
        permissionConfig.signer = mockSigner;
        permissionConfig.policyData = policyData;
        permissionConfig.signerData = "signer";
    }

    function initData() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                Kernel.initialize.selector,
                rootValidation,
                rootValidationConfig.hook,
                rootValidationConfig.validatorData,
                rootValidationConfig.hookData,
                initConfig
            );
    }
}

contract TestDittoEntryPointLogicPolygon is KernelTest {
    address usdcAddress = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174; // mainnet USDC
    address wethAddress = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619; // mainnet WETH
    address donor = 0x55CAaBB0d2b704FD0eF8192A7E35D8837e678207; // wallet for token airdrop

    IUniswapV3Pool pool =
        IUniswapV3Pool(0x45dDa9cb7c25131DF268515131f647d726f50608);
    uint24 poolFee;

    address executor = makeAddr("EXECUTOR");
    address user = makeAddr("USER");

    AutomationExecutor automationExecutor;
    DittoEntryPoint dittoEntryPoint;

    KernelFactory factory;
    Kernel smartAccount;

    ExecMode automationExecMode;
    bytes automationCallData;

    function setUp() external {
        vm.createSelectFork(vm.envString("POL_RPC_URL"), 58321464);
        vm.txGasPrice(80000000000);

        poolFee = pool.fee();

        entrypoint = IEntryPoint(EntryPointLib.deploy());

        dittoEntryPoint = new DittoEntryPoint();
        automationExecutor = new AutomationExecutor(address(dittoEntryPoint));

        Kernel impl = new Kernel(entrypoint);
        factory = new KernelFactory(address(impl));

        _setRootValidationConfig();
        _setEnableValidatorConfig();
        _setEnablePermissionConfig();

        smartAccount = Kernel(
            payable(factory.createAccount(initData(), bytes32(0)))
        );

        // 10 weth, 2000 usdc to smart account
        vm.startPrank(donor);
        IERC20(usdcAddress).transfer(address(smartAccount), 20000e6);
        IERC20(wethAddress).transfer(address(smartAccount), 10e18);
        vm.stopPrank();

        Execution[] memory executions = new Execution[](2);
        executions[0].target = wethAddress;
        executions[0].value = 0;
        executions[0].callData = abi.encodeWithSelector(
            IERC20.approve.selector,
            0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
            1 ether
        );
        executions[1].target = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
        executions[1].value = 0;
        executions[1].callData = abi.encodeWithSelector(
            IV3SwapRouter.exactInputSingle.selector,
            IV3SwapRouter.ExactInputSingleParams({
                tokenIn: wethAddress,
                tokenOut: usdcAddress,
                fee: poolFee,
                recipient: address(smartAccount),
                amountIn: 1 ether,
                amountOutMinimum: 1,
                sqrtPriceLimitX96: 0
            })
        );
        automationExecMode = ExecLib.encodeSimpleBatch();
        automationCallData = ExecLib.encodeBatch(executions);
    }

    // =========================
    // Connect module
    // =========================

    function test_dep_connect_module() public {
        // assume it's called from the entrypoint
        vm.startPrank(address(entrypoint));
        smartAccount.installModule(
            MODULE_TYPE_EXECUTOR,
            address(automationExecutor),
            abi.encodePacked(address(0), "0x")
        );
        vm.stopPrank();

        assertEq(
            address(
                smartAccount
                    .executorConfig(IExecutor(address(automationExecutor)))
                    .hook
            ),
            address(1)
        );
    }

    // =========================
    // Create an automation
    // =========================

    function test_dep_create_automation() public {
        test_dep_connect_module();

        // create an automation to transfer 10 USDC to user
        uint256 workflowId = automationExecutor.createAutomation(
            address(smartAccount),
            automationExecMode,
            automationCallData
        );

        (bool enabled, ExecMode execMode, ) = automationExecutor.automations(
            address(smartAccount),
            workflowId
        );
        assertEq(enabled, false);
        assertEq(abi.encode(execMode), abi.encode(automationExecMode));
    }

    // =========================
    // Register in DEP
    // =========================

    function test_dep_register_automation() public {
        test_dep_create_automation();
        uint256 workflowId = uint256(
            keccak256(
                abi.encode(
                    address(smartAccount),
                    automationExecMode,
                    automationCallData
                )
            )
        );

        automationExecutor.registerWorkflow(address(smartAccount), workflowId);
        assertEq(
            dittoEntryPoint.isRegisteredWorkflow(
                address(smartAccount),
                workflowId
            ),
            true
        );
    }

    // =========================
    // Execute on behalf of smart account
    // =========================

    function test_dep_execute_automation() public {
        test_dep_register_automation();

        uint256 workflowId = uint256(
            keccak256(
                abi.encode(
                    address(smartAccount),
                    automationExecMode,
                    automationCallData
                )
            )
        );

        dittoEntryPoint.grantRole(dittoEntryPoint.EXECUTOR_ROLE(), executor);

        uint256 usdcBalanceBefore = IERC20(usdcAddress).balanceOf(
            address(smartAccount)
        );

        vm.startPrank(executor);
        dittoEntryPoint.runWorkflow(address(smartAccount), workflowId);
        vm.stopPrank();

        assertGt(
            IERC20(usdcAddress).balanceOf(address(smartAccount)),
            usdcBalanceBefore
        );
    }
}
