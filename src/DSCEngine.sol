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
    error DSCEngine__NotSupportedCollatralizedToken(address token);
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__CollateralDepositFailed(address user, address token);
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__InvalidCollateralPrice(int256 price);
    error DSCEngine__DscMintFailed();
    error DSCEngine__RedeemMoreCollateralThanDeposited(address token, uint256 tokensDeposited, uint256 redeemAmount);
    error DSCEngine__CollateralRedeemFailed(address user, address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    DecentralizedStableCoin private immutable i_dsc;
    address private immutable deployer;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // borrow half of the collateral
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10%


    mapping(address token => address priceFeed) private s_priceFeed;
    address[] private s_collateralTokensAddresses;
    mapping(address user => mapping(address collateralAddress => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscMinted) private s_DscMintedByUser;
    uint256 private s_totalDscMinted;


    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralRedeemed(address indexed from, address indexed to, address indexed token, uint256 amount);
    event DscMinted(address indexed user, uint256 amount);
    event DscBurned(address indexed user, uint256 amount);


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
            revert DSCEngine__NotSupportedCollatralizedToken(tokenAddress);
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
        deployer = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This function deposits collateral and mints DSC to the caller.
     * @dev
     *  1. Calls `depositCollateral` function to deposit collateral from caller.
     *  2. Calls `mintDsc` function to mint DSC to caller.
     * Reverts if:
     *  1. `collateralAmount` is 0.
     *  2. `collateralTokenAddress` is not an allowed collateral token.
     *  3. Collateral transfer fails.
     *  4. `amountDscToMint` is 0.
     *  5. The resulting health factor while simulating DSC minting is below `MIN_HEALTH_FACTOR`.
     *  6. The DSC mint operation fails.
     * 
     * @param collateralTokenAddress Address of the ERC20 token to be deposit as collateral
     * @param collateralAmount amount of collateral tokens to deposit (in token decimals)
     * @param amountDscToMint Amount of DSC tokens to mint to the caller (18 decimals).
     * 
     */    
    function depositCollateralAndMintDsc(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) 
        external 
    {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Burns minted DSC tokens and redeems collateral for the user in a single transaction.
     * @dev
     * 1. Calls {burnDsc} to burn the specified amount of DSC tokens from the caller.
     * 2. Calls {redeemCollateral} to withdraw the specified amount of collateral tokens to the caller.
     * 3. The order is important: DSC is burned before collateral is redeemed to ensure health factor checks are accurate.
     *
     * Reverts if:
     *  1. `amountDscToBurn` is zero.
     *  2. `collateralAmount` is zero.
     *  3. `collateralTokenAddress` is not a supported collateral token.
     *  4. The caller tries to redeem more collateral than deposited.
     *  5. The resulting health factor after redeeming collateral falls below `MIN_HEALTH_FACTOR`..
     *  6. ERC20 transfer for collateral fails.
     *  7. DSC transfer or burn fails.
     *
     * @param collateralTokenAddress Address of the ERC20 token to redeem as collateral.
     * @param collateralAmount Amount of collateral tokens to redeem (in token decimals).
     * @param amountDscToBurn Amount of DSC tokens to burn from the caller (18 decimals).
     */
    function redeemCollateralForDsc(
        address collateralTokenAddress,
        uint256 collateralAmount,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralTokenAddress, collateralAmount);
    }

    /**
     * @notice Liquidates an undercollateralized user by repaying their DSC debt in exchange for their collateral plus a 10% liquidation bonus. Ensures that the amount of debt to cover (`debtToCover`) does not exceed the user's total DSC tokens borrowed.
     *
     * @dev
     * - The caller repays `debtToCover` DSC on behalf of `user`
     * - If `debtToCover` is greater than the `user`'s outstanding debt, it is capped at the `user`'s maximum borrowed DSC tokens.
     * - The protocol converts the repaid debt into an equivalent amount of collateral
     * - A liquidation bonus is added and transferred to the caller
     * - The user's DSC debt is reduced and their collateral is seized
     * - The liquidation must improve the user's health factor
     * - The liquidator must remain sufficiently collateralized after liquidation
     *
     * Reverts if:
     * - `debtToCover` is zero
     * - `collateralTokenAddress` is not an allowed collateral token
     * - The user's health factor is not below `MIN_HEALTH_FACTOR`
     * - The liquidation does not improve the user's health factor
     * - The liquidator's health factor falls below `MIN_HEALTH_FACTOR`
     *
     * @param collateralTokenAddress Address of the collateral token to seize
     * @param user Address of the undercollateralized account being liquidated
     * @param debtToCover Amount of DSC debt to repay on behalf of the user (18 decimals)
     */
    function liquidate(
        address collateralTokenAddress, 
        address user, 
        uint256 debtToCover
    ) 
        external 
        isTokenAllowed(collateralTokenAddress) 
        greaterThanZero(debtToCover) 
        nonReentrant 
    {
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        uint256 userDebt = s_DscMintedByUser[user];
        // updating debtToCover when more than the debt
        if (debtToCover > userDebt) {
            debtToCover = userDebt;
        }


        uint256 tokenAmountFromDebtToCover = getAmountCollateralFromUsd(collateralTokenAddress, debtToCover);
        // bonus for the liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtToCover * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtToCover + bonusCollateral;
        _redeemCollateral(collateralTokenAddress, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(user, msg.sender, debtToCover);
        
        if (debtToCover == userDebt) {
        _redeemCollateral(collateralTokenAddress, s_collateralDeposited[user][collateralTokenAddress], user, deployer);
        }

        uint256 userEndingHealthFactor = _healthFactor(user);
        if (userEndingHealthFactor <= userStartingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        } 
        _revertIfHealthFactorIsBroken(msg.sender);

    }

    /**
     * @notice Returns the health factor for a user with 1e18 precision.
     * @param user Address of user to return health factor for.
     */
    function getHealthFactor(address user) external view returns(uint256) {
        return _healthFactor(user);
    }

    /**
     * @notice Returns the count of ERC20 collateral tokens deposited by a user.
     * @dev Reverts if `collateralTokenAddress` is not a supported collateral token.
     * @param collateralTokenAddress Address of a ERC20 collateral token.
     * @param user Address of the user.
     */
    function getCollateralDepositedByUser(address collateralTokenAddress, address user) external view isTokenAllowed(collateralTokenAddress) returns(uint256) {
        return s_collateralDeposited[user][collateralTokenAddress];
    }

    /**
     * @notice Returns the DSC tokens minted by the user (in 18 decimals).
     * @param user Address of the user.
     */
    function getDscMintedByUser(address user) external view returns(uint256) {
        return s_DscMintedByUser[user];
    }

    /**
     * @notice Returns the Total Decentralized Stable Coin tokens minted by the protocol.
     * @dev This value represents the aggregate DSC minted across all users.
     */
    function getTotalDscMinted() external view returns(uint256) {
        return s_totalDscMinted;
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Burns DSC tokens from the caller’s balance.
     *
     * @dev
     * - Delegates burning logic to the internal `_burnDsc` function.
     * - Burns DSC on behalf of the caller.
     * - Enforces that the caller remains sufficiently collateralized.
     *
     * Reverts if:
     * - `amountDscToBurn` is zero.
     * - The underlying DSC transfer fails.
     * - The caller’s health factor falls below `MIN_HEALTH_FACTOR`.
     *
     * @param amountDscToBurn Amount of DSC tokens to burn (18 decimals).
     */
    function burnDsc(uint256 amountDscToBurn) public greaterThanZero(amountDscToBurn) {
        _burnDsc(msg.sender, msg.sender, amountDscToBurn);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Deposits collateral into the protocol
     * @dev
     *  1. Updates internal collateral accounting for the caller.
     *  2. Emits a {CollateralDeposited} event.
     *  3. Transfers collateral tokens from caller to this contract.
     *  4. Follows CEI (Checks, Effects, Interactions) pattern.
     * 
     * Reverts if:
     *  1. `collateralTokenAddress` is not an allowed collateral token.
     *  2. `collateralAmount` is zero.
     *  3. ERC20 `transferFrom` fails for collateral token.
     * 
     * @param collateralTokenAddress Address of the ERC20 token to be deposit as collateral
     * @param collateralAmount amount of collateral tokens to deposit (in token decimals)
     * 
     */
    function depositCollateral(
        address collateralTokenAddress,
        uint256 collateralAmount
    ) 
        public 
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
    
    /**
     * @notice Returns the DSC tokens minted & USD value of collateral deposited by the `user`.
     * @dev 
     *  1. DSC tokens are returned with 18 decimals.
     *  2. USD value of collateral is returned with 1e18 precision.
     * 
     * @param user address for which the account information is returned.
     * @return totalDscMinted Amount of Decentralized Stable Coin tokens minted by the user.
     * @return totalCollateralValue Totla Value of collateral deposited by `user` in USD.
     */
    function getAccountInfo(address user) public view returns(uint256 totalDscMinted, uint256 totalCollateralValue) {
        totalDscMinted = s_DscMintedByUser[user];
        totalCollateralValue = getAccountCollateralValueInUsd(user);
    }

    /**
     * @notice Returns the total collateral value in USD deposited by an `account`.
     * @dev
     *  1. Iterate over all supported collateral tokens.
     *  2. Utilises Chainlink Price Feeds to fetch current price of collateral tokens.
     *  3. Returns the total collateral value in USD with 1e18 precision.
     * @param account address for which the total collateral value is calculated and returned.
     * @return totalCollateralValue USD value for all collateral tokens deposited by the `account`.
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

    /**
     * @notice Returns the amount of collateral tokens equivalent to a given USD value.
     *
     * @dev
     * - Uses Chainlink price feeds to fetch the current USD price of the collateral token.
     * - Assumes `usdValueInWei` is provided with 1e18 precision.
     * - Returns the amount of collateral tokens in the token's native decimals.
     *
     * Reverts if:
     * - `collateralTokenAddress` is not a supported ERC20 collateral token.
     * - The price returned by the price feed is negative.
     *
     * @param collateralTokenAddress Address of the collateral token.
     * @param usdValueInWei USD value to convert, with 1e18 precision.
     * @return collateralAmount Amount of collateral tokens equivalent to the USD value.
     */
    function getAmountCollateralFromUsd(
        address collateralTokenAddress, 
        uint256 usdValueInWei
    ) 
        isTokenAllowed (collateralTokenAddress)
        public 
        view
    returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[collateralTokenAddress]);
        (, int price,,,) = priceFeed.latestRoundData();
        if (price < 0) {
            revert DSCEngine__InvalidCollateralPrice(price);
        }
        return (usdValueInWei * PRECISION) / (uint256(price) * (10 ** _getNormalisedDecimalsForTokenPrice(collateralTokenAddress)));
    }
    
    /**
     * @notice Mints DSC to the caller if collateralization requirements are met.
     * @dev 
     *  1. Increases the `s_totalDscMinted` by creating new tokens.
     *  2. Updates the count of `DSC` tokens minted by the caller.
     *  3. Calls the {DecentralizedStableCoin} contract to mint tokens to caller.
     * 
     * Reverts if:
     *  1. Caller's health factor falls below `MIN_HEALTH_FACTOR` while simulating DSC mint operation.
     *  2. {DecentralizedStableCoin} `mint` operation to mint tokens to caller fails.
     * 
     * @param amount Amount of DSC tokens to mint to the caller (18 decimals).
     *
     */
    function mintDsc(uint256 amount) public greaterThanZero(amount) {
        s_DscMintedByUser[msg.sender] += amount;
        s_totalDscMinted += amount;

        _revertIfHealthFactorIsBroken(msg.sender);

        emit DscMinted(msg.sender, amount);
        bool success = i_dsc.mint(msg.sender, amount);
        if(!success) {
            revert DSCEngine__DscMintFailed();
        }
    }

    /**
     * @notice Redeems collateral tokens from the protocol for the caller.
     *
     * @dev
     * - Delegates redemption logic to the internal `_redeemCollateral` function.
     * - Withdraws collateral on behalf of the caller.
     * - Enforces that the caller remains sufficiently collateralized.
     *
     * Reverts if:
     * - `collateralTokenAddress` is not the supported ERC20 collateral token.
     * - `collateralAmount` is zero.
     * - The caller attempts to redeem more collateral than deposited.
     * - Transfer {ERC20-transferFrom} call fails for the collateral token.
     * - The caller's health factor falls below `MIN_HEALTH_FACTOR` after redeeming the collateral tokens.
     *
     * @param collateralTokenAddress Address of the ERC20 token used as collateral
     * @param collateralAmount Amount of collateral tokens to redeem
     */
    function redeemCollateral(
        address collateralTokenAddress,
        uint256 collateralAmount
    ) 
        public 
        isTokenAllowed(collateralTokenAddress)
        greaterThanZero(collateralAmount) 
        nonReentrant
    {
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL & PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Burns DSC tokens on behalf of a user.
     *
     * - Caps the burn amount to the user’s total minted DSC.
     * - Decreases the `s_totalDscMinted` by destroying tokens.
     * - Updates user DSC tokens minted count.
     * - Transfers DSC tokens from `from` to this contract
     * - Calls the {DecentralisedStableCoin-burn} to burn the tokens
     * - Emits a {DscBurned} event
     *
     * Reverts if:
     * - The DSC transfer {DecentralizedStableCoin-transferFrom} call fails.
     *
     * @param onBehalfOf Address whose DSC debt is reduced.
     * @param from Address from which DSC tokens are transferred.
     * @param amountDscToBurn Amount of DSC tokens to burn (18 decimals).
     */
    function _burnDsc(address onBehalfOf, address from, uint256 amountDscToBurn) private {
        if (s_DscMintedByUser[onBehalfOf] < amountDscToBurn) {
            amountDscToBurn = s_DscMintedByUser[onBehalfOf];
        }
        s_totalDscMinted -= amountDscToBurn;
        s_DscMintedByUser[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(from, address(this), amountDscToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
        emit DscBurned(msg.sender, amountDscToBurn);

    }

    /**@notice Returns health factor for a user's account.
     * @dev 
     *  1. Assumes 1 DSC = 1 USD always.
     *  2. Applies liquidation threshold to the collateral value. 
     *  3. Returns a value with 1e18 precision. 
     * @param collateralValue Value in USD with 1e18 precision.
     * @param dscMinted Number of DSC minted against the collateral (18 decimals).
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
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (LIQUIDATION_THRESHOLD * collateralValue) / LIQUIDATION_PRECISION; 
        return (collateralAdjustedForThreshold * PRECISION) / dscMinted;
    }

    /**
     * @dev Calculates the USD value of a collateral token amount. 
     * Fetches latest price of collateral token using Chainlink Price Feeds
     * Normalizes token decimals and price feed decimals
     * Returns total value of the collateral tokens in USD with 1e18 precision.
     * @param token address of a collateral token
     * @param amount count of collateral tokens
     * @return amountInUsd USD value of the collateral deposited 
     */
    function _getCollateralValueInUsd(
        address token, 
        uint256 amount
    ) 
        internal 
        view 
        returns(uint256 amountInUsd) 
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeed[token]);
        (, int256 answer,,,) = priceFeed.latestRoundData();
        if (answer < 0) {
            revert DSCEngine__InvalidCollateralPrice(answer);
        }
        uint8 collateralTokenDecimals = _getCollateralTokenDecimals(token);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer) * (10 ** _getNormalisedDecimalsForTokenPrice(token));
        amountInUsd = (amount * price)/ ( 10 ** collateralTokenDecimals);
        return amountInUsd;
    }

    /**
     * @dev Returns the decimals for a supported collateral ERC20 token.
     * @param token address of a ERC20 token.
     */
    function _getCollateralTokenDecimals(address token) internal view returns(uint8) {
        return ERC20(token).decimals();
    }

    function _getNormalisedDecimalsForTokenPrice(address token) private view returns(uint8) {
        return _getCollateralTokenDecimals(token) - AggregatorV3Interface(s_priceFeed[token]).decimals();
    }

    /**
     * @dev Returns the health factor with 1e18 precision.
     * Utilises `_calculateHealthFactor` to calculate the health factor.
     * @param account Address to calculate health factor for.
     */
    function _healthFactor(address account) internal view returns (uint256) {
        (uint256 dscMinted, uint256 collateralValue) = getAccountInfo(account);
        return _calculateHealthFactor(collateralValue, dscMinted);
    }

    /**
     * @dev Redeems collateral tokens from protocol deposited by address `from` to address `to`.
     * - emits {CollateralRedeemed} event.
     * Reverts if:
     * - The caller attempts to redeem more collateral than deposited by `from`.
     * - {ERC20-transfer} call to move tokens to `to` address fails.
     * 
     * @param collateralTokenAddress Address of a ERC20 collateral token.
     * @param collateralAmount Count of collateral tokens to redeem.
     * @param from Address from which collateral is to be redeemed.
     * @param to Address to which collateral to be transferred.
     */
    function _redeemCollateral(address collateralTokenAddress, uint256 collateralAmount, address from, address to) private {
        if (collateralAmount > s_collateralDeposited[from][collateralTokenAddress]) {
            revert DSCEngine__RedeemMoreCollateralThanDeposited(collateralTokenAddress, s_collateralDeposited[from][collateralTokenAddress], collateralAmount);
        }

        s_collateralDeposited[from][collateralTokenAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);
        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);

        if (!success) {
            revert DSCEngine__CollateralRedeemFailed(to, collateralTokenAddress);
        }
    }

    /**
     * @dev Reverts if an `account`'s health factor is less than MIN_HEALTH_FACTOR.
     * Uses current collateral value in USD and the DSC tokens minted against the collateral.
     * Reverts with {DSCEngine__BreaksHealthFactor} if undercollateralized.
     * @param account Address to check health factor for.
     */
    function _revertIfHealthFactorIsBroken(address account) internal view {
        if (_healthFactor(account) < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }


}