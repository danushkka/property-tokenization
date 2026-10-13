// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PropertyIssuance} from "../src/PropertyIssuance.sol";
import {WhitelistValidator} from "../src/WhitelistValidator.sol";
import {PropertyToken} from "../src/PropertyToken.sol";

contract PropertyIssuanceTest is Test {
    /////////////////////////////////////
    ////////// STATE VARIABLES //////////
    /////////////////////////////////////

    ERC20Mock public stablecoin;
    PropertyIssuance public issuer;
    WhitelistValidator public validator;
    PropertyToken public token;

    address treasury = makeAddr("treasury");
    address admin = makeAddr("admin");
    address alice = makeAddr("alice");

    uint256 public constant INITIAL_PRICE = 10e6; // $10 in USDC
    uint256 public constant MAX_PURCHASE_PER_TX = 10_000e18; // 10_000 tokens
    uint256 public constant AMOUNT_TO_MINT = 100 ether;

    /////////////////////////////////////
    ///////////// MODIFIERS /////////////
    /////////////////////////////////////

    modifier whitelisted(address account) {
        vm.prank(admin);
        validator.addToWhitelist(account);
        _;
    }

    /////////////////////////////////////
    ////////////// HELPERS //////////////
    /////////////////////////////////////

    function getExpectedCostFromAmount(uint256 price, uint256 amount) private view returns (uint256 expectedCost) {
        expectedCost = Math.mulDiv(price, amount, issuer.TOKEN_PRECISION());
    }

    //////////////////////////////////////
    /////////////// SET UP ///////////////
    //////////////////////////////////////

    function setUp() public {
        stablecoin = new ERC20Mock();

        vm.startPrank(admin);
        validator = new WhitelistValidator(admin);
        token = new PropertyToken("Property Token", "PPT", admin, address(validator), 1_000_000e18);

        issuer = new PropertyIssuance(
            address(token), address(stablecoin), treasury, admin, INITIAL_PRICE, MAX_PURCHASE_PER_TX
        );

        // address[] memory proposers = new address[](1);
        // proposers[0] = admin;
        // address[] memory executors = new address[](1);
        // executors[0] = address(0); // anyone can execute once the delay passes

        // vm.prank(admin);
        // timelock = new TimelockController(72 hours, proposers, executors, admin);

        token.grantRole(token.ISSUER_ROLE(), address(issuer));
        token.revokeRole(token.ISSUER_ROLE(), admin);

        // token.grantRole(token.DEFAULT_ADMIN_ROLE(), address(timelock));
        // token.revokeRole(token.DEFAULT_ADMIN_ROLE(), admin);

        // issuer.grantRole(issuer.DEFAULT_ADMIN_ROLE(), address(timelock));
        // issuer.revokeRole(issuer.DEFAULT_ADMIN_ROLE(), admin);

        vm.stopPrank();
    }

    //////////////////////////////////////
    //////////// CONSTRUCTOR /////////////
    //////////////////////////////////////

    function test_Constructor_GrantsRoles() public view {
        assertTrue(issuer.hasRole(issuer.PRICE_ORACLE_ROLE(), admin));
    }

    function test_Constructor_HoldsIssuerRoleOnToken() public view {
        assertTrue(token.hasRole(token.ISSUER_ROLE(), address(issuer)));
    }

    function test_Constructor_RevertWhen_ZeroAddress() public {
        address newToken = makeAddr("newToken");
        address newStablecoin = makeAddr("newStablecoin");
        address newTreasury = makeAddr("newTreasury");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroAddress.selector));
        new PropertyIssuance(address(0), newStablecoin, newTreasury, admin, INITIAL_PRICE, MAX_PURCHASE_PER_TX);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroAddress.selector));
        new PropertyIssuance(newToken, address(0), newTreasury, admin, INITIAL_PRICE, MAX_PURCHASE_PER_TX);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroAddress.selector));
        new PropertyIssuance(newToken, newStablecoin, address(0), admin, INITIAL_PRICE, MAX_PURCHASE_PER_TX);
    }

    function test_Constructor_RevertWhen_ZeroAmount() public {
        address newToken = makeAddr("newToken");
        address newStablecoin = makeAddr("newStablecoin");
        address newTreasury = makeAddr("newTreasury");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroAmount.selector));
        new PropertyIssuance(newToken, newStablecoin, newTreasury, admin, 0, MAX_PURCHASE_PER_TX);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroAmount.selector));
        new PropertyIssuance(newToken, newStablecoin, newTreasury, admin, INITIAL_PRICE, 0);
    }

    //////////////////////////////////////
    ////////////// PURCHASE //////////////
    //////////////////////////////////////

    function test_Purchase_MintsPurchasedTokens(uint256 amount) public whitelisted(alice) {
        uint256 minPurchaseAmount = issuer.getMinPurchaseAmount();
        amount = bound(amount, minPurchaseAmount, MAX_PURCHASE_PER_TX);
        uint256 expectedCost = getExpectedCostFromAmount(INITIAL_PRICE, amount); // `alice`'s balance should cover the cost of tokens

        vm.startPrank(alice);
        stablecoin.mint(alice, expectedCost);
        stablecoin.approve(address(issuer), expectedCost);
        vm.stopPrank();

        vm.prank(alice);
        issuer.purchase(amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(stablecoin.balanceOf(alice), 0);
    }

    function test_Purchase_EmitsExpectedEvent(uint256 amount) public whitelisted(alice) {
        uint256 minPurchaseAmount = issuer.getMinPurchaseAmount();
        amount = bound(amount, minPurchaseAmount, MAX_PURCHASE_PER_TX);
        uint256 expectedCost = getExpectedCostFromAmount(INITIAL_PRICE, amount);

        vm.startPrank(alice);
        stablecoin.mint(alice, expectedCost);
        stablecoin.approve(address(issuer), expectedCost);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(issuer));
        emit PropertyIssuance.Purchased(alice, amount, expectedCost);
        issuer.purchase(amount);
    }

    function test_Purchase_RevertWhen_ZeroAmount() public whitelisted(alice) {
        vm.startPrank(alice);
        stablecoin.mint(alice, AMOUNT_TO_MINT);
        stablecoin.approve(address(issuer), AMOUNT_TO_MINT);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroAmount.selector));
        issuer.purchase(0);
    }

    function test_Purchase_RevertWhen_ExceedsMaxPurchasePerTx(uint256 amount) public whitelisted(alice) {
        amount = bound(amount, MAX_PURCHASE_PER_TX + 1, type(uint128).max);
        uint256 expectedCost = getExpectedCostFromAmount(INITIAL_PRICE, amount);

        vm.startPrank(alice);
        stablecoin.mint(alice, expectedCost);
        stablecoin.approve(address(issuer), expectedCost);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyIssuance.PropertyIssuance__ExceedsMaxPurchasePerTx.selector, amount, MAX_PURCHASE_PER_TX
            )
        );
        issuer.purchase(amount);
    }

    function test_Purchase_RevertWhen_CostRoundsToZero(uint256 amount) public whitelisted(alice) {
        uint256 minPurchaseAmount = issuer.getMinPurchaseAmount();
        amount = bound(amount, 1, minPurchaseAmount - 1);
        uint256 expectedCost = getExpectedCostFromAmount(INITIAL_PRICE, amount);

        vm.startPrank(alice);
        stablecoin.mint(alice, expectedCost);
        stablecoin.approve(address(issuer), expectedCost);
        vm.stopPrank();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__CostRoundsToZero.selector));
        issuer.purchase(amount);
    }

    function test_Purchase_RevertWhen_CostRoundsToZero_AfterPriceDrop() public whitelisted(alice) {
        vm.startPrank(alice);
        stablecoin.mint(alice, AMOUNT_TO_MINT);
        stablecoin.approve(address(issuer), AMOUNT_TO_MINT);
        vm.stopPrank();

        // Intent to purchase `amount` for the previous price
        uint256 amount = issuer.getMinPurchaseAmount();

        // Drop the price to the lowest possible
        vm.prank(admin);
        issuer.forceUpdatePrice(1);

        // Attempt to purchase normal `amount` for very low price
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__CostRoundsToZero.selector));
        issuer.purchase(amount);
    }

    // SHOULD I SIMULATE A SITUATION WHEN THE PRICE IS ALMOST ZERO, SO THAT THE COST ROUNDS TO ZERO
    // NOT BECAUSE OF A SMALL AMOUNT, BUT BECAUSE THE PRICE WAS SPOILED??

    //////////////////////////////////////
    //////////// UPDATE PRICE ////////////
    //////////////////////////////////////

    function test_UpdatePrice_SetsNewPrice(uint256 newPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minAllowedPrice = oldPrice - allowedDeviation;
        uint256 maxAllowedPrice = oldPrice + allowedDeviation;

        newPrice = bound(newPrice, minAllowedPrice, maxAllowedPrice);

        vm.prank(admin);
        issuer.updatePrice(newPrice);
        assertEq(issuer.s_pricePerToken(), newPrice);
    }

    function test_UpdatePrice_EmitsExpectedEvent(uint256 newPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minAllowedPrice = oldPrice - allowedDeviation;
        uint256 maxAllowedPrice = oldPrice + allowedDeviation;

        newPrice = bound(newPrice, minAllowedPrice, maxAllowedPrice);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(issuer));
        emit PropertyIssuance.PriceUpdated(oldPrice, newPrice, false);
        issuer.updatePrice(newPrice);
    }

    function test_UpdatePrice_RevertWhen_ExceedsAllowedDeviation() public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minUnallowedDeviation = allowedDeviation + 1;

        uint256 tooHigh = oldPrice + minUnallowedDeviation;
        uint256 tooLow = oldPrice - minUnallowedDeviation;

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyIssuance.PropertyIssuance__PriceDeviationTooLarge.selector, tooHigh - oldPrice, allowedDeviation
            )
        );
        issuer.updatePrice(tooHigh);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                PropertyIssuance.PropertyIssuance__PriceDeviationTooLarge.selector, oldPrice - tooLow, allowedDeviation
            )
        );
        issuer.updatePrice(tooLow);
        vm.stopPrank();
    }

    function test_UpdatePrice_RevertWhen_NotByOracleRole(uint256 newPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minAllowedPrice = oldPrice - allowedDeviation;
        uint256 maxAllowedPrice = oldPrice + allowedDeviation;

        newPrice = bound(newPrice, minAllowedPrice, maxAllowedPrice);

        vm.prank(alice);
        vm.expectRevert();
        issuer.updatePrice(newPrice);
    }

    function test_UpdatePrice_RevertWhen_ZeroPrice() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroPrice.selector));
        issuer.updatePrice(0);
    }

    //////////////////////////////////////
    ///////// FORCE UPDATE PRICE /////////
    //////////////////////////////////////

    function test_ForceUpdatePrice_SetsNewLowPrice(uint256 newLowPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minAllowedPrice = oldPrice - allowedDeviation;

        newLowPrice = bound(newLowPrice, 1, minAllowedPrice - 1);

        vm.prank(admin);
        issuer.forceUpdatePrice(newLowPrice);
        assertEq(issuer.s_pricePerToken(), newLowPrice);
    }

    function test_ForceUpdatePrice_SetsNewHighPrice(uint256 newHighPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 maxAllowedPrice = oldPrice + allowedDeviation;

        newHighPrice = bound(newHighPrice, maxAllowedPrice + 1, type(uint128).max);

        vm.prank(admin);
        issuer.forceUpdatePrice(newHighPrice);
        assertEq(issuer.s_pricePerToken(), newHighPrice);
    }

    function test_ForceUpdatePrice_EmitsExpectedEvent_WhenLowPrice(uint256 newPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minAllowedPrice = oldPrice - allowedDeviation;

        uint256 newLowPrice = bound(newPrice, 1, minAllowedPrice - 1);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(issuer));
        emit PropertyIssuance.PriceUpdated(oldPrice, newLowPrice, true);
        issuer.forceUpdatePrice(newLowPrice);
    }

    function test_ForceUpdatePrice_EmitsExpectedEvent_WhenHighPrice(uint256 newPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 maxAllowedPrice = oldPrice + allowedDeviation;

        uint256 newHighPrice = bound(newPrice, maxAllowedPrice + 1, type(uint128).max);

        vm.prank(admin);
        vm.expectEmit(true, true, true, true, address(issuer));
        emit PropertyIssuance.PriceUpdated(oldPrice, newHighPrice, true);
        issuer.forceUpdatePrice(newHighPrice);
    }

    function test_ForceUpdatePrice_RevertWhen_NotByAdminRole(uint256 newPrice) public {
        uint256 oldPrice = issuer.s_pricePerToken();
        uint256 allowedDeviation = oldPrice * issuer.MAX_INSTANT_DEVIATION_BPS() / issuer.BPS_DENOMINATOR();
        uint256 minAllowedPrice = oldPrice - allowedDeviation;
        uint256 maxAllowedPrice = oldPrice + allowedDeviation;

        uint256 newLowPrice = bound(newPrice, 1, minAllowedPrice - 1);
        uint256 newHighPrice = bound(newPrice, maxAllowedPrice + 1, type(uint128).max);

        vm.prank(alice);
        vm.expectRevert();
        issuer.forceUpdatePrice(newLowPrice);

        vm.prank(alice);
        vm.expectRevert();
        issuer.forceUpdatePrice(newHighPrice);
    }

    function test_ForceUpdatePrice_RevertWhen_ZeroPrice() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(PropertyIssuance.PropertyIssuance__ZeroPrice.selector));
        issuer.forceUpdatePrice(0);
    }

    //////////////////////////////////////
    ////////////// GETTERS ///////////////
    //////////////////////////////////////

    function test_GetMinPurchaseAmount() public view {
        uint256 expectedAmount = Math.ceilDiv(issuer.TOKEN_PRECISION(), issuer.s_pricePerToken());
        assertEq(issuer.getMinPurchaseAmount(), expectedAmount);
    }
}
