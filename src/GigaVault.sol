// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title GigaVault
 * @dev ERC20 token (USDmore) backed by USDmY with daily lottery and auction mechanics
 * - 1:1 ratio (USDmY 18 decimals, USDmore 18 decimals)
 * - Redemption: Proportional share of contract's USDmY (USDmore * USDmY balance / total supply)
 * - 1% fee on mint/burn/transfer (split between lottery and auction pools)
 * - Daily lottery for random holder using prevrandao
 * - Daily auctions using ERC20 USDmY
 * - Efficient winner selection using Fenwick tree (Binary Indexed Tree)
 * - Uses transient storage for reentrancy guard (EIP-1153) for gas efficiency
 * - Ownable2Step: owner receives unclaimed prizes
 */
contract GigaVault is ERC20, ReentrancyGuardTransient, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    uint256 public constant FEE_PERCENT = 100; // 1% = 100 basis points
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant MINTING_PERIOD = 3 days;

    // Synthetic addresses for fee management
    address public constant FEES_POOL =
        0x00000000000fee50000000AdD2E5500000000000; // Where fees are collected
    address public constant LOT_POOL =
        0x0000000000010700000000aDD2E5500000000000; // Where lottery/auction prizes are held

    uint256 public immutable deploymentTime;
    uint256 public immutable mintingEndTime;
    uint256 public immutable oneDayEndTime;

    // Packed storage slot: 112 + 32 = 144 bits (fits in one 256-bit slot)
    uint112 public maxSupplyEver; // Set after minting period (max ~5.2 quadrillion USDmore with 18 decimals)
    uint32 public lastLotteryDay; // Day counter (sufficient for ~11.7 million years)

    uint256 public constant TIME_GAP = 1 minutes; // Must be 1 minute into new day before lottery can execute
    uint256 public constant MIN_FEES_FOR_DISTRIBUTION = 1e12; // Minimum fees (0.000001 USDmore) to run lottery/auction
    uint256 public constant LOTTERY_PERCENT = 31; // Percentage of fees going to lottery (rest goes to auction)

    // Cyclical arrays for unclaimed prizes (7 slots each)
    // Separate arrays for lottery and auction to prevent slot conflicts
    // We need 7 slots to ensure a full week of unclaimed prizes for each type
    // Since lottery and auction alternate daily after minting period, 7 slots is sufficient
    // Packed struct: 160 + 112 = 272 bits (exceeds 256, uses 2 slots per prize)
    struct UnclaimedPrize {
        address winner; // 160 bits
        uint112 amount; // 112 bits (USDmore amount for prizes)
    }

    UnclaimedPrize[7] public lotteryUnclaimedPrizes;
    UnclaimedPrize[7] public auctionUnclaimedPrizes;

    // Struct to maintain rolling 2-day history for each value
    // Stores current and previous value with the day of last update
    // Optimized to fit in one 256-bit storage slot
    struct DualState {
        uint112 olderValue; // Previous value before last update (112 bits)
        uint112 latestValue; // Most recent value (112 bits)
        uint32 lastUpdatedDay; // Day when latestValue was set (32 bits)
        // Total: 256 bits (fits exactly in 1 storage slot)
    }

    // For addresses, we need a separate struct since addresses are 160 bits
    struct DualAddress {
        address olderValue;
        address latestValue;
        uint32 lastUpdatedDay;
    }

    // Holder tracking with rolling 2-day history
    mapping(uint256 index => DualAddress) public holderByIndex;
    mapping(address holder => DualState) public indexByHolder;
    mapping(uint256 index => DualState) public fenwickTree;
    DualState public holderCount;
    DualState public totalHolderBalance;

    // USDmY token (ERC20) - the backing asset for USDmore (MegaETH mainnet)
    address public constant USDMY =
        0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890;

    // USDm token (ERC20) - the underlying stablecoin that USDmY wraps
    address public constant USDM =
        0xFAfDdbb3FC7688494971a79cc65DCa3EF82079E7;

    // Track USDmY escrowed for auction bids (separate from reserve)
    // This ensures bid amounts don't inflate the apparent reserve
    uint256 public escrowedBid;

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
    event UnclaimedPrizeExpired(address indexed previousWinner, uint256 amount, uint256 indexed day, uint256 slot, bool isLottery);

    // Auction state
    // Packed struct: 160 + 96 + 96 + 112 + 32 = 496 bits (uses 2 slots)
    struct Auction {
        address currentBidder; // 160 bits
        uint96 currentBid; // 96 bits - USDmY amount bid
        uint96 minBid; // 96 bits - Minimum bid required (in USDmY)
        uint112 auctionTokens; // 112 bits - USDmore amount being auctioned
        uint32 auctionDay; // 32 bits - Day of the auction
    }

    Auction public currentAuction;

    constructor() ERC20("USDm Ore", "USDmore") Ownable(msg.sender) {
        deploymentTime = block.timestamp;
        oneDayEndTime = deploymentTime + 1 days;
        mintingEndTime = deploymentTime + MINTING_PERIOD;
        require(mintingEndTime >= oneDayEndTime);
        require(IERC4626(USDMY).asset() == USDM, "USDmY asset mismatch");
    }

    /**
     * @dev Prevent renouncing ownership - owner receives unclaimed prizes
     */
    function renounceOwnership() public pure override {
        revert("Cannot renounce ownership");
    }

    /**
     * @dev Get the USDmY reserve (total USDmY balance minus escrowed bid amounts)
     * This is the actual backing for USDmore tokens, excluding auction bid escrow
     */
    function getReserve() public view returns (uint256) {
        return IERC20(USDMY).balanceOf(address(this)) - escrowedBid;
    }

    /**
     * @dev Check and set max supply after minting period ends
     */
    function _checkAndSetMaxSupply() internal {
        if (maxSupplyEver == 0 && block.timestamp > mintingEndTime) {
            // Set max supply based on total supply at end of minting period
            // 1:1 conversion - max supply equals total USDmore minted
            maxSupplyEver = uint112(totalSupply());
            emit MaxSupplyLocked(maxSupplyEver);
        }
    }

    /**
     * @dev Convert USDm to USDmY by depositing into the USDmY vault
     * @param usdmAmount Amount of USDm to deposit
     * @return sharesReceived Amount of USDmY shares received
     */
    function _depositUSDmForUSDmY(uint256 usdmAmount) internal returns (uint256 sharesReceived) {
        IERC20(USDM).safeTransferFrom(msg.sender, address(this), usdmAmount);
        IERC20(USDM).forceApprove(USDMY, usdmAmount);
        sharesReceived = IERC4626(USDMY).deposit(usdmAmount, address(this));
        require(sharesReceived > 0, "Zero shares received");
    }

    /**
     * @dev Mint USDmore by depositing USDmY (standard minting with fees)
     * 1:1 ratio (USDmY 18 decimals, USDmore 18 decimals)
     * After minting period: Can only mint up to available capacity
     * @param collateralAmount Amount of USDmY to deposit (requires prior approval)
     */
    function mint(uint256 collateralAmount) external nonReentrant {
        require(collateralAmount > 0, "Must send USDmY");

        _checkAndSetMaxSupply();
        _tryExecuteLotteryAndAuction();

        uint256 reserveBefore = getReserve();

        IERC20(USDMY).safeTransferFrom(msg.sender, address(this), collateralAmount);

        _mintCore(collateralAmount, reserveBefore);
    }

    /**
     * @dev Mint USDmore by depositing USDm (converted to USDmY automatically)
     * @param usdmAmount Amount of USDm to deposit (requires prior approval)
     */
    function mintWithUSDm(uint256 usdmAmount) external nonReentrant {
        require(usdmAmount > 0, "Must send USDm");

        _checkAndSetMaxSupply();
        _tryExecuteLotteryAndAuction();

        uint256 reserveBefore = getReserve();

        uint256 sharesReceived = _depositUSDmForUSDmY(usdmAmount);

        _mintCore(sharesReceived, reserveBefore);
    }

    /**
     * @dev Core minting logic shared by mint() and mintWithUSDm()
     * @param collateralAmount Amount of USDmY collateral already in the contract
     * @param reserveBefore Reserve captured before collateral transfer
     */
    function _mintCore(uint256 collateralAmount, uint256 reserveBefore) internal {
        uint256 tokensToMint;
        uint256 fee;
        uint256 netTokens;

        if (block.timestamp <= oneDayEndTime) {
            // During first day 1:1 in base units
            // This is to avoid an inflation attack
            tokensToMint = collateralAmount;
        } else {
            if (totalSupply() > 0 && reserveBefore > 0) {
                // Mint proportionally to maintain USDmY backing ratio
                tokensToMint =
                    (collateralAmount * totalSupply()) /
                    reserveBefore;
            } else {
                // Fallback to 1:1 if no supply or USDmY
                tokensToMint = collateralAmount;
            }

            if (block.timestamp > mintingEndTime) {
                // Enforce max supply after minting period
                require(
                    totalSupply() + tokensToMint <= maxSupplyEver,
                    "Max supply reached"
                );
                require(tokensToMint >= 100, "Minimum mint amount is 100 wei");
            }
        }

        // Calculate and apply fees (common to both minting periods)
        fee = (tokensToMint * FEE_PERCENT) / BASIS_POINTS;
        netTokens = tokensToMint - fee;

        // Mint full amount to user, then transfer fee portion to FEES_POOL
        _mint(msg.sender, tokensToMint);
        if (fee > 0) {
            _atomicUpdate(msg.sender, FEES_POOL, fee);
        }

        emit Minted(msg.sender, collateralAmount, netTokens, fee);
    }

    /**
     * @dev Redeem USDmore for USDmY
     * Returns proportional share of contract's USDmY reserve (minus 1% fee)
     */
    function redeem(uint256 amount) external nonReentrant {
        uint256 collateralToReturn = _redeemCore(amount);
        IERC20(USDMY).safeTransfer(msg.sender, collateralToReturn);
    }

    /**
     * @dev Redeem USDmore and receive USDm (USDmY is unwrapped automatically)
     * @param amount Amount of USDmore to redeem
     */
    function redeemToUSDm(uint256 amount) external nonReentrant {
        uint256 collateralToReturn = _redeemCore(amount);
        IERC4626(USDMY).redeem(collateralToReturn, msg.sender, address(this));
    }

    /**
     * @dev Core redemption logic shared by redeem() and redeemToUSDm()
     * @param amount Amount of USDmore to redeem
     * @return collateralToReturn Amount of USDmY to return
     */
    function _redeemCore(uint256 amount) internal returns (uint256 collateralToReturn) {
        require(amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        _checkAndSetMaxSupply();
        _tryExecuteLotteryAndAuction();

        uint256 fee = (amount * FEE_PERCENT) / BASIS_POINTS;
        uint256 netTokens = amount - fee;

        // Calculate proportional USDmY to return before state changes
        collateralToReturn = (netTokens * getReserve()) / totalSupply();

        // Transfer fees atomically (Fenwick tree updated automatically)
        if (fee > 0) {
            _atomicUpdate(msg.sender, FEES_POOL, fee);
        }

        // Burn the remainder from user atomically (Fenwick tree updated automatically)
        _burn(msg.sender, netTokens);

        emit Redeemed(msg.sender, amount, collateralToReturn, fee);
    }

    /**
     * @dev Atomic balance update that ensures Fenwick tree consistency
     * This function should be used for ALL internal balance changes to maintain atomicity
     */
    function _atomicUpdate(address from, address to, uint256 value) internal {
        // Get balances BEFORE the update
        uint256 fromBalanceBefore = from != address(0) ? balanceOf(from) : 0;
        uint256 toBalanceBefore = to != address(0) ? balanceOf(to) : 0;

        // Perform the actual balance update
        super._update(from, to, value);

        // Get balances AFTER the update
        uint256 fromBalanceAfter = from != address(0) ? balanceOf(from) : 0;
        uint256 toBalanceAfter = to != address(0) ? balanceOf(to) : 0;

        // Update Fenwick tree atomically with balance changes
        // All filtering (address(0), contracts, synthetic addresses) handled internally
        _updateCumulativeBalancesWithExplicitBalances(
            from,
            fromBalanceBefore,
            fromBalanceAfter
        );

        _updateCumulativeBalancesWithExplicitBalances(
            to,
            toBalanceBefore,
            toBalanceAfter
        );
    }

    /**
     * @dev Override update to apply fees on transfers
     */
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        // Redirect external transfers to this contract or LOT_POOL to FEES_POOL
        // This maintains the invariant: LOT_POOL balance == auction amount + unclaimed prizes
        if (to == address(this) || to == LOT_POOL) {
            _atomicUpdate(from, FEES_POOL, value);
            return;
        }

        // For minting and burning, use atomic update directly (no lottery trigger needed)
        if (from == address(0) || to == address(0)) {
            _atomicUpdate(from, to, value);
            return;
        }

        // Check and set max supply before any potential burns
        _checkAndSetMaxSupply();

        // Try to execute pending lottery/auction before transfers
        // This ensures Fenwick tree consistency and proper snapshot usage
        _tryExecuteLotteryAndAuction();

        // Apply fees for transfers
        uint256 fee = (value * FEE_PERCENT) / BASIS_POINTS;
        uint256 netAmount = value - fee;

        // Use atomic updates for both the transfer and fee
        // This ensures Fenwick tree consistency
        // For self-transfers, we still need to emit the Transfer event
        if (from == to) {
            // Self-transfer: enforce balance check since _atomicUpdate is skipped
            require(balanceOf(from) >= value, "Insufficient balance");
            emit Transfer(from, to, netAmount);
        } else {
            // Normal transfer: update balances and emit event via _atomicUpdate
            _atomicUpdate(from, to, netAmount);
        }

        // Transfer fees to fees pool atomically
        if (fee > 0) {
            _atomicUpdate(from, FEES_POOL, fee);
        }
    }

    /**
     * @dev Update a DualState with a new value, preserving history
     */
    function _updateDualState(
        DualState storage state,
        uint112 newValue,
        uint32 currentDay
    ) internal {
        if (state.lastUpdatedDay < currentDay) {
            // New day - shift current to older and set new value
            state.olderValue = state.latestValue;
            state.latestValue = newValue;
            state.lastUpdatedDay = currentDay;
        } else {
            // Same day - just update latest value
            state.latestValue = newValue;
        }
    }

    /**
     * @dev Update a DualAddress with a new value, preserving history
     */
    function _updateDualAddress(
        DualAddress storage state,
        address newValue,
        uint32 currentDay
    ) internal {
        if (state.lastUpdatedDay < currentDay) {
            // New day - shift current to older and set new value
            state.olderValue = state.latestValue;
            state.latestValue = newValue;
            state.lastUpdatedDay = currentDay;
        } else {
            // Same day - just update latest value
            state.latestValue = newValue;
        }
    }

    /**
     * @dev Get value from a DualState for a specific day
     */
    function _getDualStateValue(
        DualState memory state,
        uint32 targetDay
    ) internal pure returns (uint112) {
        if (state.lastUpdatedDay <= targetDay) {
            return state.latestValue;
        }
        return state.olderValue;
    }

    /**
     * @dev Get value from a DualAddress for a specific day
     */
    function _getDualAddressValue(
        DualAddress memory state,
        uint32 targetDay
    ) internal pure returns (address) {
        if (state.lastUpdatedDay <= targetDay) {
            return state.latestValue;
        }
        return state.olderValue;
    }

    /**
     * @dev Update Fenwick tree at index with delta (suffix sum version)
     * For suffix sums, we update positions whose range includes the index
     */
    function _fenwickUpdate(uint256 index, int256 delta) internal {
        uint32 currentDay = uint32(getCurrentDay());

        // Update all nodes whose suffix range includes this index
        // Start from index and move backward
        uint256 i = index;
        while (i > 0) {
            DualState storage treeNode = fenwickTree[i];
            uint112 currentSum = treeNode.latestValue;
            uint112 newSum;

            if (delta > 0) {
                newSum = currentSum + uint112(uint256(delta));
            } else {
                uint112 decrease = uint112(uint256(-delta));
                newSum = currentSum - decrease;
            }

            _updateDualState(treeNode, newSum, currentDay);

            // Move to previous node whose range includes our index
            // For suffix tree: move to i - lowbit(i)
            i -= i & uint256(-int256(i));
        }
    }

    /**
     * @dev Query suffix sum from index to end for a specific day
     * Goes upward using the current holder count as max
     */
    function _fenwickQuery(
        uint256 index,
        uint32 targetDay
    ) internal view returns (uint256) {
        uint256 sum = 0;
        uint112 maxIndex = _getDualStateValue(holderCount, targetDay);

        while (index <= maxIndex) {
            sum += _getDualStateValue(fenwickTree[index], targetDay);
            index += index & uint256(-int256(index)); // Move up the tree
        }
        return sum;
    }

    /**
     * @dev Update holder balance with explicit before/after balances
     */
    function _updateCumulativeBalancesWithExplicitBalances(
        address account,
        uint256 balanceBefore,
        uint256 balanceAfter
    ) internal {
        if (account == address(0)) return; // Skip zero address (minting/burning)
        if (account == LOT_POOL || account == FEES_POOL) return; // Skip synthetic addresses

        uint32 currentDay = uint32(getCurrentDay());
        uint256 currentIndex = indexByHolder[account].latestValue;

        // For contracts: only skip if they're not already in the tree
        // This prevents corruption from constructor bypass or CREATE2 pre-funding
        if (account.code.length > 0 && currentIndex == 0) return;

        int256 balanceChange = int256(balanceAfter) - int256(balanceBefore);

        if (balanceAfter > 0 && currentIndex == 0) {
            // Add new holder
            uint112 newCount = holderCount.latestValue + 1;
            uint112 newTotalBalance = totalHolderBalance.latestValue +
                uint112(balanceAfter);

            _updateDualState(holderCount, newCount, currentDay);
            _updateDualAddress(holderByIndex[newCount], account, currentDay);
            _updateDualState(
                indexByHolder[account],
                uint112(newCount),
                currentDay
            );

            // Update Fenwick tree
            _fenwickUpdate(newCount, int256(balanceAfter));

            _updateDualState(totalHolderBalance, newTotalBalance, currentDay);
        } else if (balanceAfter == 0 && currentIndex > 0) {
            // Remove holder - use the balance before removal
            uint112 currentTotalBalance = totalHolderBalance.latestValue;

            // Update Fenwick tree before removal
            _fenwickUpdate(currentIndex, -int256(balanceBefore));

            uint112 newTotalBalance = currentTotalBalance -
                uint112(balanceBefore);

            _updateDualState(totalHolderBalance, newTotalBalance, currentDay);

            // Compact holders by moving the last holder to the removed position
            uint112 currentCount = holderCount.latestValue;

            if (currentIndex < currentCount) {
                address lastHolder = holderByIndex[currentCount].latestValue;

                // Get the last holder's balance from the Fenwick tree at their position
                // This is their balance BEFORE any concurrent updates
                uint112 lastHolderFenwickBalance = fenwickTree[currentCount]
                    .latestValue;

                // Remove last holder's balance from old position
                _fenwickUpdate(
                    currentCount,
                    -int256(uint256(lastHolderFenwickBalance))
                );

                // Move last holder to current position
                _updateDualAddress(
                    holderByIndex[currentIndex],
                    lastHolder,
                    currentDay
                );
                _updateDualState(
                    indexByHolder[lastHolder],
                    uint112(currentIndex),
                    currentDay
                );

                // Add last holder's balance to new position
                _fenwickUpdate(
                    currentIndex,
                    int256(uint256(lastHolderFenwickBalance))
                );
            }

            // Clear the removed holder's index and last position
            _updateDualState(indexByHolder[account], 0, currentDay);
            _updateDualAddress(
                holderByIndex[currentCount],
                address(0),
                currentDay
            );

            // Decrement holder count
            _updateDualState(holderCount, currentCount - 1, currentDay);
        } else if (currentIndex > 0) {
            // Update existing holder
            // Update Fenwick tree with the difference
            _fenwickUpdate(currentIndex, balanceChange);

            uint112 currentTotalBalance = totalHolderBalance.latestValue;
            uint112 newTotalBalance;

            if (balanceChange > 0) {
                newTotalBalance =
                    currentTotalBalance +
                    uint112(uint256(balanceChange));
            } else {
                uint112 decrease = uint112(uint256(-balanceChange));
                newTotalBalance = currentTotalBalance > decrease
                    ? currentTotalBalance - decrease
                    : 0;
            }

            _updateDualState(totalHolderBalance, newTotalBalance, currentDay);
        }
    }

    /**
     * @dev Internal function to try executing pending lottery and auction
     * Called before state-changing operations to ensure winners are determined first
     */
    function _tryExecuteLotteryAndAuction() internal {
        uint256 currentDay = getCurrentDay();

        // No lottery/auction until day 1 (need previous day's fees)
        if (currentDay < 1) return;

        // If day changed since last lottery, we have a pending lottery/auction
        if (currentDay <= lastLotteryDay) return;

        // Ensure we're at least 1 minute into the new day to prevent manipulation
        uint256 timeIntoDay = (block.timestamp - deploymentTime) % 25 hours;
        if (timeIntoDay < TIME_GAP) return;

        // Get all accumulated fees from FEES_POOL
        uint256 feesToDistribute = balanceOf(FEES_POOL);

        // Skip lottery/auction for dust amounts
        // This ensures both lottery and auction get meaningful amounts when split
        if (feesToDistribute < MIN_FEES_FOR_DISTRIBUTION) return;

        // Split fees between lottery and auction based on LOTTERY_PERCENT
        uint256 lotteryShare = (feesToDistribute * LOTTERY_PERCENT) / 100;
        uint256 auctionShare = feesToDistribute - lotteryShare;
        emit FeesDistributed(currentDay - 1, lotteryShare, auctionShare);
        _executeLotteryInternal(lotteryShare);
        _startAuction(auctionShare);
    }

    /**
     * @dev Internal lottery execution logic
     */
    function _executeLotteryInternal(uint256 feesToDistribute) internal {
        uint256 randomSeed = block.prevrandao;
        uint256 currentDay = getCurrentDay();

        // Use snapshot from previous day (when fees were collected)
        uint32 snapshotDay = uint32(currentDay - 1);

        // Get holder count and total balance from the snapshot day
        uint112 snapshotHolderCount = _getDualStateValue(
            holderCount,
            snapshotDay
        );
        uint112 snapshotTotalBalance = _getDualStateValue(
            totalHolderBalance,
            snapshotDay
        );

        // Select winner if there are holders
        if (snapshotHolderCount > 0 && snapshotTotalBalance > 0) {
            address winner = _selectWinnerEfficient(snapshotDay, randomSeed);

            uint256 lotteryDay = currentDay - 1; // The day whose fees we're distributing
            uint256 slot = lotteryDay % 7; // Use 7 slots for lottery prizes

            // Transfer prize from fees pool to lottery pool for holding
            _atomicUpdate(FEES_POOL, LOT_POOL, feesToDistribute);

            // Check if this slot has an unclaimed lottery prize
            UnclaimedPrize storage prize = lotteryUnclaimedPrizes[slot];
            if (prize.amount > 0) {
                emit UnclaimedPrizeExpired(prize.winner, prize.amount, lotteryDay, slot, true);

                // Try to redeem USDmore for USDmY and send to owner
                address beneficiary = owner();

                // Calculate USDmY value of the USDmore prizeToSend
                // USDmY amount = (USDmore amount * USDmY reserve) / total supply
                uint256 collateralToSend = (uint256(prize.amount) *
                    getReserve()) / totalSupply();

                // Attempt to send USDmY to beneficiary using low-level call
                // This handles both standard and non-standard ERC20 implementations
                (bool success, bytes memory data) = USDMY.call(
                    abi.encodeCall(
                        IERC20.transfer,
                        (beneficiary, collateralToSend)
                    )
                );
                success =
                    success &&
                    (data.length == 0 || abi.decode(data, (bool)));

                if (success) {
                    // USDmY transfer successful, now burn the USDmore tokens from lottery pool
                    _burn(LOT_POOL, prize.amount);
                    emit BeneficiaryFunded(
                        beneficiary,
                        collateralToSend, // Emit the actual USDmY amount sent
                        prize.winner
                    );
                } else {
                    // USDmY transfer failed, add unclaimed prize to current winner's prize
                    // The current winner will get both prizes when they claim
                    feesToDistribute += prize.amount;
                }
            }

            // Store new prize in the slot (overwriting any previous data)
            prize.winner = winner;
            prize.amount = uint112(feesToDistribute); // Store USDmore amount as prize

            emit LotteryWon(winner, feesToDistribute, lotteryDay);
        }

        // Update last lottery day
        lastLotteryDay = uint32(currentDay);
    }

    /**
     * @dev Public function to execute daily lottery
     */
    function executeLottery() external nonReentrant {
        uint256 currentDay = getCurrentDay();
        require(
            currentDay >= 1,
            "Must wait until day 1 for first lottery/auction"
        );

        require(
            currentDay > lastLotteryDay,
            "No pending lottery/auction (same day)"
        );

        // Check and set max supply before any potential burns
        _checkAndSetMaxSupply();

        // Ensure we're at least 1 minute into the new day
        uint256 timeIntoDay = (block.timestamp - deploymentTime) % 25 hours;
        require(
            timeIntoDay >= TIME_GAP,
            "Must wait 1 minute into new day before executing"
        );

        // Get all accumulated fees from FEES_POOL
        uint256 feesToDistribute = balanceOf(FEES_POOL);
        require(
            feesToDistribute >= MIN_FEES_FOR_DISTRIBUTION,
            "Insufficient fees to distribute"
        );

        // Split fees between lottery and auction based on LOTTERY_PERCENT
        uint256 lotteryShare = (feesToDistribute * LOTTERY_PERCENT) / 100;
        uint256 auctionShare = feesToDistribute - lotteryShare;
        emit FeesDistributed(currentDay - 1, lotteryShare, auctionShare);
        _executeLotteryInternal(lotteryShare);
        _startAuction(auctionShare);
    }

    /**
     * @dev Claim unclaimed prizes for the caller
     */
    function claim() external nonReentrant {
        // Check and set max supply before any transfers
        _checkAndSetMaxSupply();

        uint256 totalClaimed = 0;

        // Check all 7 slots for both lottery and auction prizes in a single loop
        for (uint256 i = 0; i < 7; i++) {
            // Check lottery prizes
            if (
                lotteryUnclaimedPrizes[i].winner == msg.sender &&
                lotteryUnclaimedPrizes[i].amount > 0
            ) {
                uint256 prizeAmount = lotteryUnclaimedPrizes[i].amount;
                totalClaimed += prizeAmount;

                // Clear the slot
                lotteryUnclaimedPrizes[i].winner = address(0);
                lotteryUnclaimedPrizes[i].amount = 0;

                emit PrizeClaimed(msg.sender, prizeAmount);
            }

            // Check auction prizes
            if (
                auctionUnclaimedPrizes[i].winner == msg.sender &&
                auctionUnclaimedPrizes[i].amount > 0
            ) {
                uint256 prizeAmount = auctionUnclaimedPrizes[i].amount;
                totalClaimed += prizeAmount;

                // Clear the slot
                auctionUnclaimedPrizes[i].winner = address(0);
                auctionUnclaimedPrizes[i].amount = 0;

                emit PrizeClaimed(msg.sender, prizeAmount);
            }
        }

        require(totalClaimed > 0, "No prizes to claim");

        // Transfer all claimed prizes at once from lottery pool
        // _atomicUpdate handles Fenwick tree updates automatically
        _atomicUpdate(LOT_POOL, msg.sender, totalClaimed);
    }

    /**
     * @dev Efficient winner selection using binary search on Fenwick tree (suffix sum version)
     */
    function _selectWinnerEfficient(
        uint32 lotteryDay,
        uint256 randomSeed
    ) internal view returns (address) {
        uint112 snapshotTotalBalance = _getDualStateValue(
            totalHolderBalance,
            lotteryDay
        );
        uint112 snapshotHolderCount = _getDualStateValue(
            holderCount,
            lotteryDay
        );

        // Random number from 1 to total balance
        uint256 winningNumber = (randomSeed % snapshotTotalBalance) + 1;

        // With suffix sums, we want to find the largest index where suffix sum >= winningNumber
        // Since suffix sum decreases as index increases, we search for the transition point
        uint256 left = 1;
        uint256 right = snapshotHolderCount;

        while (left < right) {
            uint256 mid = (left + right + 1) / 2; // Round up to avoid infinite loop
            uint256 suffixSum = _fenwickQuery(mid, lotteryDay);

            if (suffixSum >= winningNumber) {
                // This holder or later could be the winner, try higher index
                left = mid;
            } else {
                // Suffix sum too small, need earlier holder
                right = mid - 1;
            }
        }

        return _getDualAddressValue(holderByIndex[left], lotteryDay);
    }

    /**
     * @dev Get current day number
     * We use 25-hour "pseudo-days" instead of 24-hour days so that over time,
     * the daily lottery/auction transitions happen at different hours of the day.
     * This gives participants from all time zones equal opportunities to participate
     * in the beginning and end of each cycle, preventing any geographic advantage.
     */
    function getCurrentDay() public view returns (uint256) {
        return (block.timestamp - deploymentTime) / 25 hours;
    }

    /**
     * @dev Get holder count (latest value)
     */
    function getHolderCount() external view returns (uint256) {
        return holderCount.latestValue;
    }

    /**
     * @dev Get holder info by index (1-indexed for Fenwick tree)
     */
    function getHolderByIndex(
        uint256 index
    ) external view returns (address holder, uint256 balance) {
        require(
            index > 0 && index <= holderCount.latestValue,
            "Index out of bounds"
        );
        address holderAddress = holderByIndex[index].latestValue;
        return (holderAddress, balanceOf(holderAddress));
    }

    /**
     * @dev Get current lottery pool balance
     */
    function currentLotteryPool() external view returns (uint256) {
        return balanceOf(LOT_POOL);
    }

    /**
     * @dev Check if an address is a holder
     */
    function isHolder(address account) external view returns (bool) {
        return indexByHolder[account].latestValue > 0;
    }

    /**
     * @dev Debug function to get Fenwick tree value at index (for testing)
     */
    function getFenwickValue(uint256 index) external view returns (uint256) {
        return fenwickTree[index].latestValue;
    }

    /**
     * @dev Debug function to get suffix sum from index to end (for testing)
     */
    function getSuffixSum(uint256 index) external view returns (uint256) {
        return _fenwickQuery(index, uint32(getCurrentDay()));
    }

    /**
     * @dev Get claimable amount for the caller
     */
    function getMyClaimableAmount() external view returns (uint256 total) {
        // Check both lottery and auction prizes in a single loop
        for (uint256 i = 0; i < 7; i++) {
            if (lotteryUnclaimedPrizes[i].winner == msg.sender) {
                total += lotteryUnclaimedPrizes[i].amount;
            }
            if (auctionUnclaimedPrizes[i].winner == msg.sender) {
                total += auctionUnclaimedPrizes[i].amount;
            }
        }
    }

    /**
     * @dev Get all unclaimed prizes (both lottery and auction)
     */
    function getAllUnclaimedPrizes()
        external
        view
        returns (
            address[7] memory lotteryWinners,
            uint112[7] memory lotteryAmounts,
            address[7] memory auctionWinners,
            uint112[7] memory auctionAmounts
        )
    {
        for (uint256 i = 0; i < 7; i++) {
            lotteryWinners[i] = lotteryUnclaimedPrizes[i].winner;
            lotteryAmounts[i] = lotteryUnclaimedPrizes[i].amount;
            auctionWinners[i] = auctionUnclaimedPrizes[i].winner;
            auctionAmounts[i] = auctionUnclaimedPrizes[i].amount;
        }
    }

    /**
     * @dev Start an auction for the previous day's fees
     */
    function _startAuction(uint256 feesToDistribute) internal {
        uint256 currentDay = getCurrentDay();

        // Finalize previous auction if it exists
        if (currentAuction.auctionTokens != 0) {
            _finalizeAuction();
        }

        // Calculate minimum bid for the USDmore amount being auctioned
        // MinBid = (USDmY reserve * feesToDistribute) / (2 * totalSupply)
        // This sets the minimum bid at 50% of the redemption value
        // Overflow safety: reserve < 2^96, feesToDistribute < 2^112, product < 2^208
        uint256 minBid = (getReserve() * feesToDistribute) /
            (2 * totalSupply());

        // Transfer fees from fees pool to lottery pool for auction
        _atomicUpdate(FEES_POOL, LOT_POOL, feesToDistribute);

        // Start new auction
        currentAuction = Auction({
            currentBidder: address(0),
            currentBid: 0,
            minBid: minBid.toUint96(),
            auctionTokens: feesToDistribute.toUint112(),
            auctionDay: uint32(currentDay - 1) // Day whose fees we're auctioning
        });

        emit AuctionStarted(currentDay - 1, feesToDistribute, minBid);

        // Update last lottery day (even though it's an auction, we use same tracking)
        lastLotteryDay = uint32(currentDay);
    }

    /**
     * @dev Finalize the current auction
     */
    function _finalizeAuction() internal {
        // If no bids, roll over the fees to the next day
        if (currentAuction.currentBidder == address(0)) {
            if (currentAuction.auctionTokens > 0) {
                // Add unclaimed auction amount back to fees pool for next distribution
                _atomicUpdate(
                    LOT_POOL,
                    FEES_POOL,
                    currentAuction.auctionTokens
                );
                emit AuctionNoBids(currentAuction.auctionDay, currentAuction.auctionTokens);
            }
            return;
        }

        uint256 slot = currentAuction.auctionDay % 7; // Use 7 slots for auction prizes

        // Check if this slot has an unclaimed auction prize
        UnclaimedPrize storage prize = auctionUnclaimedPrizes[slot];
        if (prize.amount > 0) {
            emit UnclaimedPrizeExpired(prize.winner, prize.amount, currentAuction.auctionDay, slot, false);

            // Try to send to owner
            address beneficiary = owner();

            // Calculate USDmY value of the USDmore prize
            // USDmY amount = (USDmore amount * USDmY reserve) / total supply
            uint256 collateralToSend = (uint256(prize.amount) *
                getReserve()) / totalSupply();

            // Attempt to send USDmY to beneficiary using low-level call
            // This handles both standard and non-standard ERC20 implementations
            (bool success, bytes memory data) = USDMY.call(
                abi.encodeCall(IERC20.transfer, (beneficiary, collateralToSend))
            );
            success = success && (data.length == 0 || abi.decode(data, (bool)));

            if (success) {
                _burn(LOT_POOL, prize.amount);
                emit BeneficiaryFunded(
                    beneficiary,
                    collateralToSend,
                    prize.winner
                ); // Emit actual USDmY amount
            } else {
                // Add to current winner's prize
                currentAuction.auctionTokens += uint112(prize.amount);
            }
        }

        // Move bid USDmY from escrow to reserve (accounting change only)
        // The USDmY tokens are already in the contract, just reclassifying them
        escrowedBid -= currentAuction.currentBid;

        // Store new prize
        prize.winner = currentAuction.currentBidder;
        prize.amount = currentAuction.auctionTokens;

        emit AuctionWon(
            currentAuction.currentBidder,
            currentAuction.auctionTokens,
            currentAuction.currentBid,
            currentAuction.auctionDay
        );
    }

    /**
     * @dev Place a bid in the current auction
     * The bidder must have approved USDmY for at least 10% higher than the current bid
     * Winning bid gets the auctioned USDmore tokens
     * Previous bidder gets their USDmY refunded immediately
     *
     * We enforce a 10% minimum increment to make auctions more accessible to non-bot participants.
     * Since token prices rarely change by 10% in a single day, this creates a window where
     * early bidders can speculate on the value without being immediately outbid by bots
     * that might otherwise place marginally higher bids repeatedly.
     *
     * @param bidAmount Amount of USDmY to bid (requires prior approval)
     */
    function bid(uint256 bidAmount) external nonReentrant {
        IERC20(USDMY).safeTransferFrom(msg.sender, address(this), bidAmount);
        _bidCore(bidAmount);
    }

    /**
     * @dev Place a bid using USDm (converted to USDmY automatically)
     * Refunds for outbid bidders are always in USDmY.
     * @param usdmAmount Amount of USDm to bid (requires prior approval)
     */
    function bidWithUSDm(uint256 usdmAmount) external nonReentrant {
        uint256 sharesReceived = _depositUSDmForUSDmY(usdmAmount);
        _bidCore(sharesReceived);
    }

    /**
     * @dev Core bid logic shared by bid() and bidWithUSDm()
     * @param bidAmount Amount of USDmY already in the contract to bid
     */
    function _bidCore(uint256 bidAmount) internal {
        require(currentAuction.auctionTokens != 0, "No active auction");

        _checkAndSetMaxSupply();

        uint256 currentDay = getCurrentDay();

        // Check if auction is still active (same day)
        require(currentDay == lastLotteryDay, "Auction has ended");

        // Determine minimum bid required
        uint256 minBid = currentAuction.currentBid == 0
            ? currentAuction.minBid // Use stored minimum for first bid
            : (currentAuction.currentBid * 110) / 100; // 10% increase for subsequent bids

        require(bidAmount >= minBid, "Bid too low");

        // Track as escrowed (not part of reserve until auction finalizes)
        escrowedBid += bidAmount;

        // Store previous bidder info
        address previousBidder = currentAuction.currentBidder;
        uint256 previousBid = currentAuction.currentBid;

        // Update auction state
        currentAuction.currentBidder = msg.sender;
        currentAuction.currentBid = bidAmount.toUint96();

        emit BidPlaced(msg.sender, bidAmount, currentAuction.auctionDay);

        // Refund previous bidder if exists (always in USDmY)
        if (previousBidder != address(0)) {
            escrowedBid -= previousBid;
            IERC20(USDMY).safeTransfer(previousBidder, previousBid);
            emit BidRefunded(previousBidder, previousBid);
        }
    }
}
