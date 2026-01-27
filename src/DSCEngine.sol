// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzepplin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzepplin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzepplin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";


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
    error DSCEngine__ExceedsMaxDscMintAmount();
    error DSCEngine__InvalidCollateralPrice(int256 price);
    error DSCEngine__DscMintFailed();


    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // borrow half of the collateral
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;


    mapping(address token => address priceFeed) private s_priceFeed;
    address[] private s_collateralTokensAddresses;
    mapping(address user => mapping(address collateralAddress => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMinted) private s_DscMintedByUser;
    uint256 private s_totalDscMinted;


    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed collateralAddress, uint256 collateralAmount);
    event DscMinted(address indexed user, uint256 amount);


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
            s_collateralTokensAddresses.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/



    function depositCollateralAndMintDsc() external {

    }

    /**
     * @notice Deposits collateral into the protocol
     * @dev
     *  1. Updates internal collateral accounting for the caller.
     *  2. Emits a {CollateralDeposited} event.
     *  3. Transfers collateral tokens from caller to this contract.
     *  4. Follows CEI (Checks, Effects, Interactions) pattern.
     * 
     * @param collateralTokenAddress Address of the ERC20 token to be deposit as collateral
     * @param collateralAmount amount of collateral tokens to deposit (in token decimals)
     * 
     * Reverts if:
     *  1. `collateralTokenAddress` is not an allowed collateral token.
     *  2. `collateralAmount` is zero.
     *  3. ERC20 `transferFrom` fails.
     * 
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
        bool success = IERC20(collateralTokenAddress).transferFrom(
            msg.sender, address(this), collateralAmount);

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
    
    /**
     * @notice Mints DSC to the caller.
     * @dev 
     *  1. Increases the `s_totalDscMinted` by creating new tokens.
     *  2. Updates the count of `DSC` tokens minted by the caller.
     *  3. Calls the `DecentralizedStableCoin` contract to mint tokens to caller.
     * 
     * Reverts if:
     *  1. The health factor for the user falls below `MIN_HEALTH_FACTOR` after minting.
     *  2. DecentralizedStableCoin `mint` operation fails.
     * 
     * @param amount Amount of tokens to  transfer to the caller.
     *
     */
    function mintDsc(uint256 amount) external greaterThanZero(amount) {
        s_DscMintedByUser[msg.sender] += amount;
        s_totalDscMinted += amount;

        _revertIfHealthFactorIsBroken(msg.sender);

        bool success = i_dsc.mint(msg.sender, amount);
        if(!success) {
            revert DSCEngine__DscMintFailed();
        }
    }

    function liquidate() external {

    }

    function getHealthFactor() external view {

    }

/**
 * @dev Returns the Total Decentralized Stable Coin tokens minted by the contract.
 */
    function getTotalDscMinted() external view returns(uint256) {
        return s_totalDscMinted;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the number of Decentralized Stable Coin tokens minted and the total collateral value in USD deposited by `user`.
     * @param user address for which the details are returned.
     * @return totalDscMinted Amount of Decentralized Stable Coin tokens minted by the user.
     * @return totalCollateralValue Value of collateral deposited by `user` in USD.
     */
    function getAccountInfo(address user) public view returns(uint256 totalDscMinted, uint256 totalCollateralValue) {
        totalDscMinted = s_DscMintedByUser[user];
        totalCollateralValue = getAccountCollateralValueInUsd(user);
    }

    /**
     * @dev Returns the total collateral value in USD for an address. It loops through all the collateralized tokens.
     * @param account address for which the total collateral value is calculated and returned.
     */
    function getAccountCollateralValueInUsd(address account) public view returns(uint256 totalCollateralValue) {
        uint256 collateralCount = s_collateralTokensAddresses.length;
        for (uint256 i = 0; i < collateralCount; i++) {
            address tokenAddress = s_collateralTokensAddresses[i];
            uint256 amountTokens = s_collateralDeposited[account][tokenAddress];
            // Skip the calculation if address has no tokens for a collateral token
            if (amountTokens == 0) {
                continue;
            }
            totalCollateralValue += _getCollateralValueInUsd(tokenAddress, amountTokens);
        }
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /**
     * @dev Calculates the price of the collateral in USD. It fetches the price of the collateral token, performs the calculation to sync the decimals for token and the price returned by the price feed, performs multiplication of token amount with current price and divides the result by token decimals to get the price in USD. 
     * @param token address of a collateral token
     * @param amount count of collateral tokens
     * @notice This function uses Chainlink Price Feeds to get the token current USD value.
     */
    function _getCollateralValueInUsd(address token, uint256 amount) internal view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        if (answer < 0) {
            revert DSCEngine__InvalidCollateralPrice(answer);
        }
        uint8 collateralTokenDecimals = _getCollateralTokenDecimals(token);
        uint8 decimalsInPriceFeed = priceFeed.decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer) * (10 ** (collateralTokenDecimals - decimalsInPriceFeed));
        uint256 amountInUsd = (amount * price)/ ( 10 ** collateralTokenDecimals);
        return amountInUsd;
    }

    /**
     * @dev Returns the decimals for a token.
     * @param token address of a token for which decimals need to be calculated
     */
    function _getCollateralTokenDecimals(address token) internal view returns(uint8) {
        return ERC20(token).decimals();
    }

    function _getMaxDscMintableAgainstCollateral(uint256 collateralValue) internal pure returns (uint256) {
        return (LIQUIDATION_THRESHOLD * collateralValue) / LIQUIDATION_PRECISION;
    }

    function _healthFactor(address account) internal view returns(uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = getAccountInfo(account);
        return (collateralValueInUsd * 100) / totalDscMinted;
        
    }

    function _revertIfHealthFactorIsBroken(address account) internal {
        (uint256 dscMinted, uint256 collateralValue) = getAccountInfo(account);
        if (_healthFactor(collateralValue, dscMinted) < MIN_HEALTH_FACTOR) {
            // uint256 maxDscCanBeMinted = 
            revert DSCEngine__ExceedsMaxDscMintAmount();
        }
    }

    function _healthFactor(uint256 collateralValue, uint256 dscMinted) internal pure returns (uint256) {
        return _calculateHealthFactor(collateralValue, dscMinted);
    }

/**@notice Returns health factor for a user's account.
 * @dev 
 *  1. Assumes the value of DSC is 1 USD always.
 *  2. Calculates the max DSC that can be minted using the collateral's value. 
 *  3. Returns the health factor by calculating the percentage of DSC minted against the maximum DSC mintable against a collateral value (with 1e18 precision). 
 * @param collateralValue Value in USD with 1e18 precision.
 * @param dscMinted Number of DSC minted against the collateral.
 */
    function _calculateHealthFactor(
        uint256 collateralValue, 
        uint256 dscMinted
    )
        internal 
        pure
        returns (uint256) 
    {
        if (dscMinted == 0) {
            return 0;
        }
        uint256 collateralAdjustedForThreshold = (LIQUIDATION_THRESHOLD * collateralValue) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / dscMinted;
    }

    function _maxDscMintable(address account) internal view returns(uint256) {
        (uint256 dscMinted, uint256 collateralValue) = getAccountInfo(account);
        uint256 maxDscMintable = _getMaxDscMintableAgainstCollateral(collateralValue);
        return maxDscMintable - dscMinted;
    } 

    
}