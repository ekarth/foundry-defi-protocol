// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzepplin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzepplin/contracts/token/ERC20/IERC20.sol";
 
/**
 * @title DSCEngine
 * @author Killer
 * The system is designed to be as minimal as possible & have the tokens maintain a i token == $1 peg
 * This stablecoin has the properties:
 *  - Exogenous Collateral (wBTC and wETH)
 *  - Dollar pegged
 *  - Algorithmic Stable
 * It is similar to DAI stablecoin if it had no governance, no fees and was only backed by wETH and wBTC.
 * Our DSC system should always be "overcollateralised". At no point, should the value of all collateral <= $ backed value of all the DSC.
 * @notice This contract is the core of the DSC System. It handles all for minting and redeeming DSC, as well as depositing and withdrawing collateral. 
 */
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error DSCEngine__ZeroAmount();
    error DSCEngine__TokenCannotBeCollateralized(address token);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__CollateralDepositFailed(address user, address token);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    DecentralizedStableCoin private immutable i_dsc;

    mapping(address token => address priceFeed) private s_priceFeed;
    mapping(address user => mapping(address collateralAddress => uint256 amount)) s_collateralDeposited;


    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address user, address indexed collateralAddress, uint256 collateralAmount);


    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier greaterThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__ZeroAmount();
        } 
        _;
    }

    modifier isTokenAllowed(address tokenAddress) {
        if(s_priceFeed[tokenAddress] == address(0)) {
            revert DSCEngine__TokenCannotBeCollateralized(tokenAddress);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor(
        address[] memory tokenAddresses, 
        address[] memory tokenPriceFeedAddresses,
        address dscAddress) {

        if (tokenAddresses.length != tokenPriceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        uint256 count = tokenAddresses.length;
        for(uint256 i = 0; i < count; i++) {
            s_priceFeed[tokenAddresses[i]] = tokenPriceFeedAddresses[i];
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/



    function depositCollateralAndMintDsc() external {

    }
    /**
     * @notice follows CEI (Checks, Effects, Interactions) pattern
     * @dev Deposit the collatera
     * @param collateralTokenAddress address of the token to be deposit as collateral
     * @param collateralAmount amount of tokens to be used as collateral
     * Requirements:
     *  1. `collateralTokenAddress` must match either wBTC or wETH address.
     *  2. `collateralAmount` should be greater than 0.
     */
    function depositCollateral(
        address collateralTokenAddress,
        uint256 collateralAmount
    ) 
        external 
        greaterThanZero(collateralAmount) 
        isTokenAllowed(collateralTokenAddress) 
        nonReentrant 
    {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);

        // transfer tokens from user EOA
        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);

        if (!success) {
            revert DSCEngine__CollateralDepositFailed(msg.sender, collateralTokenAddress);
        }
    }

    function redeemCollateralForDsc() external {

    }

    function redeemCollateral() external {

    }

    function burnDsc() external {

    }
    
    function mintDsc() external {

    }

    function liquidate() external {

    }

    function getHealthFactor() external view {

    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/


}