   // SPDX-License-Identifier: MIT

// layout of contract
// version
// imports
// intefaces, libraries, contracts
// errors
// type declarations
// state variables
// Events
// modifiers
// functions

// Layout of functions:
// constructor
// recieve function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view and pure functions

pragma solidity ^0.8.18;

import {ERC20Burnable,ERC20} from "@openzeppelin/contracts/token/ERC20/Extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/console.sol";
/**
 * @title DecentralizedStableCoin
 * @author Darab Ahmad khan
 * Collateral: Exogenous (ETH and BTC)
 * Minting: ALgorithmic
 * Relative Stablitity: Pegged to the USD
 * 
 * This contract is meant to be governed by DSCEngine. This contract is just ERC20 implementation of our stablecoin system
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {

    error DecentralizedStableCoin_MustBeMoreThanZero();
    error DecentralizedStableCoin_BurnAmountExceedsBalance();
    error DecentralizedStableCoin_NotZeroAddress();

    constructor() ERC20("Decentralized Stable Coin", "DSC") Ownable(msg.sender)  {
        
    }


    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance= balanceOf(msg.sender);
        if(_amount <= 0){
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }

        if(balance < _amount){
            revert DecentralizedStableCoin_BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool){
        if(_to == address(0)){
            revert DecentralizedStableCoin_NotZeroAddress();
        }
        if(_amount <= 0){
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }

}