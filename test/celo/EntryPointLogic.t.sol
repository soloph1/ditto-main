// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

import {ProtocolFees} from "../../src/ProtocolFees.sol";

import {IV3SwapRouter} from "../../src/vault/interfaces/external/IV3SwapRouter.sol";
import {AccessControlLogic} from "../../src/vault/logics/AccessControlLogic.sol";
import {BaseContract, Constants} from "../../src/vault/libraries/BaseContract.sol";
import {EntryPointLogic, IEntryPointLogic} from "../../src/vault/logics/EntryPointLogic.sol";
import {ExecutionLogic} from "../../src/vault/logics/ExecutionLogic.sol";
import {VaultLogic} from "../../src/vault/logics/VaultLogic.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {UniswapLogic} from "../../src/vault/logics/OurLogic/dexAutomation/UniswapLogic.sol";
import {TimeCheckerLogic} from "../../src/vault/logics/Checkers/TimeCheckerLogic.sol";
import {PriceCheckerLogicUniswap} from "../../src/vault/logics/Checkers/PriceCheckerLogicUniswap.sol";
import {TransferHelper} from "../../src/vault/libraries/utils/TransferHelper.sol";
import {DexLogicLib} from "../../src/vault/libraries/DexLogicLib.sol";

import {FullDeploy, Registry, VaultProxyAdmin} from "../../script/FullDeploy.s.sol";

import {CeloNativeMock} from "./mocks/CeloNativeMock.sol";

