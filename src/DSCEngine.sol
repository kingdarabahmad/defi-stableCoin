//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Darab Ahmad khan
 * Here tokens maintain a 1 token == $1 pegged to the USD
 * This stablecoin has the properties
 * - Exogenous
 * - Dollar pegged
 * - Algorithmic
 *
 * it was backed by WETH and WBTC
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositing and withdrawing collateral
 */
contract DSCEngine is ReentrancyGuard {
    /////////////////
    // Errors      //
    /////////////////

    error DSCEngine_NeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_TokenNotAllowed();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    ///////////////////////////
    // State variables      //
    ///////////////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    mapping(address token => address priceFeed) private s_priceFeeds; //token to price feed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited; //user collateral deposited
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////////////
    // Events                //
    ///////////////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    // Modifiers  //
    ////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_NeedsMoreThanZero();
        }

        _;
    }

    modifier isAllowedToken(address tokenAddress) {
        if (s_priceFeeds[tokenAddress] == address(0)) {
            revert DSCEngine_TokenNotAllowed();
        }
        _;
    }

    /////////////////
    // Functions   //
    /////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedsAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedsAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedsAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    // External Functions   //
    ///////////////////////////

    /**
     * @notice deposits collateral and mints DSC
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param  amountDscToMint The amount of DSC to mint.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI (check, effect,interaction) pattern check in modifiers
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        // transfer collateral amount from user to this contract
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param  amountDscToBurn The amount of DSC to burn.
     * @notice this function burn DSC and redeem collateral in one transaction
     *
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // in order to redeem collateral
        // 1. health factor must be 1 AFTER collateral pulled
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI (check, effect,interaction) pattern check in modifiers
     * @param amountDscToMint The amount of DSC to mint
     * @notice They must have more collateral value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += amountDscToMint;
        // if they minted to much ($150 DSC, and only have $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // i dont think this would ever hit
    }

    // $100 eth backing  $50 DSC
    // $20 ETH back $50 DSC <-- DSC isn't worth $1!!

    /**
     *
     * @param collateral The erc20 collateral address to liquidate from user
     * @param user The user to liquidate, the user who has broken the health factor. their health factor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC you want to burn to improve users health factor.
     * @notice you can partially liquidate user
     * @notice you will get a liquidation bonus for taking the users funds
     * @notice this functon working assumes that the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A know bug would be if the protocol is 100% or less collateralized, then we wouldn't be able to incentivize the liquidaors
     * for example , if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        //need to check the health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        //we want to burn their DSC "debt"
        //And take their collateral
        //bad user: $140 ETH, $100 DSC
        // debtToCover: $100
        // $100 of DSC == ?? ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // and give them 10% bonus
        // we are givng the liquidator $110 WETH for 100DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        //we need to burn DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }

        //check health factor of the liquidator
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    ///////////////////////////////////////
    // Private and Internal Functions     //
    /////////////////////////////////////////
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _getAccountInformationUser(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice returns how close to liquidation a user is
     * if a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        //total DSC minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformationUser(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        //1. check health factor (do they have enough collateral)
        //2. revert if they dont
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(healthFactor);
        }
    }

    ////////////////////////////////////////////
    // Public and External view Functions     //
    ///////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        //price of token (ETH)
        //let say  $2000/ETH
        // how mauch eth for 1000$ --> 1000/2000 = 0.5ETH
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
        // e.g ($10e18 * 1e18)/($2000e8 * 1e10)
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        //eg 1 eth= $1000
        // the return value from cl will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // (1000 * 1e8 * (1e10)) * 1000 * 1e18;
    }
}
