// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title IGigaVault
 * @dev Interface for the GigaVault contract (USDmore token)
 * ERC20 token backed 1:1 by USDmY with daily lottery and auction mechanics.
 * A 1% fee on mint/burn/transfer is split between a lottery pool and an auction pool.
 */
interface IGigaVault {
    // ──────────────────────────────────────────────
    //  Structs
    // ──────────────────────────────────────────────

    struct UnclaimedPrize {
        address winner;
        uint112 amount;
    }

    struct DualState {
        uint112 olderValue;
        uint112 latestValue;
        uint32 lastUpdatedDay;
    }

    struct DualAddress {
        address olderValue;
        address latestValue;
        uint32 lastUpdatedDay;
    }

    struct Auction {
        address currentBidder;
        uint96 currentBid;
        uint96 minBid;
        uint112 auctionTokens;
        uint32 auctionDay;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event Minted(
        address indexed to,
        uint256 collateralAmount,
        uint256 tokenAmount,
        uint256 fee
    );
    event Redeemed(
        address indexed from,
        uint256 tokenAmount,
        uint256 collateralAmount,
        uint256 fee
    );
    event LotteryWon(address indexed winner, uint256 amount, uint256 indexed day);
    event PrizeClaimed(address indexed winner, uint256 amount);
    event BeneficiaryFunded(
        address indexed beneficiary,
        uint256 amount,
        address previousWinner
    );
    event AuctionStarted(uint256 indexed day, uint256 tokenAmount, uint256 minBid);
    event BidPlaced(address indexed bidder, uint256 amount, uint256 day);
    event BidRefunded(address indexed bidder, uint256 amount);
    event AuctionWon(
        address indexed winner,
        uint256 tokenAmount,
        uint256 collateralPaid,
        uint256 indexed day
    );
    event MaxSupplyLocked(uint256 maxSupply);
    event AuctionNoBids(uint256 indexed day, uint256 rolledOverAmount);
    event FeesDistributed(uint256 indexed day, uint256 lotteryShare, uint256 auctionShare);
    event UnclaimedPrizeExpired(
        address indexed previousWinner,
        uint256 amount,
        uint256 indexed day,
        uint256 slot,
        bool isLottery
    );

    // ──────────────────────────────────────────────
    //  Constants & Immutables
    // ──────────────────────────────────────────────

    function FEE_PERCENT() external view returns (uint256);
    function BASIS_POINTS() external view returns (uint256);
    function MINTING_PERIOD() external view returns (uint256);
    function FEES_POOL() external view returns (address);
    function LOT_POOL() external view returns (address);
    function TIME_GAP() external view returns (uint256);
    function MIN_FEES_FOR_DISTRIBUTION() external view returns (uint256);
    function LOTTERY_PERCENT() external view returns (uint256);
    function USDMY() external view returns (address);
    function USDM() external view returns (address);

    function deploymentTime() external view returns (uint256);
    function mintingEndTime() external view returns (uint256);
    function oneDayEndTime() external view returns (uint256);

    // ──────────────────────────────────────────────
    //  State Variables
    // ──────────────────────────────────────────────

    function maxSupplyEver() external view returns (uint112);
    function lastLotteryDay() external view returns (uint32);
    function escrowedBid() external view returns (uint256);

    function holderCount()
        external
        view
        returns (uint112 olderValue, uint112 latestValue, uint32 lastUpdatedDay);

    function totalHolderBalance()
        external
        view
        returns (uint112 olderValue, uint112 latestValue, uint32 lastUpdatedDay);

    function holderByIndex(uint256 index)
        external
        view
        returns (address olderValue, address latestValue, uint32 lastUpdatedDay);

    function indexByHolder(address holder)
        external
        view
        returns (uint112 olderValue, uint112 latestValue, uint32 lastUpdatedDay);

    function fenwickTree(uint256 index)
        external
        view
        returns (uint112 olderValue, uint112 latestValue, uint32 lastUpdatedDay);

    function lotteryUnclaimedPrizes(uint256 slot)
        external
        view
        returns (address winner, uint112 amount);

    function auctionUnclaimedPrizes(uint256 slot)
        external
        view
        returns (address winner, uint112 amount);

    function currentAuction()
        external
        view
        returns (
            address currentBidder,
            uint96 currentBid,
            uint96 minBid,
            uint112 auctionTokens,
            uint32 auctionDay
        );

    // ──────────────────────────────────────────────
    //  Core Operations
    // ──────────────────────────────────────────────

    /**
     * @notice Mint USDmore by depositing USDmY collateral (1:1 ratio, both 18 decimals).
     * @dev During the first day, minting is 1:1 in base units to prevent inflation attacks.
     *      After day 1 but within the 3-day minting period, tokens are minted proportionally
     *      to the current reserve ratio: `collateral * totalSupply / reserve`.
     *      After the minting period, minting is capped at `maxSupplyEver` (set once at the
     *      end of the minting period) and requires a minimum of 100 wei.
     *      A 1% fee is deducted from minted tokens and sent to FEES_POOL.
     *      Triggers any pending lottery/auction before state changes.
     *      Requires prior ERC20 approval of USDmY.
     * @param collateralAmount Amount of USDmY to deposit
     */
    function mint(uint256 collateralAmount) external;

    /**
     * @notice Mint USDmore by depositing USDm (automatically converted to USDmY).
     * @dev USDm is deposited into the USDmY ERC4626 vault; the resulting shares
     *      are used as collateral. Same fee and max supply rules as mint().
     *      Requires prior ERC20 approval of USDm.
     * @param usdmAmount Amount of USDm to deposit
     */
    function mintWithUSDm(uint256 usdmAmount) external;