contract TestEntryPointLogic is Test, FullDeploy {
    bool isTest = true;

    Registry.Contracts reg;
    // mainnet CELO
    address celoAddress = 0x471EcE3750Da237f93B8E339c536989b8978a438;
    // mainnet WETH
    address wethAddress = 0x66803FB87aBd4aaC3cbB3fAd7C3aa01f6F3FB207;
    // wallet for token airdrop
    address donor = 0xB90FE7DA36aC89448e6Dfd7f2BB1E90A66659977;
    IUniswapV3Pool pool =
        IUniswapV3Pool(0xd88D5F9E6c10E6FebC9296A454f6C2589b1E8fAE);
    uint24 poolFee;

    address vault;

    address vaultOwner = makeAddr("VAULT_OWNER");
    address executor = makeAddr("EXECUTOR");
    address user = makeAddr("USER");

    address constant TRANSFER_CELO = address(0xff - 2);

    uint256 nftId;

    bytes[] multicallData;

    function setUp() external {
        vm.createSelectFork(vm.envString("CELO_RPC_URL"));
        vm.txGasPrice(5000000000);

        poolFee = pool.fee();

        address mock = address(new CeloNativeMock());
        vm.etch(TRANSFER_CELO, mock.code);
        vm.allowCheatcodes(TRANSFER_CELO);

        deal(vaultOwner, 10000e18);
        vm.prank(donor);
        IERC20(wethAddress).transfer(vaultOwner, 10e18);

        reg = deploySystemContracts(
            isTest,
            Registry.contractsByChainId(block.chainid)
        );

        reg.protocolFees = new ProtocolFees(vaultOwner);
        reg.logics.entryPointLogic = address(
            new EntryPointLogic(reg.automateGelato, reg.protocolFees)
        );
        reg.logics.executionLogic = address(
            new ExecutionLogic(reg.protocolFees)
        );

        uint256 nonce = vm.getNonce(address(this));
        reg.vaultProxyAdmin = new VaultProxyAdmin(
            vm.computeCreateAddress(address(this), nonce + 3)
        );

        (VaultFactory vaultFactory, ) = addImplementation(
            reg,
            isTest,
            address(this)
        );

        vm.startPrank(vaultOwner);
        vault = vaultFactory.deploy(1, 1);

        (, int24 currentTick, , , , , ) = pool.slot0();
        int24 minTick = ((currentTick - 4000) / 60) * 60;
        int24 maxTick = ((currentTick + 4000) / 60) * 60;

        uint256 RTarget = reg.lens.dexLogicLens.getTargetRE18ForTickRange(
            minTick,
            maxTick,
            pool
        );
        uint160 sqrtPriceX96 = reg.lens.dexLogicLens.getCurrentSqrtRatioX96(
            pool
        );

        uint256 wethAmount = reg.lens.dexLogicLens.token1AmountForTargetRE18(
            sqrtPriceX96,
            500e6,
            1e18,
            RTarget,
            poolFee
        );

        uint256 usdcAmount = reg.lens.dexLogicLens.token0AmountForTargetRE18(
            sqrtPriceX96,
            wethAmount,
            RTarget
        );

        IERC20(wethAddress).approve(
            address(reg.uniswapNFTPositionManager),
            wethAmount
        );
        IERC20(celoAddress).approve(
            address(reg.uniswapNFTPositionManager),
            usdcAmount
        );

        INonfungiblePositionManager.MintParams memory _mParams;
        _mParams.token0 = celoAddress;
        _mParams.token1 = wethAddress;
        _mParams.fee = poolFee;
        _mParams.tickLower = minTick;
        _mParams.tickUpper = maxTick;
        _mParams.amount0Desired = usdcAmount;
        _mParams.amount1Desired = wethAmount;
        _mParams.recipient = vaultOwner;
        _mParams.deadline = block.timestamp;

        // mint new nft for tests
        (nftId, , , ) = reg.uniswapNFTPositionManager.mint(_mParams);

        reg.uniswapNFTPositionManager.safeTransferFrom(
            vaultOwner,
            vault,
            nftId
        );

        deal(vault, 1 ether);

        IERC20(wethAddress).approve(vault, type(uint256).max);
        IERC20(celoAddress).approve(vault, type(uint256).max);

        AccessControlLogic(vault).grantRole(
            Constants.EXECUTOR_ROLE,
            address(executor)
        );

        IERC20(celoAddress).transfer(
            vault,
            IERC20(celoAddress).balanceOf(vaultOwner)
        );
        IERC20(wethAddress).transfer(
            vault,
            IERC20(wethAddress).balanceOf(vaultOwner)
        );

        vm.stopPrank();
    }

    // =========================
    // AddWorkflow
    // =========================

    function test_celo_entryPointLogic_addWorkflow_shouldUpdateState()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeAndPriceCheckers();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertEq(workflow.checkers[0].storageRef, checkers[0].storageRef);
        assertEq(workflow.checkers[0].data, checkers[0].data);
        assertEq(workflow.checkers[1].storageRef, checkers[1].storageRef);
        assertEq(workflow.checkers[1].data, checkers[1].data);
        assertEq(workflow.actions[0].storageRef, actions[0].storageRef);
        assertEq(workflow.actions[0].data, actions[0].data);
        assertEq(workflow.executor, executor);
        assertEq(workflow.counter, 0); // infinite executions
    }

    function test_celo_entryPointLogic_addWorkflow_shouldGrantRole() external {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeAndPriceCheckers();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        assertTrue(
            AccessControlLogic(address(vault)).hasRole(
                Constants.EXECUTOR_ROLE,
                executor
            )
        );
    }

    function test_celo_entryPointLogic_addWorkflow_accessControl() external {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeAndPriceCheckers();

        vm.prank(vaultOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                vaultOwner
            )
        );
        IEntryPointLogic(vault).addWorkflow(checkers, actions, vaultOwner, 0);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                executor
            )
        );
        IEntryPointLogic(vault).addWorkflow(checkers, actions, executor, 0);

        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                user
            )
        );
        IEntryPointLogic(vault).addWorkflow(checkers, actions, user, 0);
    }

    // =========================
    // Run
    // =========================

    event UniswapAutoCompound(uint256 nftId);

    function test_celo_entryPointLogic_run_successfulRunUniswapAutocompound()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeAndPriceCheckers();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        _rateUp();
        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        vm.prank(executor);
        vm.expectEmit();
        emit UniswapAutoCompound(nftId);
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_run_unsuccessfulRun() external {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeAndPriceCheckers();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.prank(executor);
        vm.expectRevert(
            IEntryPointLogic.EntryPoint_TriggerVerificationFailed.selector
        );
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_run_shouldRevertWithRevertedAction()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        actions[0].data = abi.encodeCall(
            UniswapLogic.uniswapAutoCompound,
            (nftId, 0)
        );

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        vm.prank(executor);
        vm.expectRevert(DexLogicLib.MEVCheck_DeviationOfPriceTooHigh.selector);
        IEntryPointLogic(vault).run(0);
    }

    event EntryPointRun(address indexed executor, uint256 wokrflowKey);

    function test_celo_entryPointLogic_run_shouldSendDittoFeeToDittoTreasury()
        external
    {
        address treasury = makeAddr("treasury");
        vm.prank(vaultOwner);
        reg.protocolFees.setTreasury(treasury);
        vm.prank(vaultOwner);
        reg.protocolFees.setAutomationFee(1e18, 0);

        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        uint256 balanceBefore = treasury.balance;

        vm.prank(executor);
        vm.expectEmit(address(vault));
        emit EntryPointRun(executor, 0);
        IEntryPointLogic(vault).run(0);

        // Check if balance has increased
        assertGt(treasury.balance - balanceBefore, 0);
    }

    function test_celo_entryPointLogic_run_shouldRevertIfFeeDoesNotEnough()
        external
    {
        address treasury = makeAddr("treasury");
        vm.prank(vaultOwner);
        reg.protocolFees.setTreasury(treasury);
        vm.prank(vaultOwner);
        reg.protocolFees.setAutomationFee(1e18, 0);

        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        vm.prank(vaultOwner);
        VaultLogic(payable(address(vault))).withdrawTotalNative(vaultOwner);
        vm.prank(executor);
        vm.expectRevert(
            TransferHelper.TransferHelper_SafeTransferNativeError.selector
        );
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_run_shouldRevertIfWorkflowDoesNotExists()
        external
    {
        vm.prank(vaultOwner);
        vm.expectRevert(
            IEntryPointLogic.EntryPoint_WorkflowDoesNotExist.selector
        );
        IEntryPointLogic(vault).run(0);
    }

    event EntryPointWorkflowStatusDeactivated(uint256 workflowKey);

    function test_celo_entryPointLogic_run_singleExecute() external {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 1)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        vm.prank(executor);
        vm.expectEmit();
        emit EntryPointWorkflowStatusDeactivated(0);
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_run_executeFiveTimes() external {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        checkers = new IEntryPointLogic.Checker[](0);

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 5)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.startPrank(executor);
        IEntryPointLogic(vault).run(0);
        IEntryPointLogic(vault).run(0);
        IEntryPointLogic(vault).run(0);
        IEntryPointLogic(vault).run(0);

        vm.expectEmit();
        emit EntryPointWorkflowStatusDeactivated(0);
        IEntryPointLogic(vault).run(0);

        vm.expectRevert(
            IEntryPointLogic.EntryPoint_WorkflowIsInactive.selector
        );
        IEntryPointLogic(vault).run(0);
        vm.stopPrank();
    }

    // =========================
    // Active status logic
    // =========================

    function test_celo_entryPointLogic_deactivateVault_shouldStopAllWorkflows()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        assertTrue(IEntryPointLogic(vault).isActive());

        vm.prank(vaultOwner);
        bytes[] memory callbacks;
        IEntryPointLogic(vault).deactivateVault(callbacks);

        assertFalse(IEntryPointLogic(vault).isActive());

        vm.prank(executor);
        vm.expectRevert(IEntryPointLogic.EntryPoint_VaultIsInactive.selector);
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_deactivateVault_shouldRevertIfVaultAlreadyDeactivated()
        external
    {
        vm.startPrank(vaultOwner);

        bytes[] memory callbacks;
        IEntryPointLogic(vault).deactivateVault(callbacks);

        assertFalse(IEntryPointLogic(vault).isActive());

        vm.expectRevert(IEntryPointLogic.EntryPoint_AlreadyInactive.selector);
        IEntryPointLogic(vault).deactivateVault(callbacks);

        vm.stopPrank();
    }

    function test_celo_entryPointLogic_deactivateVault_shouldExecuteCallbacks()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.startPrank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        bytes[] memory callbacks = new bytes[](2);
        callbacks[0] = abi.encodeCall(IEntryPointLogic.deactivateWorkflow, (0));
        callbacks[1] = abi.encodeCall(
            VaultLogic.withdrawTotalNative,
            (vaultOwner)
        );
        IEntryPointLogic(vault).deactivateVault(callbacks);

        assertFalse(IEntryPointLogic(vault).isActive());

        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertTrue(workflow.inactive);

        vm.stopPrank();
    }

    function test_celo_entryPointLogic_deactivateVault_accessControl()
        external
    {
        bytes[] memory callbacks;

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                executor
            )
        );
        IEntryPointLogic(vault).deactivateVault(callbacks);
    }

    function test_celo_entryPointLogic_activateVault_shouldRunAllWorkflows()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.prank(vaultOwner);
        bytes[] memory callbacks;
        IEntryPointLogic(vault).deactivateVault(callbacks);

        assertFalse(IEntryPointLogic(vault).isActive());

        vm.prank(executor);
        vm.expectRevert(IEntryPointLogic.EntryPoint_VaultIsInactive.selector);
        IEntryPointLogic(vault).run(0);

        vm.prank(vaultOwner);
        IEntryPointLogic(vault).activateVault(callbacks);

        assertTrue(IEntryPointLogic(vault).isActive());

        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        vm.prank(executor);
        vm.expectEmit();
        emit UniswapAutoCompound(nftId);
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_activateVault_shouldRevertIfVaultAlreadyActivated()
        external
    {
        bytes[] memory callbacks;

        assertTrue(IEntryPointLogic(vault).isActive());

        vm.prank(vaultOwner);
        vm.expectRevert(IEntryPointLogic.EntryPoint_AlreadyActive.selector);
        IEntryPointLogic(vault).activateVault(callbacks);
    }

    function test_celo_entryPointLogic_activateVault_shouldExecuteCallbacks()
        external
    {
        bytes[] memory callbacks;
        vm.prank(vaultOwner);
        IEntryPointLogic(vault).deactivateVault(callbacks);
        assertFalse(IEntryPointLogic(vault).isActive());

        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        vm.startPrank(vaultOwner);
        callbacks = new bytes[](1);
        callbacks[0] = abi.encodeCall(
            IEntryPointLogic.addWorkflow,
            (checkers, actions, executor, 0)
        );
        IEntryPointLogic(vault).activateVault(callbacks);
        assertTrue(IEntryPointLogic(vault).isActive());

        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertEq(workflow.checkers.length, 1);
        assertEq(workflow.actions.length, 1);
        assertEq(workflow.executor, executor);
    }

    function test_celo_entryPointLogic_activateVault_accessControl() external {
        bytes[] memory callbacks;

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                executor
            )
        );
        IEntryPointLogic(vault).activateVault(callbacks);
    }

    function test_celo_entryPointLogic_deactivateWorkflow_shouldStopWorkflow()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertFalse(workflow.inactive);

        vm.prank(vaultOwner);
        IEntryPointLogic(vault).deactivateWorkflow(0);
        workflow = IEntryPointLogic(vault).getWorkflow(0);
        assertTrue(workflow.inactive);

        vm.prank(executor);
        vm.expectRevert(
            IEntryPointLogic.EntryPoint_WorkflowIsInactive.selector
        );
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_deactivateWorkflow_shouldRevertIfWorkflowAlreadyDeactivated()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.startPrank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        IEntryPointLogic(vault).deactivateWorkflow(0);
        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertTrue(workflow.inactive);

        vm.expectRevert(IEntryPointLogic.EntryPoint_AlreadyInactive.selector);
        IEntryPointLogic(vault).deactivateWorkflow(0);

        vm.stopPrank();
    }

    function test_celo_entryPointLogic_deactivateWorkflow_accessControl()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                executor
            )
        );
        IEntryPointLogic(vault).deactivateWorkflow(0);
    }

    function test_celo_entryPointLogic_deactivateWorkflow_shouldRevertIfWorkflowDoesNotExists()
        external
    {
        vm.prank(vaultOwner);
        vm.expectRevert(
            IEntryPointLogic.EntryPoint_WorkflowDoesNotExist.selector
        );
        IEntryPointLogic(vault).deactivateWorkflow(0);
    }

    function test_celo_entryPointLogic_activateWorkflow_shouldRunWorkflow()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.prank(vaultOwner);
        IEntryPointLogic(vault).deactivateWorkflow(0);

        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertTrue(workflow.inactive);

        vm.prank(executor);
        vm.expectRevert(
            IEntryPointLogic.EntryPoint_WorkflowIsInactive.selector
        );
        IEntryPointLogic(vault).run(0);

        vm.prank(vaultOwner);
        IEntryPointLogic(vault).activateWorkflow(0);

        workflow = IEntryPointLogic(vault).getWorkflow(0);
        assertFalse(workflow.inactive);

        vm.warp(block.timestamp + 3601);
        vm.roll(block.number + 300);

        vm.prank(executor);
        vm.expectEmit();
        emit UniswapAutoCompound(nftId);
        IEntryPointLogic(vault).run(0);
    }

    function test_celo_entryPointLogic_activateWorkflow_shouldRevertIfWorkflowAlreadyActivated()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        IEntryPointLogic.Workflow memory workflow = IEntryPointLogic(vault)
            .getWorkflow(0);
        assertFalse(workflow.inactive);

        vm.prank(vaultOwner);
        vm.expectRevert(IEntryPointLogic.EntryPoint_AlreadyActive.selector);
        IEntryPointLogic(vault).activateWorkflow(0);
    }

    function test_celo_entryPointLogic_activateWorkflow_accessControl()
        external
    {
        (
            IEntryPointLogic.Checker[] memory checkers,
            IEntryPointLogic.Action[] memory actions
        ) = _checkersAndActionsWithTimeChecker();

        multicallData.push(
            abi.encodeCall(
                IEntryPointLogic.addWorkflow,
                (checkers, actions, executor, 0)
            )
        );

        vm.prank(vaultOwner);
        ExecutionLogic(vault).multicall(multicallData);

        vm.prank(executor);
        vm.expectRevert(
            abi.encodeWithSelector(
                BaseContract.UnauthorizedAccount.selector,
                executor
            )
        );
        IEntryPointLogic(vault).activateWorkflow(0);
    }

    function test_celo_entryPointLogic_activateWorkflow_shouldRevertIfWorkflowDoesNotExists()
        external
    {
        vm.prank(vaultOwner);
        vm.expectRevert(
            IEntryPointLogic.EntryPoint_WorkflowDoesNotExist.selector
        );
        IEntryPointLogic(vault).activateWorkflow(0);
    }

    // =========================
    // Helpers
    // =========================

    function _checkersAndActionsWithTimeAndPriceCheckers()
        internal
        view
        returns (
            IEntryPointLogic.Checker[] memory,
            IEntryPointLogic.Action[] memory
        )
    {
        IEntryPointLogic.Checker[]
            memory checkers = new IEntryPointLogic.Checker[](2);
        IEntryPointLogic.Action[]
            memory actions = new IEntryPointLogic.Action[](1);

        checkers[0].data = abi.encodeWithSelector(
            TimeCheckerLogic.checkTime.selector
        );
        checkers[0].viewData = abi.encodeWithSelector(
            TimeCheckerLogic.checkTimeView.selector
        );
        checkers[0].storageRef = "time.checker.pointer";
        checkers[0].initData = abi.encodeWithSelector(
            TimeCheckerLogic.timeCheckerInitialize.selector,
            block.timestamp,
            3600
        );

        uint256 targetRate = reg.dittoOracle.consult(
            celoAddress,
            1e6,
            wethAddress,
            poolFee,
            address(reg.uniswapFactory)
        );

        checkers[1].data = abi.encodeWithSelector(
            PriceCheckerLogicUniswap.uniswapCheckGTTargetRate.selector
        );
        checkers[1].viewData = abi.encodeWithSelector(
            PriceCheckerLogicUniswap.uniswapCheckGTTargetRate.selector
        );
        checkers[1].storageRef = "price.checker.pointer";
        checkers[1].initData = abi.encodeWithSelector(
            PriceCheckerLogicUniswap.priceCheckerUniswapInitialize.selector,
            pool,
            targetRate
        );

        actions[0].data = abi.encodeCall(
            UniswapLogic.uniswapAutoCompound,
            (nftId, 0.01e18)
        );

        return (checkers, actions);
    }

    function _checkersAndActionsWithTimeChecker()
        internal
        view
        returns (
            IEntryPointLogic.Checker[] memory,
            IEntryPointLogic.Action[] memory
        )
    {
        IEntryPointLogic.Checker[]
            memory checkers = new IEntryPointLogic.Checker[](1);
        IEntryPointLogic.Action[]
            memory actions = new IEntryPointLogic.Action[](1);

        checkers[0].data = abi.encodeWithSelector(
            TimeCheckerLogic.checkTime.selector
        );
        checkers[0].viewData = abi.encodeWithSelector(
            TimeCheckerLogic.checkTimeView.selector
        );
        checkers[0].storageRef = "time.checker.pointer2";
        checkers[0].initData = abi.encodeWithSelector(
            TimeCheckerLogic.timeCheckerInitialize.selector,
            block.timestamp,
            3600
        );

        actions[0].data = abi.encodeCall(
            UniswapLogic.uniswapAutoCompound,
            (nftId, 0.01e18)
        );

        return (checkers, actions);
    }

    // Rate up
    function _rateUp() internal {
        vm.startPrank(donor);
        TransferHelper.safeApprove(
            wethAddress,
            address(reg.uniswapRouter),
            type(uint256).max
        );
        TransferHelper.safeApprove(
            celoAddress,
            address(reg.uniswapRouter),
            type(uint256).max
        );
        for (uint i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 1);
            reg.uniswapRouter.exactInputSingle(
                IV3SwapRouter.ExactInputSingleParams({
                    tokenIn: wethAddress,
                    tokenOut: celoAddress,
                    fee: poolFee,
                    recipient: donor,
                    amountIn: 2e18,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }
        vm.stopPrank();
    }

    receive() external payable {}
}
