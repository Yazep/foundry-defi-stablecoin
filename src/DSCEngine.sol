// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import{OracleLib} from "./libraries/OracleLib.sol";
/** 
 * @title DSCEngine
 * @author Andrei Yazepchyk
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DCS system should always be "overcollateralized". At no point, shoul the value of all collateral <= the value of all the DSC.
 * 
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    //////////////////// 
    ////Errors //////
    ///////////////////
error DSCEngine_NeedsMOreThanZero();
error DSCEngine_TokenAdressesAndPriceFeedAddressesMustBeSameLength();
error DSCEngine_NotAllowedToken();
error DSCEngine_TransferFailed();
error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
error  DSCEngine_MintFailed();
error DSCEngine_HealthFactorOk();
error DSCEngine_HealthFactorNotImproved();
    //////////////////// 
    ////Type      //////
    ///////////////////
using OracleLib for AggregatorV3Interface;
   //////////////////// 
    ////State Variables //////
    ///////////////////
uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
uint256 private constant PRECISION = 1e18;
uint256 private constant LIQUIDATION_THRESHOLD = 50;
uint256 private constant LIQUIDATION_PRECISION = 100;
uint256 private constant MIN_HEALTH_FACTOR = 1e18;
uint256 private constant LIQUIDATION_BONUS=10;

mapping (address token =>address priceFeed) private s_priceFeeds; 
mapping (address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
mapping (address user => uint256 amountDscMinted)private s_DSCMinted;
address[] private s_collateralTokens;

DecentralizedStableCoin private immutable i_dsc;
//////////////////// 
    ////Events //////
    ///////////////////

event CollateralDeposited (address indexed user, address indexed token,  uint256 indexed amount);
event CollateralRedeemed (address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256  amount);

    //////////////////// 
    ////Modifiers //////
    /////////////////// 
    modifier moreThanZero (uint256 amount){
        if (amount ==0){
            revert DSCEngine_NeedsMOreThanZero();
        }
        _;
    }

    modifier isAllowedToken (address token) {
        if(s_priceFeeds[token]==address(0)){
            revert DSCEngine_NotAllowedToken();
        } _;
    }
    // modifier isAlllowedToken( address token){

    // }

     //////////////////// 
    ////Functions //////
    ///////////////////
    constructor (address [] memory tokenAddresses,
     address [] memory priceFeedAddresses,
     address dscAddress){
        //USD Price Feeds
        if (tokenAddresses.length !=priceFeedAddresses.length){
            revert DSCEngine_TokenAdressesAndPriceFeedAddressesMustBeSameLength(); 
        }
        for (uint256 i=0; i<tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]]=priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);

        } 
        i_dsc=DecentralizedStableCoin(dscAddress);
     }
 
    ///////////////////////////////
    //// External Functions //////
    //////////////////////////////

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositColleteralAndMintDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToMint) external {
             depositColleteral(tokenCollateralAddress, amountCollateral);
             mintDsc(amountDscToMint);
    }

    /**
     * @notice follows CEI
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositColleteral(address tokenCollateralAddress, uint256 amountCollateral) 
    public 
    moreThanZero(amountCollateral) 
    isAllowedToken(tokenCollateralAddress) 
    nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender,address(this),amountCollateral);
        if (!success){
            revert DSCEngine_TransferFailed();
        }

    }

    /**
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint)nonReentrant {
       s_DSCMinted[msg.sender] +=amountDscToMint;
       _revertIfHealthFactorIsBroken(msg.sender);
    bool minted =i_dsc.mint(msg.sender, amountDscToMint);
    if (!minted){
        revert DSCEngine_MintFailed();
    }
        
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */

    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        //redeem Collateral already check Healthfactor
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(msg.sender,msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    
    function burnDsc(uint256 amount) public moreThanZero(amount){
        _burnDsc(amount,msg.sender,msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }
    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 200% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint  debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor =_healthFactor(user);
        if (startingUserHealthFactor >=MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered =getTokenAmountFromUsd(collateral, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered*LIQUIDATION_BONUS)/LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedem= tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender,collateral,totalCollateralToRedem);
        _burnDsc(debtToCover,user,msg.sender);

        uint256 endingUserHealthFactor =_healthFactor(user);
        if(endingUserHealthFactor<= startingUserHealthFactor){
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
        }

    function getHealthFactor() external view {}
    ////////////////////////////////////// 
    //// Private Internal Functions //////
    //////////////////////////////////////

function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private{
    s_DSCMinted[onBehalfOf] -=amountDscToBurn;
        bool success =i_dsc.transferFrom(dscFrom,address(this),amountDscToBurn);
        if(!success){
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
}

function _redeemCollateral(address from , address to, address tokenCollateralAddress, uint256 amountCollateral) private{
        s_collateralDeposited[from][tokenCollateralAddress]-=amountCollateral;
        emit CollateralRedeemed(from,to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert DSCEngine_TransferFailed();
        }} 

function _getAccountInformation (address user)private view returns (uint256 totalDscMinted,uint256 collateralValueInUsd){
    totalDscMinted=s_DSCMinted[user];
    collateralValueInUsd=getAccountCollateralValue(user);
}

    function _healthFactor(address user)private view returns(uint256){
        //total DSC minted
        //total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd)=_getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =(collateralValueInUsd * LIQUIDATION_THRESHOLD)/LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold* PRECISION)/totalDscMinted;
        // (collateralValueInUsd/totalDscMinted);

    }

    function _revertIfHealthFactorIsBroken (address user) internal view{
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR){
            revert DSCEngine_BreaksHealthFactor(userHealthFactor);
        }
        //1. Check health factor
        //2.Revert if they don't

    }
    //////////////////////////////////////////// 
    ////Public & Ecxternal View Funcitons //////
    ///////////////////////////////////////////

    function getTokenAmountFromUsd (address token, uint256 usdAmountInWei) public view returns (uint256){
        AggregatorV3Interface pricefeed =AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,)= pricefeed.stalepriceCheck();
        return (usdAmountInWei*PRECISION)/(uint256(price)*ADDITIONAL_FEED_PRECISION);

    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd){
        for (uint256 i=0; i<s_collateralTokens.length; i++)
        {address token = s_collateralTokens[i];
        uint256 amount = s_collateralDeposited[user][token];
        totalCollateralValueInUsd += getUsdValue(token,amount);
        }
    return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256){
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token])    ;
        (,int256 price,,,) = priceFeed.stalepriceCheck();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount)/PRECISION; }



    function getAccountInformation(address user) external view returns (uint256 totalDscMinted, uint256 collateralValueInUsd) {
    (totalDscMinted,collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory){
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256){
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}

   