    /**
     * @notice Redeem USDmore for a proportional share of the USDmY reserve.
     * @dev Redemption value = `(amount - 1% fee) * reserve / totalSupply`.
     *      Because the reserve may grow (from auction bids absorbed) or shrink
     *      (from unclaimed prize payouts), the redemption rate can differ from 1:1.
     *      Escrowed auction bids are excluded from the reserve calculation.
     *      The fee portion is sent to FEES_POOL; the net tokens are burned.
     *      Triggers any pending lottery/auction before state changes.
     * @param amount Amount of USDmore to redeem
     */
    function redeem(uint256 amount) external;

    /**
     * @notice Redeem USDmore and receive USDm (USDmY is unwrapped automatically).
     * @dev The proportional USDmY share is redeemed from the USDmY ERC4626 vault,
     *      and the underlying USDm is sent directly to the caller.
     * @param amount Amount of USDmore to redeem
     */
    function redeemToUSDm(uint256 amount) external;

    /**
     * @notice Place a bid in the current daily auction using USDmY.
     * @dev Auctions distribute the auction share (~69%) of accumulated fees as USDmore
     *      to the highest bidder. The winning bid's USDmY is absorbed into the reserve,
     *      increasing the backing ratio for all holders.
     *      First bid must meet the minimum bid (50% of redemption value of auctioned tokens).
     *      Subsequent bids must be at least 10% higher than the current bid.
     *      The 10% increment prevents bot-driven marginal outbidding and creates a
     *      speculative window for early bidders.
     *      Previous bidder is refunded immediately via safeTransfer.
     *      Bid USDmY is held in escrow (excluded from reserve) until auction finalizes.
     *      Requires prior ERC20 approval of USDmY.
     * @param bidAmount Amount of USDmY to bid
     */
    function bid(uint256 bidAmount) external;

    /**
     * @notice Place a bid using USDm (automatically converted to USDmY).
     * @dev USDm is deposited into the USDmY vault; the resulting shares are used
     *      as the bid amount. Refunds for outbid bidders are always in USDmY.
     *      Requires prior ERC20 approval of USDm.
     * @param usdmAmount Amount of USDm to bid
     */
    function bidWithUSDm(uint256 usdmAmount) external;

    /**
     * @notice Manually trigger the daily lottery and auction cycle.
     * @dev Normally triggered automatically by mint/redeem/transfer, but can be called
     *      directly if no user activity occurs on a given day.
     *      Requires: at least day 1, at least 1 minute into the new day (TIME_GAP),
     *      and accumulated fees >= MIN_FEES_FOR_DISTRIBUTION (1e12 wei).
     *      Fees are split: LOTTERY_PERCENT (31%) to lottery, remainder to auction.
     *      The lottery selects a winner weighted by token balance using a Fenwick tree
     *      binary search on a snapshot of the previous day's balances.
     *      The auction finalizes the previous day's auction (if any) and starts a new one.
     */
    function executeLottery() external;

    /**
     * @notice Claim all unclaimed lottery and auction prizes for the caller.
     * @dev Scans all 7 cyclical slots in both lotteryUnclaimedPrizes and
     *      auctionUnclaimedPrizes for entries matching msg.sender.
     *      Prizes are held as USDmore in LOT_POOL and transferred to the caller.
     *      Reverts if no prizes are found.
     */
    function claim() external;

    // ──────────────────────────────────────────────
    //  View Functions
    // ──────────────────────────────────────────────

    /**
     * @notice Get the USDmY reserve backing all USDmore tokens.
     * @dev Returns the contract's USDmY balance minus escrowed auction bids.
     *      This is the denominator used in redemption calculations.
     */
    function getReserve() external view returns (uint256);

    /**
     * @notice Get the current pseudo-day number since deployment.
     * @dev Uses 25-hour days so the daily cycle drifts across time zones,
     *      preventing any single timezone from having a consistent advantage
     *      at lottery/auction boundaries.
     */
    function getCurrentDay() external view returns (uint256);

    function getHolderCount() external view returns (uint256);

    function getHolderByIndex(uint256 index)
        external
        view
        returns (address holder, uint256 balance);

    function currentLotteryPool() external view returns (uint256);

    function isHolder(address account) external view returns (bool);

    function getFenwickValue(uint256 index) external view returns (uint256);

    function getSuffixSum(uint256 index) external view returns (uint256);

    /**
     * @notice Get total claimable prize amount for the caller across all slots.
     * @dev Checks all 7 lottery and 7 auction unclaimed prize slots.
     */
    function getMyClaimableAmount() external view returns (uint256 total);

    /**
     * @notice Get all unclaimed prizes across both lottery and auction pools.
     * @dev Returns parallel arrays of winners and amounts for all 7 slots
     *      in both the lottery and auction prize rings.
     */
    function getAllUnclaimedPrizes()
        external
        view
        returns (
            address[7] memory lotteryWinners,
            uint112[7] memory lotteryAmounts,
            address[7] memory auctionWinners,
            uint112[7] memory auctionAmounts
        );

    // ──────────────────────────────────────────────
    //  Ownership
    // ──────────────────────────────────────────────

    /**
     * @notice Disabled — ownership cannot be renounced.
     * @dev The owner receives unclaimed prizes as USDmY, so renouncing
     *      would lock those funds permanently.
     */
    function renounceOwnership() external;
}
