// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

// Needed to pass in structs
pragma experimental ABIEncoderV2;

// Imports

import "./IERC20.sol";
import "./ConfigurableRightsPool.sol";
import "./IBFactory.sol";
import "./KalancerConstants.sol";
import "./KalancerSafeMath.sol";
import "./SafeApprove.sol";


/**
 * @author Kalancer Labs
 * @title Factor out the weight updates
 */
library SmartPoolManager {
    // Type declarations

    struct NewTokenParams {
        address addr;
        bool isCommitted;
        uint commitBlock;
        uint denorm;
        uint balance;
    }

    // updateWeight and pokeWeights are unavoidably long
    /* solhint-disable function-max-lines */

    /**
     * @notice Update the weight of an existing token
     * @dev Refactored to library to make CRPFactory deployable
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param token - token to be reweighted
     * @param newWeight - new weight of the token
    */
    function updateWeight(
        ConfigurableRightsPool self,
        IBPool BPool,
        address token,
        uint newWeight
    )
        external
    {
        require(newWeight >= KalancerConstants.MIN_WEIGHT, "ERR_MIN_WEIGHT");
        require(newWeight <= KalancerConstants.MAX_WEIGHT, "ERR_MAX_WEIGHT");

        uint currentWeight = BPool.getDenormalizedWeight(token);
        // Save gas; return immediately on NOOP
        if (currentWeight == newWeight) {
             return;
        }

        uint currentBalance = BPool.getBalance(token);
        uint totalSupply = self.totalSupply();
        uint totalWeight = BPool.getTotalDenormalizedWeight();
        uint poolShares;
        uint deltaBalance;
        uint deltaWeight;
        uint newBalance;

        if (newWeight < currentWeight) {
            // This means the controller will withdraw tokens to keep price
            // So they need to redeem PCTokens
            deltaWeight = KalancerSafeMath.bsub(currentWeight, newWeight);

            // poolShares = totalSupply * (deltaWeight / totalWeight)
            poolShares = KalancerSafeMath.bmul(totalSupply,
                                               KalancerSafeMath.bdiv(deltaWeight, totalWeight));

            // deltaBalance = currentBalance * (deltaWeight / currentWeight)
            deltaBalance = KalancerSafeMath.bmul(currentBalance,
                                                 KalancerSafeMath.bdiv(deltaWeight, currentWeight));

            // New balance cannot be lower than MIN_BALANCE
            newBalance = KalancerSafeMath.bsub(currentBalance, deltaBalance);

            require(newBalance >= KalancerConstants.MIN_BALANCE, "ERR_MIN_BALANCE");

            // First get the tokens from this contract (Pool Controller) to msg.sender
            BPool.rebind(token, newBalance, newWeight);

            // Now with the tokens this contract can send them to msg.sender
            bool xfer = IERC20(token).transfer(msg.sender, deltaBalance);
            require(xfer, "ERR_ERC20_FALSE");

            self.pullPoolShareFromLib(msg.sender, poolShares);
            self.burnPoolShareFromLib(poolShares);
        }
        else {
            // This means the controller will deposit tokens to keep the price.
            // They will be minted and given PCTokens
            deltaWeight = KalancerSafeMath.bsub(newWeight, currentWeight);

            require(KalancerSafeMath.badd(totalWeight, deltaWeight) <= KalancerConstants.MAX_TOTAL_WEIGHT,
                    "ERR_MAX_TOTAL_WEIGHT");

            // poolShares = totalSupply * (deltaWeight / totalWeight)
            poolShares = KalancerSafeMath.bmul(totalSupply,
                                               KalancerSafeMath.bdiv(deltaWeight, totalWeight));
            // deltaBalance = currentBalance * (deltaWeight / currentWeight)
            deltaBalance = KalancerSafeMath.bmul(currentBalance,
                                                 KalancerSafeMath.bdiv(deltaWeight, currentWeight));

            // First gets the tokens from msg.sender to this contract (Pool Controller)
            bool xfer = IERC20(token).transferFrom(msg.sender, address(this), deltaBalance);
            require(xfer, "ERR_ERC20_FALSE");

            // Now with the tokens this contract can bind them to the pool it controls
            BPool.rebind(token, KalancerSafeMath.badd(currentBalance, deltaBalance), newWeight);

            self.mintPoolShareFromLib(poolShares);
            self.pushPoolShareFromLib(msg.sender, poolShares);
        }
    }

    /**
     * @notice External function called to make the contract update weights according to plan
     * @param BPool - Core BPool the CRP is wrapping
     * @param gradualUpdate - gradual update parameters from the CRP
    */
    function pokeWeights(
        IBPool BPool,
        ConfigurableRightsPool.GradualUpdateParams storage gradualUpdate
    )
        external
    {
        // Do nothing if we call this when there is no update plan
        if (gradualUpdate.startBlock == 0) {
            return;
        }

        // Error to call it before the start of the plan
        require(block.number >= gradualUpdate.startBlock, "ERR_CANT_POKE_YET");
        // Proposed error message improvement
        // require(block.number >= startBlock, "ERR_NO_HOKEY_POKEY");

        // This allows for pokes after endBlock that get weights to endWeights
        // Get the current block (or the endBlock, if we're already past the end)
        uint currentBlock;
        if (block.number > gradualUpdate.endBlock) {
            currentBlock = gradualUpdate.endBlock;
        }
        else {
            currentBlock = block.number;
        }

        uint blockPeriod = KalancerSafeMath.bsub(gradualUpdate.endBlock, gradualUpdate.startBlock);
        uint blocksElapsed = KalancerSafeMath.bsub(currentBlock, gradualUpdate.startBlock);
        uint weightDelta;
        uint deltaPerBlock;
        uint newWeight;

        address[] memory tokens = BPool.getCurrentTokens();

        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            // Make sure it does nothing if the new and old weights are the same (saves gas)
            // It's a degenerate case if they're *all* the same, but you certainly could have
            // a plan where you only change some of the weights in the set
            if (gradualUpdate.startWeights[i] != gradualUpdate.endWeights[i]) {
                if (gradualUpdate.endWeights[i] < gradualUpdate.startWeights[i]) {
                    // We are decreasing the weight

                    // First get the total weight delta
                    weightDelta = KalancerSafeMath.bsub(gradualUpdate.startWeights[i],
                                                        gradualUpdate.endWeights[i]);
                    // And the amount it should change per block = total change/number of blocks in the period
                    deltaPerBlock = KalancerSafeMath.bdiv(weightDelta, blockPeriod);
                    //deltaPerBlock = bdivx(weightDelta, blockPeriod);

                     // newWeight = startWeight - (blocksElapsed * deltaPerBlock)
                    newWeight = KalancerSafeMath.bsub(gradualUpdate.startWeights[i],
                                                      KalancerSafeMath.bmul(blocksElapsed, deltaPerBlock));
                }
                else {
                    // We are increasing the weight

                    // First get the total weight delta
                    weightDelta = KalancerSafeMath.bsub(gradualUpdate.endWeights[i],
                                                        gradualUpdate.startWeights[i]);
                    // And the amount it should change per block = total change/number of blocks in the period
                    deltaPerBlock = KalancerSafeMath.bdiv(weightDelta, blockPeriod);
                    //deltaPerBlock = bdivx(weightDelta, blockPeriod);

                     // newWeight = startWeight + (blocksElapsed * deltaPerBlock)
                    newWeight = KalancerSafeMath.badd(gradualUpdate.startWeights[i],
                                                      KalancerSafeMath.bmul(blocksElapsed, deltaPerBlock));
                }

                uint bal = BPool.getBalance(tokens[i]);

                BPool.rebind(tokens[i], bal, newWeight);
            }
        }

        // Reset to allow add/remove tokens, or manual weight updates
        if (block.number >= gradualUpdate.endBlock) {
            gradualUpdate.startBlock = 0;
        }
    }

    /* solhint-enable function-max-lines */

    /**
     * @notice Schedule (commit) a token to be added; must call applyAddToken after a fixed
     *         number of blocks to actually add the token
     * @param BPool - Core BPool the CRP is wrapping
     * @param token - the token to be added
     * @param balance - how much to be added
     * @param denormalizedWeight - the desired token weight
     * @param newToken - NewTokenParams struct used to hold the token data (in CRP storage)
     */
    function commitAddToken(
        IBPool BPool,
        address token,
        uint balance,
        uint denormalizedWeight,
        NewTokenParams storage newToken
    )
        external
    {
        require(!BPool.isBound(token), "ERR_IS_BOUND");

        require(denormalizedWeight <= KalancerConstants.MAX_WEIGHT, "ERR_WEIGHT_ABOVE_MAX");
        require(denormalizedWeight >= KalancerConstants.MIN_WEIGHT, "ERR_WEIGHT_BELOW_MIN");
        require(KalancerSafeMath.badd(BPool.getTotalDenormalizedWeight(),
                                      denormalizedWeight) <= KalancerConstants.MAX_TOTAL_WEIGHT,
                "ERR_MAX_TOTAL_WEIGHT");
        require(balance >= KalancerConstants.MIN_BALANCE, "ERR_BALANCE_BELOW_MIN");

        newToken.addr = token;
        newToken.balance = balance;
        newToken.denorm = denormalizedWeight;
        newToken.commitBlock = block.number;
        newToken.isCommitted = true;
    }

    /**
     * @notice Add the token previously committed (in commitAddToken) to the pool
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param addTokenTimeLockInBlocks -  Wait time between committing and applying a new token
     * @param newToken - NewTokenParams struct used to hold the token data (in CRP storage)
     */
    function applyAddToken(
        ConfigurableRightsPool self,
        IBPool BPool,
        uint addTokenTimeLockInBlocks,
        NewTokenParams storage newToken
    )
        external
    {
        require(newToken.isCommitted, "ERR_NO_TOKEN_COMMIT");
        require(KalancerSafeMath.bsub(block.number, newToken.commitBlock) >= addTokenTimeLockInBlocks,
                                      "ERR_TIMELOCK_STILL_COUNTING");

        uint totalSupply = self.totalSupply();

        // poolShares = totalSupply * newTokenWeight / totalWeight
        uint poolShares = KalancerSafeMath.bdiv(KalancerSafeMath.bmul(totalSupply, newToken.denorm),
                                                BPool.getTotalDenormalizedWeight());

        // Clear this to allow adding more tokens
        newToken.isCommitted = false;

        // First gets the tokens from msg.sender to this contract (Pool Controller)
        bool returnValue = IERC20(newToken.addr).transferFrom(self.getController(), address(self), newToken.balance);
        require(returnValue, "ERR_ERC20_FALSE");

        // Now with the tokens this contract can bind them to the pool it controls
        // Approves BPool to pull from this controller
        // Approve unlimited, same as when creating the pool, so they can join pools later
        returnValue = SafeApprove.safeApprove(IERC20(newToken.addr), address(BPool), KalancerConstants.MAX_UINT);
        require(returnValue, "ERR_ERC20_FALSE");

        BPool.bind(newToken.addr, newToken.balance, newToken.denorm);

        self.mintPoolShareFromLib(poolShares);
        self.pushPoolShareFromLib(msg.sender, poolShares);
    }

     /**
     * @notice Remove a token from the pool
     * @dev Logic in the CRP controls when ths can be called. There are two related permissions:
     *      AddRemoveTokens - which allows removing down to the underlying BPool limit of two
     *      RemoveAllTokens - which allows completely draining the pool by removing all tokens
     *                        This can result in a non-viable pool with 0 or 1 tokens (by design),
     *                        meaning all swapping or binding operations would fail in this state
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param token - token to remove
     */
    function removeToken(
        ConfigurableRightsPool self,
        IBPool BPool,
        address token
    )
        external
    {
        uint totalSupply = self.totalSupply();

        // poolShares = totalSupply * tokenWeight / totalWeight
        uint poolShares = KalancerSafeMath.bdiv(KalancerSafeMath.bmul(totalSupply,
                                                                      BPool.getDenormalizedWeight(token)),
                                                BPool.getTotalDenormalizedWeight());

        // this is what will be unbound from the pool
        // Have to get it before unbinding
        uint balance = BPool.getBalance(token);

        // Unbind and get the tokens out of Kalancer pool
        BPool.unbind(token);

        // Now with the tokens this contract can send them to msg.sender
        bool xfer = IERC20(token).transfer(self.getController(), balance);
        require(xfer, "ERR_ERC20_FALSE");

        self.pullPoolShareFromLib(self.getController(), poolShares);
        self.burnPoolShareFromLib(poolShares);
    }

    /**
     * @notice Non ERC20-conforming tokens are problematic; don't allow them in pools
     * @dev Will revert if invalid
     * @param token - The prospective token to verify
     */
    function verifyTokenCompliance(address token) external {
        verifyTokenComplianceInternal(token);
    }

    /**
     * @notice Non ERC20-conforming tokens are problematic; don't allow them in pools
     * @dev Will revert if invalid - overloaded to save space in the main contract
     * @param tokens - The prospective tokens to verify
     */
    function verifyTokenCompliance(address[] calldata tokens) external {
        for (uint i = 0; i < tokens.length; i++) {
            verifyTokenComplianceInternal(tokens[i]);
         }
    }

    /**
     * @notice Update weights in a predetermined way, between startBlock and endBlock,
     *         through external cals to pokeWeights
     * @param BPool - Core BPool the CRP is wrapping
     * @param newWeights - final weights we want to get to
     * @param startBlock - when weights should start to change
     * @param endBlock - when weights will be at their final values
     * @param minimumWeightChangeBlockPeriod - needed to validate the block period
    */
    function updateWeightsGradually(
        IBPool BPool,
        ConfigurableRightsPool.GradualUpdateParams storage gradualUpdate,
        uint[] calldata newWeights,
        uint startBlock,
        uint endBlock,
        uint minimumWeightChangeBlockPeriod
    )
        external
    {
        // Enforce a minimum time over which to make the changes
        // The also prevents endBlock <= startBlock
        require(KalancerSafeMath.bsub(endBlock, startBlock) >= minimumWeightChangeBlockPeriod,
                "ERR_WEIGHT_CHANGE_TIME_BELOW_MIN");
        require(block.number < endBlock, "ERR_GRADUAL_UPDATE_TIME_TRAVEL");

        address[] memory tokens = BPool.getCurrentTokens();

        // Must specify weights for all tokens
        require(newWeights.length == tokens.length, "ERR_START_WEIGHTS_MISMATCH");

        uint weightsSum = 0;
        gradualUpdate.startWeights = new uint[](tokens.length);

        // Check that endWeights are valid now to avoid reverting in a future pokeWeights call
        //
        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            require(newWeights[i] <= KalancerConstants.MAX_WEIGHT, "ERR_WEIGHT_ABOVE_MAX");
            require(newWeights[i] >= KalancerConstants.MIN_WEIGHT, "ERR_WEIGHT_BELOW_MIN");

            weightsSum = KalancerSafeMath.badd(weightsSum, newWeights[i]);
            gradualUpdate.startWeights[i] = BPool.getDenormalizedWeight(tokens[i]);
        }
        require(weightsSum <= KalancerConstants.MAX_TOTAL_WEIGHT, "ERR_MAX_TOTAL_WEIGHT");

        if (block.number > startBlock && block.number < endBlock) {
            // This means the weight update should start ASAP
            // Moving the start block up prevents a big jump/discontinuity in the weights
            //
            // Only valid within the startBlock - endBlock period!
            // Should not happen, but defensively check that we aren't
            // setting the start point past the end point
            gradualUpdate.startBlock = block.number;
        }
        else{
            gradualUpdate.startBlock = startBlock;
        }

        gradualUpdate.endBlock = endBlock;
        gradualUpdate.endWeights = newWeights;
    }

    /**
     * @notice Join a pool
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param poolAmountOut - number of pool tokens to receive
     * @param maxAmountsIn - Max amount of asset tokens to spend
     * @return actualAmountsIn - calculated values of the tokens to pull in
     */
    function joinPool(
        ConfigurableRightsPool self,
        IBPool BPool,
        uint poolAmountOut,
        uint[] calldata maxAmountsIn
    )
         external
         view
         returns (uint[] memory actualAmountsIn)
    {
        address[] memory tokens = BPool.getCurrentTokens();

        require(maxAmountsIn.length == tokens.length, "ERR_AMOUNTS_MISMATCH");

        uint poolTotal = self.totalSupply();
        // Subtract  1 to ensure any rounding errors favor the pool
        uint ratio = KalancerSafeMath.bdiv(poolAmountOut,
                                           KalancerSafeMath.bsub(poolTotal, 1));

        require(ratio != 0, "ERR_MATH_APPROX");

        // We know the length of the array; initialize it, and fill it below
        // Cannot do "push" in memory
        actualAmountsIn = new uint[](tokens.length);

        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint bal = BPool.getBalance(t);
            // Add 1 to ensure any rounding errors favor the pool
            uint tokenAmountIn = KalancerSafeMath.bmul(ratio,
                                                       KalancerSafeMath.badd(bal, 1));

            require(tokenAmountIn != 0, "ERR_MATH_APPROX");
            require(tokenAmountIn <= maxAmountsIn[i], "ERR_LIMIT_IN");

            actualAmountsIn[i] = tokenAmountIn;
        }
    }

    /**
     * @notice Exit a pool - redeem pool tokens for underlying assets
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountsOut - minimum amount of asset tokens to receive
     * @return exitFee - calculated exit fee
     * @return pAiAfterExitFee - final amount in (after accounting for exit fee)
     * @return actualAmountsOut - calculated amounts of each token to pull
     */
    function exitPool(
        ConfigurableRightsPool self,
        IBPool BPool,
        uint poolAmountIn,
        uint[] calldata minAmountsOut
    )
        external
        view
        returns (uint exitFee, uint pAiAfterExitFee, uint[] memory actualAmountsOut)
    {
        address[] memory tokens = BPool.getCurrentTokens();

        require(minAmountsOut.length == tokens.length, "ERR_AMOUNTS_MISMATCH");

        uint poolTotal = self.totalSupply();

        // Calculate exit fee and the final amount in
        exitFee = KalancerSafeMath.bmul(poolAmountIn, KalancerConstants.EXIT_FEE);
        pAiAfterExitFee = KalancerSafeMath.bsub(poolAmountIn, exitFee);

        uint ratio = KalancerSafeMath.bdiv(pAiAfterExitFee,
                                           KalancerSafeMath.badd(poolTotal, 1));

        require(ratio != 0, "ERR_MATH_APPROX");

        actualAmountsOut = new uint[](tokens.length);

        // This loop contains external calls
        // External calls are to math libraries or the underlying pool, so low risk
        for (uint i = 0; i < tokens.length; i++) {
            address t = tokens[i];
            uint bal = BPool.getBalance(t);
            // Subtract 1 to ensure any rounding errors favor the pool
            uint tokenAmountOut = KalancerSafeMath.bmul(ratio,
                                                        KalancerSafeMath.bsub(bal, 1));

            require(tokenAmountOut != 0, "ERR_MATH_APPROX");
            require(tokenAmountOut >= minAmountsOut[i], "ERR_LIMIT_OUT");

            actualAmountsOut[i] = tokenAmountOut;
        }
    }

    /**
     * @notice Join by swapping a fixed amount of an external token in (must be present in the pool)
     *         System calculates the pool token amount
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param tokenIn - which token we're transferring in
     * @param tokenAmountIn - amount of deposit
     * @param minPoolAmountOut - minimum of pool tokens to receive
     * @return poolAmountOut - amount of pool tokens minted and transferred
     */
    function joinswapExternAmountIn(
        ConfigurableRightsPool self,
        IBPool BPool,
        address tokenIn,
        uint tokenAmountIn,
        uint minPoolAmountOut
    )
        external
        view
        returns (uint poolAmountOut)
    {
        require(BPool.isBound(tokenIn), "ERR_NOT_BOUND");
        require(tokenAmountIn <= KalancerSafeMath.bmul(BPool.getBalance(tokenIn),
                                                       KalancerConstants.MAX_IN_RATIO),
                                                       "ERR_MAX_IN_RATIO");

        poolAmountOut = BPool.calcPoolOutGivenSingleIn(
                            BPool.getBalance(tokenIn),
                            BPool.getDenormalizedWeight(tokenIn),
                            self.totalSupply(),
                            BPool.getTotalDenormalizedWeight(),
                            tokenAmountIn,
                            BPool.getSwapFee()
                        );

        require(poolAmountOut >= minPoolAmountOut, "ERR_LIMIT_OUT");
    }

    /**
     * @notice Join by swapping an external token in (must be present in the pool)
     *         To receive an exact amount of pool tokens out. System calculates the deposit amount
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param tokenIn - which token we're transferring in (system calculates amount required)
     * @param poolAmountOut - amount of pool tokens to be received
     * @param maxAmountIn - Maximum asset tokens that can be pulled to pay for the pool tokens
     * @return tokenAmountIn - amount of asset tokens transferred in to purchase the pool tokens
     */
    function joinswapPoolAmountOut(
        ConfigurableRightsPool self,
        IBPool BPool,
        address tokenIn,
        uint poolAmountOut,
        uint maxAmountIn
    )
        external
        view
        returns (uint tokenAmountIn)
    {
        require(BPool.isBound(tokenIn), "ERR_NOT_BOUND");

        tokenAmountIn = BPool.calcSingleInGivenPoolOut(
                            BPool.getBalance(tokenIn),
                            BPool.getDenormalizedWeight(tokenIn),
                            self.totalSupply(),
                            BPool.getTotalDenormalizedWeight(),
                            poolAmountOut,
                            BPool.getSwapFee()
                        );

        require(tokenAmountIn != 0, "ERR_MATH_APPROX");
        require(tokenAmountIn <= maxAmountIn, "ERR_LIMIT_IN");

        require(tokenAmountIn <= KalancerSafeMath.bmul(BPool.getBalance(tokenIn),
                                                       KalancerConstants.MAX_IN_RATIO),
                                                       "ERR_MAX_IN_RATIO");
    }

    /**
     * @notice Exit a pool - redeem a specific number of pool tokens for an underlying asset
     *         Asset must be present in the pool, and will incur an EXIT_FEE (if set to non-zero)
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param tokenOut - which token the caller wants to receive
     * @param poolAmountIn - amount of pool tokens to redeem
     * @param minAmountOut - minimum asset tokens to receive
     * @return exitFee - calculated exit fee
     * @return tokenAmountOut - amount of asset tokens returned
     */
    function exitswapPoolAmountIn(
        ConfigurableRightsPool self,
        IBPool BPool,
        address tokenOut,
        uint poolAmountIn,
        uint minAmountOut
    )
        external
        view
        returns (uint exitFee, uint tokenAmountOut)
    {
        require(BPool.isBound(tokenOut), "ERR_NOT_BOUND");

        tokenAmountOut = BPool.calcSingleOutGivenPoolIn(
                            BPool.getBalance(tokenOut),
                            BPool.getDenormalizedWeight(tokenOut),
                            self.totalSupply(),
                            BPool.getTotalDenormalizedWeight(),
                            poolAmountIn,
                            BPool.getSwapFee()
                        );

        require(tokenAmountOut >= minAmountOut, "ERR_LIMIT_OUT");
        require(tokenAmountOut <= KalancerSafeMath.bmul(BPool.getBalance(tokenOut),
                                                        KalancerConstants.MAX_OUT_RATIO),
                                                        "ERR_MAX_OUT_RATIO");

        exitFee = KalancerSafeMath.bmul(poolAmountIn, KalancerConstants.EXIT_FEE);
    }

    /**
     * @notice Exit a pool - redeem pool tokens for a specific amount of underlying assets
     *         Asset must be present in the pool
     * @param self - ConfigurableRightsPool instance calling the library
     * @param BPool - Core BPool the CRP is wrapping
     * @param tokenOut - which token the caller wants to receive
     * @param tokenAmountOut - amount of underlying asset tokens to receive
     * @param maxPoolAmountIn - maximum pool tokens to be redeemed
     * @return exitFee - calculated exit fee
     * @return poolAmountIn - amount of pool tokens redeemed
     */
    function exitswapExternAmountOut(
        ConfigurableRightsPool self,
        IBPool BPool,
        address tokenOut,
        uint tokenAmountOut,
        uint maxPoolAmountIn
    )
        external
        view
        returns (uint exitFee, uint poolAmountIn)
    {
        require(BPool.isBound(tokenOut), "ERR_NOT_BOUND");
        require(tokenAmountOut <= KalancerSafeMath.bmul(BPool.getBalance(tokenOut),
                                                        KalancerConstants.MAX_OUT_RATIO),
                                                        "ERR_MAX_OUT_RATIO");
        poolAmountIn = BPool.calcPoolInGivenSingleOut(
                            BPool.getBalance(tokenOut),
                            BPool.getDenormalizedWeight(tokenOut),
                            self.totalSupply(),
                            BPool.getTotalDenormalizedWeight(),
                            tokenAmountOut,
                            BPool.getSwapFee()
                        );

        require(poolAmountIn != 0, "ERR_MATH_APPROX");
        require(poolAmountIn <= maxPoolAmountIn, "ERR_LIMIT_IN");

        exitFee = KalancerSafeMath.bmul(poolAmountIn, KalancerConstants.EXIT_FEE);
    }

    // Internal functions

    // Check for zero transfer, and make sure it returns true to returnValue
    function verifyTokenComplianceInternal(address token) internal {
        bool returnValue = IERC20(token).transfer(msg.sender, 0);
        require(returnValue, "ERR_NONCONFORMING_TOKEN");
    }
}
