// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma experimental ABIEncoderV2;

import {IVault} from "./interfaces/IVault.sol";
import {IFlashLoanRecipient} from "./interfaces/IFlashLoanRecipient.sol";
import {IERC20Permit} from "@openzeppelin/contracts/drafts/IERC20Permit.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {DepotFacet} from "./facets/DepotFacet.sol";
import {TokenSupportFacet} from "./facets/TokenSupportFacet.sol";
import {IBeanstalk, To, From} from "./interfaces/IBeanstalk.sol";
import {IERC4494} from "./interfaces/IERC4494.sol";
import {LibFunction} from "./libraries/LibFunction.sol";
import {LibFlashLoan} from "./libraries/LibFlashLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";



/**
 * @title FlashDepot
 * @author Publius, Brean
 * @notice Depot wraps Pipeline's Pipe functions to facilitate the loading of non-Ether assets in Pipeline
 * in the same transaction that loads Ether, Pipes calls to other protocols and unloads Pipeline.
 * Added balancer flash-loan functionality 
 * https://evmpipeline.org
**/

contract Depot is IFlashLoanRecipient, DepotFacet, TokenSupportFacet {

    using SafeERC20 for IERC20;
    
    IBeanstalk private constant beanstalk =
        IBeanstalk(0xC1E088fC1323b20BCBee9bd1B9fC9546db5624C5);
    address private constant vault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    /**
     * 
     * Farm
     * 
    **/

    /**
     * @notice Execute multiple function calls in Depot.
     * @param data list of encoded function calls to be executed
     * @return results list of return data from each function call
     * @dev Implementation from https://github.com/Uniswap/v3-periphery/blob/main/contracts/base/Multicall.sol.
    **/
    function farm(bytes[] calldata data)
        external
        payable
        returns (bytes[] memory results)
    {
        return _farm(data);
    }
    
    function _farm(bytes[] calldata data)
        internal
        returns (bytes[] memory results)
    {
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);
            LibFunction.checkReturn(success, result);
            results[i] = result;
        }
    }

    /**
     *
     * Transfer
     *
    **/

    /**
     * @notice Execute a Beanstalk ERC-20 token transfer.
     * @dev See {TokenFacet-transferToken}.
     * @dev Only supports INTERNAL and EXTERNAL From modes.
    **/
    function transferToken(
        IERC20 token,
        address recipient,
        uint256 amount,
        From fromMode,
        To toMode
    ) external payable {
        if (fromMode == From.EXTERNAL) {
            token.transferFrom(msg.sender, recipient, amount);
        } else if (fromMode == From.INTERNAL) {
            beanstalk.transferInternalTokenFrom(token, msg.sender, recipient, amount, toMode);
        } else {
            revert("Mode not supported");
        }
    }

    /**
     * @notice Execute a single Beanstalk Deposit transfer.
     * @dev See {SiloFacet-transferDeposit}.
    **/
    function transferDeposit(
        address sender,
        address recipient,
        address token,
        uint32 season,
        uint256 amount
    ) external payable returns (uint256 bdv) {
        require(sender == msg.sender, "invalid sender");
        bdv = beanstalk.transferDeposit(msg.sender, recipient, token, season, amount);
    }

    /**
     * @notice Execute multiple Beanstalk Deposit transfers of a single Whitelisted Tokens.
     * @dev See {SiloFacet-transferDeposits}.
    **/
    function transferDeposits(
        address sender,
        address recipient,
        address token,
        uint32[] calldata seasons,
        uint256[] calldata amounts
    ) external payable returns (uint256[] memory bdvs) {
        require(sender == msg.sender, "invalid sender");
        bdvs = beanstalk.transferDeposits(msg.sender, recipient, token, seasons, amounts);
    }

    /**
     *
     * Permits
     *
    **/

    /**
     * @notice Execute a permit for an ERC-20 Token stored in a Beanstalk Farm balance.
     * @dev See {TokenFacet-permitToken}.
    **/
    function permitToken(
        address owner,
        address spender,
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {
        beanstalk.permitToken(owner, spender, token, value, deadline, v, r, s);
    }

    /**
     * @notice Execute a permit for Beanstalk Deposits of a single Whitelisted Token.
     * @dev See {SiloFacet-permitDeposit}.
    **/
    function permitDeposit(
        address owner,
        address spender,
        address token,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {
        beanstalk.permitDeposit(owner, spender, token, value, deadline, v, r, s);
    }

    /**
     * @notice Execute a permit for a Beanstalk Deposits of a multiple Whitelisted Tokens.
     * @dev See {SiloFacet-permitDeposits}.
    **/
    function permitDeposits(
        address owner,
        address spender,
        address[] calldata tokens,
        uint256[] calldata values,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external payable {
        beanstalk.permitDeposits(owner, spender, tokens, values, deadline, v, r, s);
    }

    function receiveFlashLoan(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        uint256[] memory,
        bytes memory userData
    ) external override {
        require(msg.sender == vault);
        // convert userData back into bytes

        bytes[] memory data = new bytes[](1);
        data[0] = userData;
        this.farm(data);
        for(uint i; i < tokens.length; ++i ){
            tokens[i].transfer(vault, amounts[i]);
        }
    }

    
    // flash pipe embeds a flash loan call to balancer.
    // flash pipe calls {farm}, and converts data into bytes
    // to be compatable with pipeline. 
    function flashPipe(
        IERC20[] memory tokens,
        uint256[] memory amounts,
        bytes[] calldata data
    ) external {
        // convert data[] into data 
        bytes memory _data = new bytes(32);
        _data = data[0];
        IVault(vault).flashLoan(IFlashLoanRecipient(this), tokens, amounts, _data);
    }

    function flashMultiPipe(

    ) public {

    }

    function flashAdvancedPipe(

    ) public {

    }

    function convertBytesIntoBytesArray(bytes memory data) 
        public 
        view 
        returns(bytes[] memory Newdata){}
}
