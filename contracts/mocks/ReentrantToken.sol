// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test double: an ERC-777-style token that calls back into `target` on every transfer,
///      the way a token hook would hand control to an attacker mid-transfer.
contract ReentrantToken is ERC20 {
    address public target;
    bytes public callbackData;
    bool private _entered;

    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setCallback(address target_, bytes calldata data) external {
        target = target_;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (target != address(0) && !_entered && from != address(0)) {
            _entered = true;
            (bool ok, bytes memory ret) = target.call(callbackData);
            _entered = false;
            if (!ok) {
                // Bubble the revert so tests can assert on the guard's error.
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }
}

    function generateReport(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function transcodeVideo(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function logEvent(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function generateReport(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }