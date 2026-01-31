// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;


import {ERC20Burnable} from "@openzepplin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20} from "@openzepplin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzepplin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author KILLER
 * @notice Decentralized Stable coin which 
 *  - uses exogenous collateral (wETH and wBTC) 
 *  - 100% algorithmic minting
 *  - pegged to $1
 * @dev This contract is meant to be governed by DSCEngine. This contract is just the ERC20 implementation of the stablecoin system.
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeGreaterThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance(uint256 balance, uint256 burnAmount);
    error DecentralizedStableCoin__NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") {}

    /**
     * @dev Destroys `_amount` number of tokens, reducing the total supply. It can only be called by the owner of the contract. It calls the burn function in ERC20Burnable parent contract to burn the tokens.
     * @param _amount number of tokens to burn.
     * 
     * Requirements:
     *      1. `_amount` shold be greater than 0.
     *      2. `msg.sender` should have atleast `_amount` tokens.
     */
    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount == 0) {
            revert DecentralizedStableCoin__AmountMustBeGreaterThanZero();
        }
        if (_amount < balance) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance(
                balance,
                _amount
            );
        }

        super.burn(_amount);
    }

    /**
     * @dev Creates `_amount` number fo tokens and assign them to `_to` address increasing the total supply.
     * @param _to address to which the tokens are assigned.
     * @param _amount number of tokens created and assigned.
     * 
     * Requirements:
     *      1. `_to` cannot be Zero Address.
     *      2. `_amount` should be greater than 0.
     * 
     * @return bool if the tokens are successfully created and assigned to address `_to`.
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns(bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }

        if (_amount == 0) {
            revert DecentralizedStableCoin__AmountMustBeGreaterThanZero();
        }

        _mint(_to, _amount);
        return true;
    }
}