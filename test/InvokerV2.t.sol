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
import { InvokerV2 } from "src/InvokerV2.sol";
import { ENTRYPOINT_ADDR } from "modulekit/test/predeploy/EntryPoint.sol";
import { IEntryPoint } from "modulekit/external/ERC4337.sol";
import { ERC7579Helpers } from "modulekit/test/utils/ERC7579Helpers.sol";
import "forge-std/console2.sol";
import { SigDecode, Operation } from "src/DataTypes.sol";
import { IAccountExecute } from
    "@ERC4337/account-abstraction/contracts/interfaces/IAccountExecute.sol";
import { MockValidator } from "./mocks/MockValidator.sol";

contract InvokerV2Test is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;
    using ModuleKitUserOp for *;

    // account and validator
    AccountInstance internal instance;
    InvokerV2 internal account;
    MockValidator internal mockValidator;

    function setUp() public {
        init();

        // Create the invoker
        account = new InvokerV2();
        vm.label(address(account), "InvokerV2");

        // Create the account
        instance = makeAccountInstance("InvokerV2", address(account), "");
        vm.deal(address(instance.account), 10 ether);
    }

    function testExec() public {
        // Create a target address and send some ether to it
        address target = makeAddr("target");
        uint256 value = 1 ether;

        // Create the validator
        MockValidator mockValidator = new MockValidator();
        address _validator = address(mockValidator);

        // Get the UserOp data (UserOperation and UserOperationHash)
        UserOpData memory userOpData = instance.getExecOps({
            target: target,
            value: value,
            callData: "",
            txValidator: _validator
        });

        // Create an EOA and send some ether to it
        (address eoa, uint256 eoaKey) = makeAddrAndKey("eoa");
        vm.deal(eoa, 10 ether);

        // Encode the EOA in the nonce
        userOpData.userOp.nonce =
            ERC7579Helpers.getNonce(address(instance.account), IEntryPoint(ENTRYPOINT_ADDR), eoa);

        // Create the authSig
        uint64 nonce = vm.getNonce(address(eoa));
        bytes32 hash = account.getDigest(bytes32(0), nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaKey, hash);
        bytes memory authSig = abi.encodePacked(r, s, v);

        // Create the validatorSig - left blank for mock validator
        bytes memory validatorSig = bytes("");

        // Encode the signatures
        userOpData.userOp.signature = abi.encode(_validator, validatorSig, authSig);

        // Encode the UserOp calldata to use executeUserOp
        userOpData.userOp.callData =
            abi.encodePacked(IAccountExecute.executeUserOp.selector, userOpData.userOp.callData);

        // Execute the UserOp
        userOpData.execUserOps();

        // Check if the balance of the target has increased and the balance of the EOA has decreased
        assertEq(target.balance, 1 ether);
        assertGt(instance.account.balance, 9 ether);
        assertEq(eoa.balance, 9 ether);
    }
}
