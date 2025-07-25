// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "../utils/Precision.sol";

import "./Position.sol";

import "../data/DataStore.sol";
import "../data/Keys.sol";

import "../pricing/PositionPricingUtils.sol";
import "../order/BaseOrderUtils.sol";

// @title PositionUtils
// @dev Library for position functions
library PositionUtils {
    using SafeCast for uint256;
    using SafeCast for int256;
    using Price for Price.Props;
    using Position for Position.Props;
    using Order for Order.Props;

    // @dev UpdatePositionParams struct used in increasePosition and decreasePosition
    // to avoid stack too deep errors
    //
    // @param contracts BaseOrderUtils.ExecuteOrderParamsContracts
    // @param market the values of the trading market
    // @param order the decrease position order
    // @param orderKey the key of the order
    // @param position the order's position
    // @param positionKey the key of the order's position
    struct UpdatePositionParams {
        BaseOrderUtils.ExecuteOrderParamsContracts contracts;
        Market.Props market;
        Order.Props order;
        bytes32 orderKey;
        Position.Props position;
        bytes32 positionKey;
        Order.SecondaryOrderType secondaryOrderType;
    }

    // @param dataStore DataStore
    // @param eventEmitter EventEmitter
    // @param oracle Oracle
    struct UpdatePositionParamsContracts {
        DataStore dataStore;
        EventEmitter eventEmitter;
        Oracle oracle;
        SwapHandler swapHandler;
    }

    struct WillPositionCollateralBeSufficientValues {
        uint256 positionSizeInUsd;
        uint256 positionCollateralAmount;
        int256 realizedPnlUsd;
        int256 openInterestDelta;
    }

    struct DecreasePositionCollateralValuesOutput {
        address outputToken;
        uint256 outputAmount;
        address secondaryOutputToken;
        uint256 secondaryOutputAmount;
    }

    // @dev ProcessCollateralValues struct used to contain the values in processCollateral
    // @param executionPrice the order execution price
    // @param remainingCollateralAmount the remaining collateral amount of the position
    // @param positionPnlUsd the pnl of the position in USD
    // @param sizeDeltaInTokens the change in position size in tokens
    // @param priceImpactAmount the price impact in tokens
    // @param priceImpactDiffUsd the price impact difference in USD
    // @param pendingCollateralDeduction the pending collateral deduction
    // @param output DecreasePositionCollateralValuesOutput
    struct DecreasePositionCollateralValues {
        uint256 executionPrice;
        uint256 remainingCollateralAmount;
        int256 basePnlUsd;
        int256 uncappedBasePnlUsd;
        uint256 sizeDeltaInTokens;
        int256 priceImpactUsd;
        uint256 priceImpactDiffUsd;
        DecreasePositionCollateralValuesOutput output;
    }

    // @dev DecreasePositionCache struct used in decreasePosition to
    // avoid stack too deep errors
    // @param prices the prices of the tokens in the market
    // @param pnlToken the token that the pnl for the user is in, for long positions
    // this is the market.longToken, for short positions this is the market.shortToken
    // @param pnlTokenPrice the price of the pnlToken
    // @param initialCollateralAmount the initial collateral amount
    // @param nextPositionSizeInUsd the new position size in USD
    // @param nextPositionBorrowingFactor the new position borrowing factor
    struct DecreasePositionCache {
        MarketUtils.MarketPrices prices;
        int256 estimatedPositionPnlUsd;
        int256 estimatedRealizedPnlUsd;
        int256 estimatedRemainingPnlUsd;
        address pnlToken;
        Price.Props pnlTokenPrice;
        Price.Props collateralTokenPrice;
        uint256 initialCollateralAmount;
        uint256 nextPositionSizeInUsd;
        uint256 nextPositionBorrowingFactor;
    }


    struct GetPositionPnlUsdCache {
        int256 positionValue;
        int256 totalPositionPnl;
        int256 uncappedTotalPositionPnl;
        address pnlToken;
        uint256 poolTokenAmount;
        uint256 poolTokenPrice;
        uint256 poolTokenUsd;
        int256 poolPnl;
        int256 cappedPoolPnl;
        uint256 sizeDeltaInTokens;
        int256 positionPnlUsd;
        int256 uncappedPositionPnlUsd;
    }

    struct IsPositionLiquidatableInfo {
        int256 remainingCollateralUsd;
        int256 minCollateralUsd;
        int256 minCollateralUsdForLeverage;
    }

    // @dev IsPositionLiquidatableCache struct used in isPositionLiquidatable
    // to avoid stack too deep errors
    // @param positionPnlUsd the position's pnl in USD
    // @param minCollateralFactor the min collateral factor
    // @param collateralTokenPrice the collateral token price
    // @param collateralUsd the position's collateral in USD
    // @param usdDeltaForPriceImpact the usdDelta value for the price impact calculation
    // @param priceImpactUsd the price impact of closing the position in USD
    struct IsPositionLiquidatableCache {
        int256 positionPnlUsd;
        uint256 minCollateralFactor;
        Price.Props collateralTokenPrice;
        uint256 collateralUsd;
        int256 usdDeltaForPriceImpact;
        int256 priceImpactUsd;
        bool hasPositiveImpact;
    }

    struct GetExecutionPriceForDecreaseCache {
        int256 priceImpactUsd;
        uint256 priceImpactDiffUsd;
        uint256 executionPrice;
    }

    // @dev get the position pnl in USD
    //
    // for long positions, pnl is calculated as:
    // (position.sizeInTokens * indexTokenPrice) - position.sizeInUsd
    // if position.sizeInTokens is larger for long positions, the position will have
    // larger profits and smaller losses for the same changes in token price
    //
    // for short positions, pnl is calculated as:
    // position.sizeInUsd -  (position.sizeInTokens * indexTokenPrice)
    // if position.sizeInTokens is smaller for long positions, the position will have
    // larger profits and smaller losses for the same changes in token price
    //
    // @param position the position values
    // @param sizeDeltaUsd the change in position size
    // @param indexTokenPrice the price of the index token
    //
    // @return (positionPnlUsd, uncappedPositionPnlUsd, sizeDeltaInTokens)
    function getPositionPnlUsd(
        DataStore dataStore,
        Market.Props memory market,
        MarketUtils.MarketPrices memory prices,
        Position.Props memory position,
        uint256 sizeDeltaUsd
    ) public view returns (int256, int256, uint256) {
        GetPositionPnlUsdCache memory cache;

        uint256 executionPrice = prices.indexTokenPrice.pickPriceForPnl(position.isLong(), false);

        // position.sizeInUsd is the cost of the tokens, positionValue is the current worth of the tokens
        cache.positionValue = (position.sizeInTokens() * executionPrice).toInt256();
        cache.totalPositionPnl = position.isLong() ? cache.positionValue - position.sizeInUsd().toInt256() : position.sizeInUsd().toInt256() - cache.positionValue;
        cache.uncappedTotalPositionPnl = cache.totalPositionPnl;

        if (cache.totalPositionPnl > 0) {
            cache.pnlToken = position.isLong() ? market.longToken : market.shortToken;
            cache.poolTokenAmount = MarketUtils.getPoolAmount(dataStore, market, cache.pnlToken);
            cache.poolTokenPrice = position.isLong() ? prices.longTokenPrice.min : prices.shortTokenPrice.min;
            cache.poolTokenUsd = cache.poolTokenAmount * cache.poolTokenPrice;
            cache.poolPnl = MarketUtils.getPnl(
                dataStore,
                market,
                prices.indexTokenPrice,
                position.isLong(),
                true
            );

            cache.cappedPoolPnl = MarketUtils.getCappedPnl(
                dataStore,
                market.marketToken,
                position.isLong(),
                cache.poolPnl,
                cache.poolTokenUsd,
                Keys.MAX_PNL_FACTOR_FOR_TRADERS
            );

            if (cache.cappedPoolPnl != cache.poolPnl && cache.cappedPoolPnl > 0 && cache.poolPnl > 0) {
                cache.totalPositionPnl = Precision.mulDiv(cache.totalPositionPnl.toUint256(), cache.cappedPoolPnl, cache.poolPnl.toUint256());
            }
        }

        if (position.sizeInUsd() == sizeDeltaUsd) {
            cache.sizeDeltaInTokens = position.sizeInTokens();
        } else {
            if (position.isLong()) {
                cache.sizeDeltaInTokens = Calc.roundUpDivision(position.sizeInTokens() * sizeDeltaUsd, position.sizeInUsd());
            } else {
                cache.sizeDeltaInTokens = position.sizeInTokens() * sizeDeltaUsd / position.sizeInUsd();
            }
        }

        cache.positionPnlUsd = Precision.mulDiv(cache.totalPositionPnl, cache.sizeDeltaInTokens, position.sizeInTokens());
        cache.uncappedPositionPnlUsd = Precision.mulDiv(cache.uncappedTotalPositionPnl, cache.sizeDeltaInTokens, position.sizeInTokens());

        return (cache.positionPnlUsd, cache.uncappedPositionPnlUsd, cache.sizeDeltaInTokens);
    }

    // @dev get the key for a position
    // @param account the position's account
    // @param market the position's market
    // @param collateralToken the position's collateralToken
    // @param isLong whether the position is long or short
    // @return the position key
    function getPositionKey(address account, address market, address collateralToken, bool isLong) internal pure returns (bytes32) {
        bytes32 key = keccak256(abi.encode(account, market, collateralToken, isLong));
        return key;
    }

    // @dev validate that a position is not empty
    // @param position the position values
    function validateNonEmptyPosition(Position.Props memory position) internal pure {
        if (position.sizeInUsd() == 0 && position.sizeInTokens() == 0 && position.collateralAmount() == 0) {
            revert Errors.EmptyPosition();
        }
    }

    // @dev check if a position is valid
    // @param dataStore DataStore
    // @param position the position values
    // @param market the market values
    // @param prices the prices of the tokens in the market
    // @param shouldValidateMinCollateralUsd whether min collateral usd needs to be validated
    // validation is skipped for decrease position to prevent reverts in case the order size
    // is just slightly smaller than the position size
    // in decrease position, the remaining collateral is estimated at the start, and the order
    // size is updated to match the position size if the remaining collateral will be less than
    // the min collateral usd
    // since this is an estimate, there may be edge cases where there is a small remaining position size
    // and small amount of collateral remaining
    // validation is skipped for this case as it is preferred for the order to be executed
    // since the small amount of collateral remaining only impacts the potential payment of liquidation
    // keepers
    function validatePosition(
        DataStore dataStore,
        Position.Props memory position,
        Market.Props memory market,
        MarketUtils.MarketPrices memory prices,
        bool shouldValidateMinPositionSize,
        bool shouldValidateMinCollateralUsd
    ) public view {
        if (position.sizeInUsd() == 0 || position.sizeInTokens() == 0) {
            revert Errors.InvalidPositionSizeValues(position.sizeInUsd(), position.sizeInTokens());
        }

        MarketUtils.validateEnabledMarket(dataStore, market.marketToken);
        MarketUtils.validateMarketCollateralToken(market, position.collateralToken());

        if (shouldValidateMinPositionSize) {
            uint256 minPositionSizeUsd = dataStore.getUint(Keys.MIN_POSITION_SIZE_USD);
            if (position.sizeInUsd() < minPositionSizeUsd) {
                revert Errors.MinPositionSize(position.sizeInUsd(), minPositionSizeUsd);
            }
        }

        (bool isLiquidatable, string memory reason, IsPositionLiquidatableInfo memory info) = isPositionLiquidatable(
            dataStore,
            position,
            market,
            prices,
            shouldValidateMinCollateralUsd
        );

        if (isLiquidatable) {
            revert Errors.LiquidatablePosition(
                reason,
                info.remainingCollateralUsd,
                info.minCollateralUsd,
                info.minCollateralUsdForLeverage
            );
        }
    }

    // @dev check if a position is liquidatable
    // @param dataStore DataStore
    // @param position the position values
    // @param market the market values
    // @param prices the prices of the tokens in the market
    function isPositionLiquidatable(
        DataStore dataStore,
        Position.Props memory position,
        Market.Props memory market,
        MarketUtils.MarketPrices memory prices,
        bool shouldValidateMinCollateralUsd
    ) public view returns (bool, string memory, IsPositionLiquidatableInfo memory) {
        IsPositionLiquidatableCache memory cache;
        IsPositionLiquidatableInfo memory info;

        (cache.positionPnlUsd, /* int256 uncappedBasePnlUsd */,  /* uint256 sizeDeltaInTokens */) = getPositionPnlUsd(
            dataStore,
            market,
            prices,
            position,
            position.sizeInUsd()
        );

        cache.collateralTokenPrice = MarketUtils.getCachedTokenPrice(
            position.collateralToken(),
            market,
            prices
        );

        cache.collateralUsd = position.collateralAmount() * cache.collateralTokenPrice.min;

        // calculate the usdDeltaForPriceImpact for fully closing the position
        cache.usdDeltaForPriceImpact = -position.sizeInUsd().toInt256();

        cache.priceImpactUsd = PositionPricingUtils.getPriceImpactUsd(
            PositionPricingUtils.GetPriceImpactUsdParams(
                dataStore,
                market,
                cache.usdDeltaForPriceImpact,
                position.isLong()
            )
        );

        cache.hasPositiveImpact = cache.priceImpactUsd > 0;

        // even if there is a large positive price impact, positions that would be liquidated
        // if the positive price impact is reduced should not be allowed to be created
        // as they would be easily liquidated if the price impact changes
        // cap the priceImpactUsd to zero to prevent these positions from being created
        if (cache.priceImpactUsd >= 0) {
            cache.priceImpactUsd = 0;
        } else {
            uint256 maxPriceImpactFactor = MarketUtils.getMaxPositionImpactFactorForLiquidations(
                dataStore,
                market.marketToken
            );

            // if there is a large build up of open interest and a sudden large price movement
            // it may result in a large imbalance between longs and shorts
            // this could result in very large price impact temporarily
            // cap the max negative price impact to prevent cascading liquidations
            int256 maxNegativePriceImpactUsd = -Precision.applyFactor(position.sizeInUsd(), maxPriceImpactFactor).toInt256();
            if (cache.priceImpactUsd < maxNegativePriceImpactUsd) {
                cache.priceImpactUsd = maxNegativePriceImpactUsd;
            }
        }

        PositionPricingUtils.GetPositionFeesParams memory getPositionFeesParams = PositionPricingUtils.GetPositionFeesParams(
            dataStore, // dataStore
            position, // position
            cache.collateralTokenPrice, //collateralTokenPrice
            cache.hasPositiveImpact, // forPositiveImpact
            market.longToken, // longToken
            market.shortToken, // shortToken
            position.sizeInUsd(), // sizeDeltaUsd
            address(0) // uiFeeReceiver
        );

        PositionPricingUtils.PositionFees memory fees = PositionPricingUtils.getPositionFees(getPositionFeesParams);

        // the totalCostAmount is in tokens, use collateralTokenPrice.min to calculate the cost in USD
        // since in PositionPricingUtils.getPositionFees the totalCostAmount in tokens was calculated
        // using collateralTokenPrice.min
        uint256 collateralCostUsd = fees.totalCostAmount * cache.collateralTokenPrice.min;

        // the position's pnl is counted as collateral for the liquidation check
        // as a position in profit should not be liquidated if the pnl is sufficient
        // to cover the position's fees
        info.remainingCollateralUsd =
            cache.collateralUsd.toInt256()
            + cache.positionPnlUsd
            + cache.priceImpactUsd
            - collateralCostUsd.toInt256();

        cache.minCollateralFactor = MarketUtils.getMinCollateralFactor(dataStore, market.marketToken);

        // validate if (remaining collateral) / position.size is less than the min collateral factor (max leverage exceeded)
        // this validation includes the position fee to be paid when closing the position
        // i.e. if the position does not have sufficient collateral after closing fees it is considered a liquidatable position
        info.minCollateralUsdForLeverage = Precision.applyFactor(position.sizeInUsd(), cache.minCollateralFactor).toInt256();

        if (shouldValidateMinCollateralUsd) {
            info.minCollateralUsd = dataStore.getUint(Keys.MIN_COLLATERAL_USD).toInt256();
            if (info.remainingCollateralUsd < info.minCollateralUsd) {
                return (true, "min collateral", info);
            }
        }

        if (info.remainingCollateralUsd <= 0) {
            return (true, "< 0", info);
        }

        if (info.remainingCollateralUsd < info.minCollateralUsdForLeverage) {
            return (true, "min collateral for leverage", info);
        }

        return (false, "", info);
    }

    // fees and price impact are not included for the willPositionCollateralBeSufficient validation
    // this is because this validation is meant to guard against a specific scenario of price impact
    // gaming
    //
    // price impact could be gamed by opening high leverage positions, if the price impact
    // that should be charged is higher than the amount of collateral in the position
    // then a user could pay less price impact than what is required, and there is a risk that
    // price manipulation could be profitable if the price impact cost is less than it should be
    //
    // this check should be sufficient even without factoring in fees as fees should have a minimal impact
    // it may be possible that funding or borrowing fees are accumulated and need to be deducted which could
    // lead to a user paying less price impact than they should, however gaming of this form should be difficult
    // since the funding and borrowing fees would still add up for the user's cost
    //
    // another possibility would be if a user opens a large amount of both long and short positions, and
    // funding fees are paid from one side to the other, but since most of the open interest is owned by the
    // user the user earns most of the paid cost, in this scenario the borrowing fees should still be significant
    // since some time would be required for the funding fees to accumulate
    //
    // fees and price impact are validated in the validatePosition check
    function willPositionCollateralBeSufficient(
        DataStore dataStore,
        Market.Props memory market,
        MarketUtils.MarketPrices memory prices,
        address collateralToken,
        bool isLong,
        WillPositionCollateralBeSufficientValues memory values
    ) public view returns (bool, int256) {
        Price.Props memory collateralTokenPrice = MarketUtils.getCachedTokenPrice(
            collateralToken,
            market,
            prices
        );

        int256 remainingCollateralUsd = values.positionCollateralAmount.toInt256() * collateralTokenPrice.min.toInt256();

        // deduct realized pnl if it is negative since this would be paid from
        // the position's collateral
        if (values.realizedPnlUsd < 0) {
            remainingCollateralUsd = remainingCollateralUsd + values.realizedPnlUsd;
        }

        if (remainingCollateralUsd < 0) {
            return (false, remainingCollateralUsd);
        }

        // the min collateral factor will increase as the open interest for a market increases
        // this may lead to previously created limit increase orders not being executable
        //
        // the position's pnl is not factored into the remainingCollateralUsd value, since
        // factoring in a positive pnl may allow the user to manipulate price and bypass this check
        // it may be useful to factor in a negative pnl for this check, this can be added if required
        uint256 minCollateralFactor = MarketUtils.getMinCollateralFactorForOpenInterest(
            dataStore,
            market,
            values.openInterestDelta,
            isLong
        );

        uint256 minCollateralFactorForMarket = MarketUtils.getMinCollateralFactor(dataStore, market.marketToken);
        // use the minCollateralFactor for the market if it is larger
        if (minCollateralFactorForMarket > minCollateralFactor) {
            minCollateralFactor = minCollateralFactorForMarket;
        }

        int256 minCollateralUsdForLeverage = Precision.applyFactor(values.positionSizeInUsd, minCollateralFactor).toInt256();
        bool willBeSufficient = remainingCollateralUsd >= minCollateralUsdForLeverage;

        return (willBeSufficient, remainingCollateralUsd);
    }

    function updateFundingAndBorrowingState(
        PositionUtils.UpdatePositionParams memory params,
        MarketUtils.MarketPrices memory prices
    ) internal {
        // update the funding amount per size for the market
        MarketUtils.updateFundingState(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market,
            prices
        );

        // update the cumulative borrowing factor for longs
        MarketUtils.updateCumulativeBorrowingFactor(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market,
            prices,
            true // isLong
        );

        // update the cumulative borrowing factor for shorts
        MarketUtils.updateCumulativeBorrowingFactor(
            params.contracts.dataStore,
            params.contracts.eventEmitter,
            params.market,
            prices,
            false // isLong
        );
    }

    function updateTotalBorrowing(
        PositionUtils.UpdatePositionParams memory params,
        uint256 nextPositionSizeInUsd,
        uint256 nextPositionBorrowingFactor
    ) internal {
        MarketUtils.updateTotalBorrowing(
            params.contracts.dataStore, // dataStore
            params.market.marketToken, // market
            params.position.isLong(), // isLong
            params.position.sizeInUsd(), // prevPositionSizeInUsd
            params.position.borrowingFactor(), // prevPositionBorrowingFactor
            nextPositionSizeInUsd, // nextPositionSizeInUsd
            nextPositionBorrowingFactor // nextPositionBorrowingFactor
        );
    }

    // the order.receiver is meant to allow the output of an order to be
    // received by an address that is different from the position.account
    // address
    // for funding fees, the funds are still credited to the owner
    // of the position indicated by order.account
    function incrementClaimableFundingAmount(
        PositionUtils.UpdatePositionParams memory params,
        PositionPricingUtils.PositionFees memory fees
    ) internal {
        // if the position has negative funding fees, distribute it to allow it to be claimable
        if (fees.funding.claimableLongTokenAmount > 0) {
            MarketUtils.incrementClaimableFundingAmount(
                params.contracts.dataStore,
                params.contracts.eventEmitter,
                params.market.marketToken,
                params.market.longToken,
                params.order.account(),
                fees.funding.claimableLongTokenAmount
            );
        }

        if (fees.funding.claimableShortTokenAmount > 0) {
            MarketUtils.incrementClaimableFundingAmount(
                params.contracts.dataStore,
                params.contracts.eventEmitter,
                params.market.marketToken,
                params.market.shortToken,
                params.order.account(),
                fees.funding.claimableShortTokenAmount
            );
        }
    }

    function updateOpenInterest(
        PositionUtils.UpdatePositionParams memory params,
        int256 sizeDeltaUsd,
        int256 sizeDeltaInTokens
    ) internal {
        if (sizeDeltaUsd != 0) {
            MarketUtils.applyDeltaToOpenInterest(
                params.contracts.dataStore,
                params.contracts.eventEmitter,
                params.market,
                params.position.collateralToken(),
                params.position.isLong(),
                sizeDeltaUsd
            );

            MarketUtils.applyDeltaToOpenInterestInTokens(
                params.contracts.dataStore,
                params.contracts.eventEmitter,
                params.position.market(),
                params.position.collateralToken(),
                params.position.isLong(),
                sizeDeltaInTokens
            );
        }
    }

    // returns priceImpactUsd, priceImpactAmount, sizeDeltaInTokens, executionPrice
    function getExecutionPriceForIncrease(
        UpdatePositionParams memory params,
        Price.Props memory indexTokenPrice
    ) external view returns (int256, int256, uint256, uint256) {
        // note that the executionPrice is not validated against the order.acceptablePrice value
        // if the sizeDeltaUsd is zero
        // for limit orders the order.triggerPrice should still have been validated
        if (params.order.sizeDeltaUsd() == 0) {
            // increase order:
            //     - long: use the larger price
            //     - short: use the smaller price
            return (0, 0, 0, indexTokenPrice.pickPrice(params.position.isLong()));
        }

        int256 priceImpactUsd = PositionPricingUtils.getPriceImpactUsd(
            PositionPricingUtils.GetPriceImpactUsdParams(
                params.contracts.dataStore,
                params.market,
                params.order.sizeDeltaUsd().toInt256(),
                params.order.isLong()
            )
        );

        // cap priceImpactUsd based on the amount available in the position impact pool
        priceImpactUsd = MarketUtils.getCappedPositionImpactUsd(
            params.contracts.dataStore,
            params.market.marketToken,
            indexTokenPrice,
            priceImpactUsd,
            params.order.sizeDeltaUsd()
        );

        // for long positions
        //
        // if price impact is positive, the sizeDeltaInTokens would be increased by the priceImpactAmount
        // the priceImpactAmount should be minimized
        //
        // if price impact is negative, the sizeDeltaInTokens would be decreased by the priceImpactAmount
        // the priceImpactAmount should be maximized

        // for short positions
        //
        // if price impact is positive, the sizeDeltaInTokens would be decreased by the priceImpactAmount
        // the priceImpactAmount should be minimized
        //
        // if price impact is negative, the sizeDeltaInTokens would be increased by the priceImpactAmount
        // the priceImpactAmount should be maximized

        int256 priceImpactAmount;

        if (priceImpactUsd > 0) {
            // use indexTokenPrice.max and round down to minimize the priceImpactAmount
            priceImpactAmount = priceImpactUsd / indexTokenPrice.max.toInt256();
        } else {
            // use indexTokenPrice.min and round up to maximize the priceImpactAmount
            priceImpactAmount = Calc.roundUpMagnitudeDivision(priceImpactUsd, indexTokenPrice.min);
        }

        uint256 baseSizeDeltaInTokens;

        if (params.position.isLong()) {
            // round the number of tokens for long positions down
            baseSizeDeltaInTokens = params.order.sizeDeltaUsd() / indexTokenPrice.max;
        } else {
            // round the number of tokens for short positions up
            baseSizeDeltaInTokens = Calc.roundUpDivision(params.order.sizeDeltaUsd(), indexTokenPrice.min);
        }

        int256 sizeDeltaInTokens;
        if (params.position.isLong()) {
            sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() + priceImpactAmount;
        } else {
            sizeDeltaInTokens = baseSizeDeltaInTokens.toInt256() - priceImpactAmount;
        }

        if (sizeDeltaInTokens < 0) {
            revert Errors.PriceImpactLargerThanOrderSize(priceImpactUsd, params.order.sizeDeltaUsd());
        }

        // using increase of long positions as an example
        // if price is $2000, sizeDeltaUsd is $5000, priceImpactUsd is -$1000
        // priceImpactAmount = -1000 / 2000 = -0.5
        // baseSizeDeltaInTokens = 5000 / 2000 = 2.5
        // sizeDeltaInTokens = 2.5 - 0.5 = 2
        // executionPrice = 5000 / 2 = $2500
        uint256 executionPrice = BaseOrderUtils.getExecutionPriceForIncrease(
            params.order.sizeDeltaUsd(),
            sizeDeltaInTokens.toUint256(),
            params.order.acceptablePrice(),
            params.position.isLong()
        );

        return (priceImpactUsd, priceImpactAmount, sizeDeltaInTokens.toUint256(), executionPrice);
    }

    // returns priceImpactUsd, priceImpactDiffUsd, executionPrice
    function getExecutionPriceForDecrease(
        UpdatePositionParams memory params,
        Price.Props memory indexTokenPrice
    ) external view returns (int256, uint256, uint256) {
        uint256 sizeDeltaUsd = params.order.sizeDeltaUsd();

        // note that the executionPrice is not validated against the order.acceptablePrice value
        // if the sizeDeltaUsd is zero
        // for limit orders the order.triggerPrice should still have been validated
        if (sizeDeltaUsd == 0) {
            // decrease order:
            //     - long: use the smaller price
            //     - short: use the larger price
            return (0, 0, indexTokenPrice.pickPrice(!params.position.isLong()));
        }

        GetExecutionPriceForDecreaseCache memory cache;

        cache.priceImpactUsd = PositionPricingUtils.getPriceImpactUsd(
            PositionPricingUtils.GetPriceImpactUsdParams(
                params.contracts.dataStore,
                params.market,
                -sizeDeltaUsd.toInt256(),
                params.order.isLong()
            )
        );

        // cap priceImpactUsd based on the amount available in the position impact pool
        cache.priceImpactUsd = MarketUtils.getCappedPositionImpactUsd(
            params.contracts.dataStore,
            params.market.marketToken,
            indexTokenPrice,
            cache.priceImpactUsd,
            sizeDeltaUsd
        );

        if (cache.priceImpactUsd < 0) {
            uint256 maxPriceImpactFactor = MarketUtils.getMaxPositionImpactFactor(
                params.contracts.dataStore,
                params.market.marketToken,
                false
            );

            // convert the max price impact to the min negative value
            // e.g. if sizeDeltaUsd is 10,000 and maxPriceImpactFactor is 2%
            // then minPriceImpactUsd = -200
            int256 minPriceImpactUsd = -Precision.applyFactor(sizeDeltaUsd, maxPriceImpactFactor).toInt256();

            // cap priceImpactUsd to the min negative value and store the difference in priceImpactDiffUsd
            // e.g. if priceImpactUsd is -500 and minPriceImpactUsd is -200
            // then set priceImpactDiffUsd to -200 - -500 = 300
            // set priceImpactUsd to -200
            if (cache.priceImpactUsd < minPriceImpactUsd) {
                cache.priceImpactDiffUsd = (minPriceImpactUsd - cache.priceImpactUsd).toUint256();
                cache.priceImpactUsd = minPriceImpactUsd;
            }
        }

        // the executionPrice is calculated after the price impact is capped
        // so the output amount directly received by the user may not match
        // the executionPrice, the difference would be stored as a
        // claimable amount
        cache.executionPrice = BaseOrderUtils.getExecutionPriceForDecrease(
            indexTokenPrice,
            params.position.sizeInUsd(),
            params.position.sizeInTokens(),
            sizeDeltaUsd,
            cache.priceImpactUsd,
            params.order.acceptablePrice(),
            params.position.isLong()
        );

        return (cache.priceImpactUsd, cache.priceImpactDiffUsd, cache.executionPrice);
    }

}
