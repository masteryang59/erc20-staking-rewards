// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {StakeToken} from "../../contracts/StakeToken.sol";

contract StakeTokenTest is Test {
    StakeToken internal token;
    address internal treasury = makeAddr("treasury");

    function setUp() public {
        token = new StakeToken("Stake Token", "STK", 100_000_000 ether, treasury);
    }

    function test_metadata() public view {
        assertEq(token.name(), "Stake Token");
        assertEq(token.symbol(), "STK");
        assertEq(token.decimals(), 18);
    }

    function test_mintsWholeSupplyToHolder() public view {
        assertEq(token.totalSupply(), 100_000_000 ether);
        assertEq(token.balanceOf(treasury), 100_000_000 ether);
    }

    function test_rejectsZeroHolder() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new StakeToken("Stake Token", "STK", 1 ether, address(0));
    }

    function test_permit_setsAllowanceAndBumpsNonce() public {
        (address holder, uint256 pk) = makeAddrAndKey("holder");
        address spender = makeAddr("spender");
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _permitDigest(holder, spender, 7 ether, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        token.permit(holder, spender, 7 ether, deadline, v, r, s);
        assertEq(token.allowance(holder, spender), 7 ether);
        assertEq(token.nonces(holder), 1);

        // A signature can be used once.
        vm.expectRevert();
        token.permit(holder, spender, 7 ether, deadline, v, r, s);
    }

    function test_permit_rejectsExpiredSignature() public {
        (address holder, uint256 pk) = makeAddrAndKey("holder");
        uint256 deadline = block.timestamp;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _permitDigest(holder, address(this), 1, 0, deadline));
        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(holder, address(this), 1, deadline, v, r, s);
    }

    function testFuzz_transferMovesExactAmount(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != treasury);
        amount = bound(amount, 0, token.balanceOf(treasury));
        vm.prank(treasury);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(treasury) + amount, token.totalSupply());
    }

    function _permitDigest(address holder, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                holder,
                spender,
                value,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }
}

    function importData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function acknowledgeReceipt(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function importData(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }

    function acknowledgeReceipt(uint256 value) public pure returns (uint256) {
        require(value > 0);
        return value;
    }