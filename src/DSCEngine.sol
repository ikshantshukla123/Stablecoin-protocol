// SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {OracleLib} from "./libraries/OracleLib.sol";
/**
 * @title DSCEngine
 * @author Ikshant shukla
 * @notice
 * The system is designed to be as minimal as possible, and have maintain a 1token == $1 peg.
 * This stableCoin has the properties:
 * -Exogenous collateral
 *
 * -Dollar pegged
 * -Algoritmically Stable
 *
 *
 * It is similar to DAI if DAI had no governance, no fees,and was only backed by WETH and WBTC.
 *
 * @notice This contract is the core of the DSC system.It handles all the logic for minig and redeming DSC,as well as depositing & withdrwaing collateral
 *
 * @notice This contract is vERy lossely based on the MakerDAO DSS(DAI) system.
 *
 */

contract DSCEngine is ReentrancyGuard {
    //_______________________________________________________________________________________________________________________
    //errors
    error DSCEngine_NeedMoreTHanZero();
    error DSCEngine_TokenAddressesAndPriveFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TranferFailed();
    error DSCENGINE__BreakHealthFactor(uint256 _healthFactor);
    error DSC__NotMinted();
    error DSCEnigne__HealthFactorOk();
    error DSCEnigne__HealthFactorNotImproved();

    using OracleLib for AggregatorV3Interface;

    //_______________________________________________________________________________________________________________________
    //state variables

    uint256 private constant ADDITIONAL_FEED_PRECESION = 1e10;
    uint256 private constant PRECESION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;



    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    address[] private s_collateralTokens;

    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    DecentralizedStableCoin private immutable i_dsc;
    //_______________________________________________________________________________________________________________________
    //events

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    //_______________________________________________________________________________________________________________________
    //Modifiers

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_NeedMoreTHanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) { 
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }
    //_______________________________________________________________________________________________________________________

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        //USD Price Feeds
      if(tokenAddresses.length != priceFeedAddresses.length){
        revert DSCEngine_TokenAddressesAndPriveFeedAddressesMustBeSameLength();
      }

        // For example ETH/USD,BTC/USD,MKR/USD etc
        for(uint256 i=0;i<tokenAddresses.length;i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
            
        }

       
        i_dsc = DecentralizedStableCoin(dscAddress);
        //dscAddress is the deployed address of your DecentralizedStableCoin contract (your ERC20-based stablecoin).
    }
    //_______________________________________________________________________________________________________________________
    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint the amount of decentralized stablecoin to mint
     * @notice this function will deposit your collateral and mint DSC in one transaction
     */

    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    //_______________________________________________________________________________________________________________________
    /**
     * @notice follows Checks-Effects-Interaction pattern
     * @param tokenCollateralAddress The address of the token depost as collateral
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

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);

        if (!success) {
            revert DSCEngine__TranferFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    // $100 ETH -> $20 DSC
    //100 (break)
    //1. burn DSC
    //2. redeem ETH

    //_______________________________________________________________________________________________________________________

    /**
     *
     * @param tokenCollateralAddress the collateral address to redeem
     * @param amountCollateral  the amount to collateral to redeem
     * @param amountDscToBurn  the amount to DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);

        //redeemCollateral already checks helth factor
    }
    //_______________________________________________________________________________________
    // in order to redeem collateral:
    //1. health factor must be over 1 After collateral pulled
    //DRY: Don't repeat yourself
    //CEI: Check, Effects, Interactions

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //_______________________________________________________________________________________________________________________

    /**
     * @notice follows CEI
     * @param amountDscToMint The amopunt of the centralized stablecoin to mint
     * @notice they must have more collateral value than the minimum threshold
     */


    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much ($150 DSC, $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        
        if (!minted) {
            revert DSC__NotMinted();
        }
    }
    //_______________________________________________________________________________________________________________________

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //i dont think this line would ever hit...
    }
    //___________________________________________________________________________________________

    // $75 backing $50 DSC ;; liquidater take $75 backing and burns of the 50 dsc
    //if someoe is almost undercollateralized, we will pay you to liquidate them!

    /**
     *
     * @param collateral the erc20 collateral address to liquidate from the user
     * @param user the user who has broken the health factor thier. thier _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover the amount of DSC you want to burn to improve the users the health factor
     * @notice You can partially liquidate user
     * @notice you will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be 200% overcollatarized in order or this to work
     * @notice A known bug would be if the protocol were 100% of less collateralized,then we wouldnt be able to incentive the liquidaters
     * for example, if the prize of the collateral plumeted befor anyone could be liquidated
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEnigne__HealthFactorOk();
        }
        //We want to burn thier DSC"Debt"
        // And take thier collateral
        //Bad user: $140 EETH, $100 DSC
        //debtToCover = $100
        //$100 of DSC == ?? ETH?
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS / 100);
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        //We need to burn the DSC
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEnigne__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //________________________________________________________________________________________
    function getHealthFactor() external view {}

    //_______________________________________________________________________________________________________________________

    // private internal view funciton

    /**
     * @dev Low-level internal function,do not call unless the function calling it is checking for health facotrs being broken
     *
     */
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;

        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        // _calculateHealthFactorAfter();
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) {
            revert DSCEngine__TranferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TranferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * returns how close to liquidation a user is
     * if a user goes below 1,then they can get liquidated
     */

    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) {
            return type(uint256).max; // user has no debt, health factor is "infinite"
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * PRECESION / totalDscMinted);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (do they have enough collateral?)
        //2. Revert if they don't have a good health factor
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCENGINE__BreakHealthFactor(userHealthFactor);
        }
    }

    //_______________________________________________________________________________________________________________________

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        //loop thorugh each collateral token,get the amount they have deposited,and map it to the price,to get the USD value

        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //1 ETH = $1000
        //The returned value from Cl will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECESION) * amount) / PRECESION;
    }

    function getTokenAmountFromUsd(address token, uint256 useAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (useAmountInWei * PRECESION) / (uint256(price) * ADDITIONAL_FEED_PRECESION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralDeposited(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
