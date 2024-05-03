// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {
    ERC7579ModeLib,
    ERC7579ExecutionLib,
    ModeCode,
    CALLTYPE_SINGLE,
    CallType,
    ExecType
} from "modulekit/external/ERC7579.sol";
import "erc7579/lib/ModeLib.sol";
import "forge-std/console2.sol";

ModeSelector constant MODE_EIP3074 = ModeSelector.wrap(bytes4(keccak256("eip3074.invoker")));

contract ExecutionHelper {
    using ERC7579ModeLib for ModeCode;
    using ERC7579ExecutionLib for bytes;

    error InvalidMode();
    error ExecutionFailed();

    function _authCall(address to, uint256 value, bytes memory data) internal returns (bool) {
        bool success;
        uint256 length = data.length;

        assembly {
            success := authcall(gas(), to, value, data, length, 0, 0)
        }
        if (!success) revert ExecutionFailed();
    }

    function _execute(ModeCode mode, bytes calldata executionCalldata) internal {
        (
            CallType _calltype,
            ExecType _execType,
            ModeSelector _modeSelector,
            ModePayload _modePayload
        ) = mode.decode();
        // if (ModeSelector.unwrap(_modeSelector) != ModeSelector.unwrap(MODE_EIP3074)) {
        //     revert InvalidMode();
        // }

        if (_calltype == CALLTYPE_SINGLE) {
            (address to, uint256 value, bytes calldata callData) = executionCalldata.decodeSingle();
            console2.log("to: %s", to);
            console2.logBytes(callData);
            _authCall(to, value, callData);
        }
    }

    function _installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    )
        internal
    { }
}
