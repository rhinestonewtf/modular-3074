// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import {
    RhinestoneModuleKit,
    ModuleKitHelpers,
    ModuleKitUserOp,
    AccountInstance,
    UserOpData
} from "modulekit/ModuleKit.sol";
import { MODULE_TYPE_VALIDATOR } from "modulekit/external/ERC7579.sol";
import { EIP3074ERC7579Account } from "src/EIP3074ERC7579Account.sol";
import { ENTRYPOINT_ADDR } from "modulekit/test/predeploy/EntryPoint.sol";
import { IEntryPoint } from "modulekit/external/ERC4337.sol";
import { ERC7579Helpers } from "modulekit/test/utils/ERC7579Helpers.sol";
import "forge-std/console2.sol";
import { SigDecode, Operation } from "src/DataTypes.sol";
import { IAccountExecute } from
    "@ERC4337/account-abstraction/contracts/interfaces/IAccountExecute.sol";

contract InvokerTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;
    using ModuleKitUserOp for *;

    // account and modules
    AccountInstance internal instance;
    EIP3074ERC7579Account internal account;

    function setUp() public {
        init();

        // Create the validator
        account = new EIP3074ERC7579Account(IEntryPoint(ENTRYPOINT_ADDR));
        vm.label(address(account), "EIP3074ERC7579Account");

        // Create the account and install the validator
        instance = makeAccountInstance("ValidatorTemplate", address(account), "");
        vm.deal(address(instance.account), 10 ether);
    }

    function testExec() public {
        // Create a target address and send some ether to it
        address target = makeAddr("target");
        uint256 value = 1 ether;

        address validator = address(instance.defaultValidator);

        // Get the UserOp data (UserOperation and UserOperationHash)
        UserOpData memory userOpData = instance.getExecOps({
            target: target,
            value: value,
            callData: "",
            txValidator: validator
        });

        (address eoa, uint256 eoaKey) = makeAddrAndKey("eoa");
        vm.deal(eoa, 10 ether);
        userOpData.userOp.nonce =
            ERC7579Helpers.getNonce(address(instance.account), IEntryPoint(ENTRYPOINT_ADDR), eoa);

        // Set the signature
        bytes memory sigPart1 = SigDecode.packSelection({
            operation: Operation.MOCK,
            validator: validator,
            nonce: vm.getNonce(eoa)
        });
        bytes32 commit = keccak256(abi.encodePacked(validator, bytes("")));
        uint64 nonce = vm.getNonce(address(eoa));
        bytes32 hash = account.getDigest(commit, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaKey, hash);
        bytes memory authSig = abi.encodePacked(r, s, v);

        bytes memory sigPart2 = abi.encode(authSig, authSig);

        userOpData.userOp.signature = abi.encodePacked(sigPart1, sigPart2);

        userOpData.userOp.callData =
            abi.encodePacked(IAccountExecute.executeUserOp.selector, userOpData.userOp.callData);

        // Execute the UserOp
        userOpData.execUserOps();

        // Check if the balance of the target has increased
        assertEq(target.balance, 1 ether);
    }
}
