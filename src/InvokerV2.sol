// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "erc7579/lib/ModeLib.sol";
import { ExecutionLib } from "erc7579/lib/ExecutionLib.sol";
import { ExecutionHelper } from "erc7579/core/ExecutionHelper.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import "erc7579/interfaces/IERC7579Module.sol";
import { IERC7579Account } from "erc7579/interfaces/IERC7579Account.sol";
import { IMSA } from "erc7579/interfaces/IMSA.sol";
import { ModuleManager } from "erc7579/core/ModuleManager.sol";
import { HookManager } from "erc7579/core/HookManager.sol";
import { IStatelessValidator } from "./interfaces/IStatelessValidator.sol";
import { CallType } from "erc7579/lib/ModeLib.sol";
import { Auth } from "./utils/Auth.sol";
import "./utils/utils.sol";

import "forge-std/console2.sol";

/**
 * @author zeroknots.eth | rhinestone.wtf
 * Reference implementation of a very simple ERC7579 Account.
 * This account implements CallType: SINGLE, BATCH and DELEGATECALL.
 * This account implements ExecType: DEFAULT and TRY.
 * Hook support is implemented
 */
contract InvokerV2 is IMSA, ExecutionHelper, ModuleManager, HookManager, Auth {
    using ExecutionLib for bytes;
    using ModeLib for ModeCode;

    error MismatchModuleTypeId(uint256);

    /**
     * @inheritdoc IERC7579Account
     * @dev this function is only callable by the entry point or the account itself
     * @dev this function demonstrates how to implement
     * CallType SINGLE and BATCH and ExecType DEFAULT and TRY
     * @dev this function demonstrates how to implement hook support (modifier)
     */
    function execute(
        ModeCode mode,
        bytes calldata executionCalldata
    )
        external
        payable
        onlyEntryPointOrSelf
        withHook
    {
        (CallType callType, ExecType execType,,) = mode.decode();

        // check if calltype is batch or single
        if (callType == CALLTYPE_BATCH) {
            // destructure executionCallData according to batched exec
            Execution[] calldata executions = executionCalldata.decodeBatch();
            // check if execType is revert or try
            if (execType == EXECTYPE_DEFAULT) _execute(executions);
            else if (execType == EXECTYPE_TRY) _tryExecute(executions);
            else revert UnsupportedExecType(execType);
        } else if (callType == CALLTYPE_SINGLE) {
            // destructure executionCallData according to single exec
            (address target, uint256 value, bytes calldata callData) =
                executionCalldata.decodeSingle();
            // check if execType is revert or try
            if (execType == EXECTYPE_DEFAULT) _execute(target, value, callData);
            // TODO: implement event emission for tryExecute singleCall
            else if (execType == EXECTYPE_TRY) _tryExecute(target, value, callData);
            else revert UnsupportedExecType(execType);
        } else if (callType == CALLTYPE_DELEGATECALL) {
            // destructure executionCallData according to single exec
            address delegate = address(uint160(bytes20(executionCalldata[0:20])));
            bytes calldata callData = executionCalldata[20:];
            // check if execType is revert or try
            if (execType == EXECTYPE_DEFAULT) _executeDelegatecall(delegate, callData);
            else if (execType == EXECTYPE_TRY) _tryExecuteDelegatecall(delegate, callData);
            else revert UnsupportedExecType(execType);
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    function doAuth(address eoa, bytes calldata authSig) internal {
        Signature memory sig = Signature({
            signer: eoa,
            yParity: vToYParity(uint8(bytes1(authSig[64]))),
            r: bytes32(authSig[0:32]),
            s: bytes32(authSig[32:64])
        });
        bool success = auth(bytes32(0), sig);
        require(success, "Auth failed");
    }

    function _authCall(address target, uint256 value, bytes memory data) internal returns (bool) {
        bool success;
        uint256 length = data.length;

        assembly {
            success := authcall(gas(), target, value, data, length, 0, 0)
        }
        if (!success) revert ExecutionFailed();
    }

    /**
     * @inheritdoc IERC7579Account
     * @dev this function is only callable by an installed executor module
     * @dev this function demonstrates how to implement
     * CallType SINGLE and BATCH and ExecType DEFAULT and TRY
     * @dev this function demonstrates how to implement hook support (modifier)
     */
    function executeFromExecutor(
        ModeCode mode,
        bytes calldata executionCalldata
    )
        external
        payable
        onlyExecutorModule
        withHook
        returns (
            bytes[] memory returnData // TODO returnData is not used
        )
    {
        (CallType callType, ExecType execType,,) = mode.decode();

        // check if calltype is batch or single
        if (callType == CALLTYPE_BATCH) {
            // destructure executionCallData according to batched exec
            Execution[] calldata executions = executionCalldata.decodeBatch();
            // check if execType is revert or try
            if (execType == EXECTYPE_DEFAULT) returnData = _execute(executions);
            else if (execType == EXECTYPE_TRY) returnData = _tryExecute(executions);
            else revert UnsupportedExecType(execType);
        } else if (callType == CALLTYPE_SINGLE) {
            // destructure executionCallData according to single exec
            (address target, uint256 value, bytes calldata callData) =
                executionCalldata.decodeSingle();
            returnData = new bytes[](1);
            bool success;
            // check if execType is revert or try
            if (execType == EXECTYPE_DEFAULT) {
                returnData[0] = _execute(target, value, callData);
            }
            // TODO: implement event emission for tryExecute singleCall
            else if (execType == EXECTYPE_TRY) {
                (success, returnData[0]) = _tryExecute(target, value, callData);
                if (!success) emit TryExecuteUnsuccessful(0, returnData[0]);
            } else {
                revert UnsupportedExecType(execType);
            }
        } else if (callType == CALLTYPE_DELEGATECALL) {
            // destructure executionCallData according to single exec
            address delegate = address(uint160(bytes20(executionCalldata[0:20])));
            bytes calldata callData = executionCalldata[20:];
            // check if execType is revert or try
            if (execType == EXECTYPE_DEFAULT) _executeDelegatecall(delegate, callData);
            else if (execType == EXECTYPE_TRY) _tryExecuteDelegatecall(delegate, callData);
            else revert UnsupportedExecType(execType);
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    /**
     * @dev ERC-4337 executeUserOp according to ERC-4337 v0.7
     *         This function is intended to be called by ERC-4337 EntryPoint.sol
     * @dev Ensure adequate authorization control: i.e. onlyEntryPointOrSelf
     *      The implementation of the function is OPTIONAL
     *
     * @param userOp PackedUserOperation struct (see ERC-4337 v0.7+)
     */
    function executeUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        external
        payable
        onlyEntryPointOrSelf
    {
        bytes calldata userOpCallData = userOp.callData[4:];
        ModeCode mode = ModeCode.wrap(bytes32(userOpCallData[4:36]));
        (CallType callType, ExecType execType,,) = mode.decode();

        if (callType == CALLTYPE_SINGLE) {
            // destructure executionCallData according to single exec

            bytes calldata authSig;

            bytes calldata sig = userOp.signature;
            assembly {
                let offset := sig.offset
                let baseOffset := offset
                let dataPointer := add(offset, calldataload(offset))

                offset := add(offset, 64)

                dataPointer := add(baseOffset, calldataload(offset))
                authSig.offset := add(dataPointer, 32)
                authSig.length := calldataload(dataPointer)
            }

            address eoa;
            uint256 nonce = userOp.nonce;
            assembly {
                eoa := shr(96, nonce)
            }
            doAuth(eoa, authSig);

            (address target, uint256 value, bytes calldata callData) =
                ExecutionLib.decodeSingle(userOpCallData[100:]);
            _authCall(target, value, callData);
        } else {
            revert UnsupportedCallType(callType);
        }
    }

    function executeUserOp(PackedUserOperation calldata userOp)
        external
        payable
        onlyEntryPointOrSelf
    {
        revert();
    }

    /**
     * @inheritdoc IERC7579Account
     */
    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    )
        external
        payable
        onlyEntryPointOrSelf
        withHook
    {
        if (!IModule(module).isModuleType(moduleTypeId)) revert MismatchModuleTypeId(moduleTypeId);

        if (moduleTypeId == MODULE_TYPE_VALIDATOR) _installValidator(module, initData);
        else if (moduleTypeId == MODULE_TYPE_EXECUTOR) _installExecutor(module, initData);
        else if (moduleTypeId == MODULE_TYPE_FALLBACK) _installFallbackHandler(module, initData);
        else if (moduleTypeId == MODULE_TYPE_HOOK) _installHook(module, initData);
        else revert UnsupportedModuleType(moduleTypeId);
        emit ModuleInstalled(moduleTypeId, module);
    }

    /**
     * @inheritdoc IERC7579Account
     */
    function uninstallModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata deInitData
    )
        external
        payable
        onlyEntryPointOrSelf
        withHook
    {
        if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
            _uninstallValidator(module, deInitData);
        } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            _uninstallExecutor(module, deInitData);
        } else if (moduleTypeId == MODULE_TYPE_FALLBACK) {
            _uninstallFallbackHandler(module, deInitData);
        } else if (moduleTypeId == MODULE_TYPE_HOOK) {
            _uninstallHook(module, deInitData);
        } else {
            revert UnsupportedModuleType(moduleTypeId);
        }
        emit ModuleUninstalled(moduleTypeId, module);
    }

    /**
     * @dev ERC-4337 validateUserOp according to ERC-4337 v0.7
     *         This function is intended to be called by ERC-4337 EntryPoint.sol
     * this validation function should decode / sload the validator module to validate the userOp
     * and call it.
     *
     * @dev MSA MUST implement this function signature.
     * @param userOp PackedUserOperation struct (see ERC-4337 v0.7+)
     */
    function validateUserOp(
        PackedUserOperation memory userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    )
        external
        payable
        virtual
        onlyEntryPointOrSelf
        payPrefund(missingAccountFunds)
        returns (uint256 validSignature)
    {
        (address validator, bytes memory signature,) =
            abi.decode(userOp.signature, (address, bytes, bytes));

        // check if validator is enabled. If not terminate the validation phase.
        // if (!_isValidatorInstalled(validator)) return VALIDATION_FAILED;

        // bubble up the return value of the validator module
        // todo: load data
        bool success =
            IStatelessValidator(validator).validateSignatureWithData(userOpHash, signature, "");
        return success ? VALIDATION_SUCCESS : VALIDATION_FAILED;
    }

    /**
     * @dev ERC-1271 isValidSignature
     *         This function is intended to be used to validate a smart account signature
     * and may forward the call to a validator module
     *
     * @param hash The hash of the data that is signed
     * @param data The data that is signed
     */
    function isValidSignature(
        bytes32 hash,
        bytes calldata data
    )
        external
        view
        virtual
        override
        returns (bytes4)
    {
        address validator = address(bytes20(data[0:20]));
        if (!_isValidatorInstalled(validator)) revert InvalidModule(validator);
        return IValidator(validator).isValidSignatureWithSender(msg.sender, hash, data[20:]);
    }

    /**
     * @inheritdoc IERC7579Account
     */
    function isModuleInstalled(
        uint256 moduleTypeId,
        address module,
        bytes calldata additionalContext
    )
        external
        view
        override
        returns (bool)
    {
        if (moduleTypeId == MODULE_TYPE_VALIDATOR) {
            return _isValidatorInstalled(module);
        } else if (moduleTypeId == MODULE_TYPE_EXECUTOR) {
            return _isExecutorInstalled(module);
        } else if (moduleTypeId == MODULE_TYPE_FALLBACK) {
            return _isFallbackHandlerInstalled(abi.decode(additionalContext, (bytes4)), module);
        } else if (moduleTypeId == MODULE_TYPE_HOOK) {
            return _isHookInstalled(module);
        } else {
            return false;
        }
    }

    /**
     * @inheritdoc IERC7579Account
     */
    function accountId() external view virtual override returns (string memory) {
        // vendor.flavour.SemVer
        return "uMSA.advanced/withHook.v0.1";
    }

    /**
     * @inheritdoc IERC7579Account
     */
    function supportsExecutionMode(ModeCode mode)
        external
        view
        virtual
        override
        returns (bool isSupported)
    {
        (CallType callType, ExecType execType,,) = mode.decode();
        if (callType == CALLTYPE_BATCH) isSupported = true;
        else if (callType == CALLTYPE_SINGLE) isSupported = true;
        else if (callType == CALLTYPE_DELEGATECALL) isSupported = true;
        // if callType is not single, batch or delegatecall return false
        else return false;

        if (execType == EXECTYPE_DEFAULT) isSupported = true;
        else if (execType == EXECTYPE_TRY) isSupported = true;
        // if execType is not default or try, return false
        else return false;
    }

    /**
     * @inheritdoc IERC7579Account
     */
    function supportsModule(uint256 modulTypeId) external view virtual override returns (bool) {
        if (modulTypeId == MODULE_TYPE_VALIDATOR) return true;
        else if (modulTypeId == MODULE_TYPE_EXECUTOR) return true;
        else if (modulTypeId == MODULE_TYPE_FALLBACK) return true;
        else if (modulTypeId == MODULE_TYPE_HOOK) return true;
        else return false;
    }

    /**
     * @dev Initializes the account. Function might be called directly, or by a Factory
     * @param data. encoded data that can be used during the initialization phase
     */
    function initializeAccount(bytes calldata data) public payable virtual {
        // checks if already initialized and reverts before setting the state to initialized
        _initModuleManager();

        // this is just implemented for demonstration purposes. You can use any other initialization
        // logic here.
        (address bootstrap, bytes memory bootstrapCall) = abi.decode(data, (address, bytes));
        (bool success,) = bootstrap.delegatecall(bootstrapCall);
        if (!success) revert();
    }
}
