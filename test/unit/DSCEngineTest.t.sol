// SPDX-License-Identifier:MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";

import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;

    address btcUsdPriceFeed;
    address weth;
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();


        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    //Constructor tests ::
    address[] public tokenAddresses;
    address[] public priceFeedsAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedsAddresses.push(ethUsdPriceFeed);
        priceFeedsAddresses.push(btcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriveFeedAddressesMustBeSameLength.selector);

        new DSCEngine(tokenAddresses, priceFeedsAddresses, address(dsc));
    }

    //PRICE TESTS::

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000/Eth  ,100eth
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        //15e18 *2000/ETH = 30000e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    // DepositCollateral Tests ::

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreTHanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertIfAllowedToken() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testMintDscSuccess() public {
        uint256 mintAmount = 50e18;
        vm.startPrank(USER);
        // Step 2: Approve & deposit collateral
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        dsce.mintDsc(mintAmount);

        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, mintAmount, "DSC balance should equal minted amount");

        // Step 5: Also check account info
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, mintAmount, "DSCEngine should record minted DSC");
    }

    function testRevertIfMintZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_NeedMoreTHanZero.selector);
        dsce.mintDsc(0); // we have to test this
        vm.stopPrank();
    }

    function testCanDepositCollateralAccountInfo() public depositCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        // 2. No DSC minted yet
        uint256 expectedTotalDscMinted = 0;
        assertEq(totalDscMinted, expectedTotalDscMinted);

        // 3. Check the actual deposited collateral amount in tokens (not USD reconversion)
        uint256 depositedCollateral = dsce.getCollateralDeposited(USER, weth);
        assertEq(depositedCollateral, AMOUNT_COLLATERAL);

        // 4. Also check that collateralValueInUsd matches priceFeed value
        uint256 ethUsdPrice = 2000e8; // assuming you mocked ETH price as $2000 with 8 decimals
        uint256 expectedCollateralValueInUsd = (ethUsdPrice * 1e10 * AMOUNT_COLLATERAL) / 1e18;

        assertEq(collateralValueInUsd, expectedCollateralValueInUsd);
    }

    //Test for DecentralizedStableCoin::

    function testIfAmountIsZeroRevert() public {
        uint256 mintAmount = 100e18;
        console.log("Owner is: ", dsc.owner());

        address owner = dsc.owner();
        vm.startPrank(owner);
        dsc.mint(owner, mintAmount);

        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }




    function testBurnDsc() public {
        uint256 mintAmount = 10e18;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDsc(mintAmount);
        assertEq(dsc.balanceOf(USER), mintAmount, "mint failed");
        dsc.approve(address(dsce), mintAmount);
        dsce.burnDsc(mintAmount);
        assertEq(dsc.balanceOf(USER), 0, "Burn failed");

        vm.stopPrank();
    }





    function testRevertIfAmountIsGreaterThenBalance() public {
        uint256 mintAmount = 50e18;

        address owner = dsc.owner();
        vm.startPrank(owner);

        dsc.mint(owner, mintAmount);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(100e18);
        vm.stopPrank();
    }





   function testLiquidatehealthyUserReverts() public {
    uint256 mintAmount = 5e18;

    // USER setup
    vm.startPrank(USER);
    ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL); // fix: approve engine, not address(this)
    dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
    dsce.mintDsc(mintAmount);
      dsc.transfer(LIQUIDATOR, 3e18);
    vm.stopPrank();

    // LIQUIDATOR setup: needs DSC + approval
    vm.startPrank(LIQUIDATOR);
    // give LIQUIDATOR some DSC tokens
    dsc.approve(address(dsce), 10e18); // approve DSCEngine to use DSC 

    // Expect revert because USER is healthy
    vm.expectRevert(DSCEngine.DSCEnigne__HealthFactorOk.selector);
    dsce.liquidate(address(weth), USER, 3e18);
    vm.stopPrank();
}






    function testBurnIsWorking() public {
        uint256 mintAmount = 50e18;
        address owner = dsc.owner();

        vm.startPrank(owner);
        dsc.mint(owner, mintAmount);
        dsc.burn(40e18);
        assertEq(dsc.balanceOf(owner), 10e18);

        vm.stopPrank();
    }
}
