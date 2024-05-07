import { IStatelessValidator } from "src/interfaces/IStatelessValidator.sol";

contract MockValidator is IStatelessValidator {
    function validateSignatureWithData(
        bytes32 hash,
        bytes calldata signature,
        bytes calldata data
    )
        external
        view
        returns (bool)
    {
        return true;
    }
}
