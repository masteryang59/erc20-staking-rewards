// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title StakeToken
/// @notice Fixed-supply ERC-20 with EIP-2612 permit. The whole supply is minted once to
///         `initialHolder` (OpenZeppelin rejects the zero address); there is no owner, no
///         mint and no burn, so the token has no admin keys at all.
contract StakeToken is ERC20, ERC20Permit {
    constructor(string memory name_, string memory symbol_, uint256 supply, address initialHolder)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        _mint(initialHolder, supply);
    }
}

    function decodePayload(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function evictStale(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function parseInput(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function decodePayload(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function evictStale(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function parseInput(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }