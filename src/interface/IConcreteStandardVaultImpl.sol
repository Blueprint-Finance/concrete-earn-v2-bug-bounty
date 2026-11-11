// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IUpgradeableVault} from "./IUpgradeableVault.sol";
import {IHurdleRateOracle} from "./IHurdleRateOracle.sol";
import {Hooks} from "./IHook.sol";
import {IERC4626} from "@openzeppelin-contracts/interfaces/IERC4626.sol";
import {IAccessControlEnumerable} from "@openzeppelin-contracts/access/extensions/IAccessControlEnumerable.sol";
import {ITimelockProtected} from "./ITimelockProtected.sol";

/**
 * @title IConcreteStandardVaultImpl
 * @dev Interface for the standard vault implementation that manages multiple investment strategies.
 * @dev This interface extends the base tokenized vault functionality with strategy management capabilities.
 * @dev Strategies are external contracts that implement the IStrategyTemplate interface and handle
 * fund allocation to different yield-generating protocols or investment opportunities.
 */
interface IConcreteStandardVaultImpl is IUpgradeableVault, IERC4626, IAccessControlEnumerable, ITimelockProtected {
    /**
     * @dev Thrown when attempting to withdraw to the zero address.
     */
    error InvalidReceiver();

    /**
     * @dev Thrown when attempting to sweep the vault share token itself. On async vaults the
     *      share token is the vault (`address(this)`) and holds shares escrowed for queued
     *      withdrawal requests; sweeping it would drain that escrow and break cancellation/settlement.
     */
    error CannotSweepShareToken();

    /**
     * @dev Thrown when attempting to add a strategy that uses a different asset than the vault.
     */
    error InvalidStrategyAsset();

    /**
     * @dev Thrown when attempting to add a strategy that is bound to a different vault.
     */
    error InvalidStrategyVault();

    /**
     * @dev Thrown when attempting to add a strategy that has already been added to the vault.
     */
    error StrategyAlreadyAdded();

    /**
     * @dev Thrown when attempting to operate on a strategy that doesn't exist in the vault.
     */
    error StrategyDoesNotExist();

    /**
     * @dev Thrown when attempting to interact with a strategy that is halted.
     */
    error StrategyIsHalted();

    /**
     * @dev Thrown when attempting to halt a strategy that is already halted.
     */
    error StrategyAlreadyHalted();

    /**
     * @dev Thrown when attempting to toggle the status of an inactive strategy.
     */
    error CannotToggleInactiveStrategy();

    /**
     * @dev Thrown when attempting to set a management fee without setting a recipient first.
     */
    error FeeRecipientNotSet();

    /**
     * @dev Thrown when attempting to set a management fee that exceeds the maximum allowed.
     */
    error ManagementFeeExceedsMaximum();

    /**
     * @dev Thrown when attempting to set a performance fee that exceeds the maximum allowed.
     */
    error PerformanceFeeExceedsMaximum();

    /**
     * @dev Thrown when attempting to set an invalid fee recipient address (address(0)).
     */
    error InvalidFeeRecipient();

    /**
     * @dev Thrown when the allocate module is invalid.
     */
    error InvalidAllocateModule();

    /**
     * @dev Thrown when the asset is invalid.
     */
    error InvalidAsset();

    /**
     * @dev Thrown when the initial vault manager is invalid.
     */
    error InvalidInitialVaultManager();

    /**
     * @dev Thrown when the name is invalid.
     */
    error InvalidName();

    /**
     * @dev Thrown when the symbol is invalid.
     */
    error InvalidSymbol();

    /**
     * @dev Thrown when the deposit limits are invalid.
     */
    error InvalidDepositLimits();

    /**
     * @dev Thrown when the withdraw limits are invalid.
     */
    error InvalidWithdrawLimits();

    /**
     * @dev Thrown when a hook's vault() does not match this vault.
     */
    error InvalidHookVault(address hook);

    /**
     *
     *
     *
     * @dev Thrown when the minimum deposit amount per transaction is not met.
     */
    error MinimumDepositAmountNotMet(address sender, uint256 assets, uint256 minTxDepositAmount);

    /**
     * @dev Thrown when the minimum withdraw amount per transaction is not met.
     */
    error MinimumWithdrawAmountNotMet(address sender, uint256 assets, uint256 minTxWithdrawAmount);

    /**
     * @dev Thrown when attempting to remove a strategy that has allocation or is in the deallocation order.
     */
    error StrategyHasAllocation();
    error StaleDeallocationOrder(address strategy);

    /**
     * @dev Thrown when a Halted-only reconciliation action is attempted on a strategy that is not Halted.
     */
    error StrategyNotHalted();

    /**
     * @dev Thrown when a reconciliation action requires a strategy with a non-zero allocation.
     */
    error StrategyHasNoAllocation();

    /**
     * @dev Thrown when the vault has insufficient balance to process the epoch.
     */
    error InsufficientBalance();

    /**
     * @dev Thrown when there are insufficient withdrawable assets available across all strategies.
     * @param requested The amount of assets requested for withdrawal.
     * @param available The total amount of assets available for withdrawal (idle + withdrawable from strategies).
     */
    error InsufficientWithdrawableAssets(uint256 requested, uint256 available);

    /**
     * @dev Thrown when calculated shares are zero.
     */
    error InsufficientShares();

    /**
     * @dev Thrown when calculated assets are zero.
     */
    error InsufficientAssets();

    /// @notice Thrown when renounceOwnership is called — permanently disabled.
    error RenounceOwnershipDisabled();

    /// @notice Thrown when removing a ROLE_ADMIN would leave the vault with no admins.
    /// @dev The last remaining ROLE_ADMIN cannot revoke or renounce its own admin role.
    error CannotRemoveLastRoleAdmin();

    /**
     * @dev Emitted when a new strategy is successfully added to the vault.
     * @param strategy The address of the strategy contract that was added.
     */
    event StrategyAdded(address strategy);

    /**
     * @dev Emitted when a strategy is successfully removed from the vault.
     * @param strategy The address of the strategy contract that was removed.
     */
    event StrategyRemoved(address strategy);

    /**
     * @dev Emitted when a Halted strategy's frozen allocation is realized as a loss and the
     *      strategy is removed. `cachedTotalAssets` is decreased by `loss`.
     * @param strategy The Halted strategy whose allocation was written down.
     * @param loss The amount written off from `cachedTotalAssets` (equals the prior allocation).
     */
    event StrategyLossRealized(address indexed strategy, uint256 loss);

    /**
     * @dev Emitted when a Halted strategy's allocation is migrated to an Active strategy and the
     *      Halted strategy is removed. `cachedTotalAssets` and the aggregate allocation are unchanged;
     *      any real shortfall is reconciled by the next yield accrual on the destination strategy.
     * @param fromStrategy The Halted strategy whose allocation was migrated away.
     * @param toStrategy The Active strategy that received the migrated allocation.
     * @param amount The allocation amount moved from `fromStrategy` to `toStrategy`.
     */
    event StrategyAllocationMigrated(address indexed fromStrategy, address indexed toStrategy, uint256 amount);

    /**
     * @dev Emitted when a strategy is set to Halted status.
     * @param strategy The address of the strategy contract that was halted.
     */
    event StrategyHalted(address strategy);

    /**
     * @dev Emitted when a strategy's status is toggled between Active and Halted.
     * @param strategy The address of the strategy contract whose status was toggled.
     */
    event StrategyStatusToggled(address indexed strategy);

    /**
     * @dev Emitted when the yield accrual operation is completed across all strategies.
     *
     * @param totalPositiveYield The total amount of positive yield generated across all strategies.
     * @param totalNegativeYield The total amount of losses incurred across all strategies.
     */
    event YieldAccrued(uint256 totalPositiveYield, uint256 totalNegativeYield);

    /**
     * @dev Emitted when management fee is accrued.
     * @param recipient The address that received the management fee shares.
     * @param shares The number of shares minted as management fee.
     * @param feeAmount The asset value of the management fee.
     */
    event ManagementFeeAccrued(address indexed recipient, uint256 shares, uint256 feeAmount);

    /**
     * @dev Emitted when performance fee is accrued.
     * @param recipient The address that received the performance fee shares.
     * @param shares The number of shares minted as performance fee.
     * @param feeAmount The asset value of the performance fee.
     */
    event PerformanceFeeAccrued(address indexed recipient, uint256 shares, uint256 feeAmount);

    /**
     * @dev Emitted when management fee is updated.
     * @param managementFee The new management fee rate in basis points.
     */
    event ManagementFeeUpdated(uint16 managementFee);

    /**
     * @dev Emitted when management fee recipient is updated.
     * @param managementFeeRecipient The new management fee recipient address.
     */
    event ManagementFeeRecipientUpdated(address managementFeeRecipient);

    /**
     * @dev Emitted when performance fee is updated.
     * @param performanceFee The new performance fee rate in basis points.
     */
    event PerformanceFeeUpdated(uint16 performanceFee);

    /**
     * @dev Emitted when performance fee recipient is updated.
     * @param performanceFeeRecipient The new performance fee recipient address.
     */
    event PerformanceFeeRecipientUpdated(address performanceFeeRecipient);

    /**
     * @dev Emitted when the hurdle rate oracle is updated.
     * @param oracle The new hurdle rate oracle address (address(0) disables hurdle gating).
     */
    event HurdleRateOracleUpdated(address indexed oracle);

    /**
     * @dev Emitted when deposit limits are updated.
     * @param maxGlobalDepositAmount The new maximum global deposit amount (applies to total assets across all users).
     * @param minTxDepositAmount The new minimum deposit amount per transaction.
     */
    event DepositLimitsUpdated(uint256 maxGlobalDepositAmount, uint256 minTxDepositAmount);

    /**
     * @dev Emitted when withdraw limits are updated.
     * @param maxTxWithdrawAmount The new maximum withdraw amount per transaction.
     * @param minTxWithdrawAmount The new minimum withdraw amount per transaction.
     */
    event WithdrawLimitsUpdated(uint256 maxTxWithdrawAmount, uint256 minTxWithdrawAmount);

    /**
     * @dev Emitted when the deallocation order is updated.
     */
    event DeallocationOrderUpdated();

    /**
     * @dev Emitted when the hooks are set.
     * @param hooks The new hooks.
     */
    event HooksSet(Hooks hooks);

    /**
     * @dev Emitted when an individual strategy's yield is accrued.
     *
     * @param strategy The address of the strategy contract whose yield was accrued.
     * @param currentTotalAllocatedValue The current total allocated value reported by the strategy.
     * @param yield The amount of positive yield generated by this strategy since last accrual.
     * @param loss The amount of loss incurred by this strategy since last accrual.
     */
    event StrategyYieldAccrued(
        address indexed strategy, uint256 currentTotalAllocatedValue, uint256 yield, uint256 loss
    );

    /**
     * @dev Enumeration of vault-manager–configurable parameters.
     * Used by {configure} to dispatch to the correct setter in a single call.
     */
    enum VaultManagerConfig {
        ManagementFee,
        PerformanceFee,
        HurdleRateOracle,
        DepositLimits,
        WithdrawLimits,
        CancellationEnabled
    }

    error InvalidVaultManagerConfig();

    /**
     * @dev Enumeration of possible strategy statuses within the vault.
     * @dev Inactive: Strategy is inactive and cannot receive new allocations.
     * @dev Active: Strategy is active and can receive allocations and process withdrawals normally.
     * @dev Halted: Strategy is halted, typically due to detected issues or failures.
     * In this state the strategy is skipped by yield accrual and withdrawals. A Halted strategy that
     * still has allocated funds cannot be removed directly; its position must first be reconciled via
     * {reconcileHaltedStrategy}: pass a `toStrategy` to migrate the position onto an Active strategy,
     * or pass `address(0)` to write the position off as a loss.
     */
    enum StrategyStatus {
        Inactive,
        Active,
        Halted
    }

    /**
     * @dev Structure containing metadata and state information for each strategy.
     * @dev status: Current operational status of the strategy.
     * @dev allocated: Total amount of vault assets currently allocated to this strategy, denominated in the vault's underlying asset token.
     */
    struct StrategyData {
        StrategyStatus status;
        uint120 allocated;
    }

    /**
     * @dev Adds a new strategy to the vault.
     * @dev The strategy must implement the IStrategyTemplate interface and use the same underlying asset as the vault.
     * @dev Only callable by accounts with the STRATEGY_MANAGER role.
     *
     * @param strategy The address of the strategy contract to add.
     *
     * Requirements:
     * - The strategy's asset() must match the vault's asset()
     * - The strategy must not already be added to the vault
     * - Caller must have STRATEGY_MANAGER role
     *
     * Emits:
     * - StrategyAdded event
     *
     * Reverts:
     * - InvalidStrategyAsset if strategy uses different asset
     * - StrategyAlreadyAdded if strategy is already in the vault
     */
    function addStrategy(address strategy) external;

    /**
     * @dev Removes a strategy from the vault.
     * @dev The strategy can only be removed if it has zero allocated funds and is not in the
     *      deallocation order. A Halted strategy that still holds an allocation must first be
     *      reconciled via {reconcileHaltedStrategy}.
     * @dev Only callable by accounts with the STRATEGY_MANAGER role.
     *
     * @param strategy The address of the strategy contract to remove.
     *
     * Requirements:
     * - Strategy must exist in the vault
     * - Strategy must have zero allocated funds and not be in the deallocation order
     * - Caller must have STRATEGY_MANAGER role
     *
     * Emits:
     * - StrategyRemoved event
     *
     * Reverts:
     * - StrategyDoesNotExist if strategy is not in the vault
     * - StrategyHasAllocation if strategy has allocated funds or is in the deallocation order
     */
    function removeStrategy(address strategy) external;

    /**
     * @dev Reconciles the frozen allocation of a Halted strategy and removes it. The behaviour
     *      depends on `toStrategy`:
     *      - `address(0)` (realize loss): `cachedTotalAssets` is decreased by the strategy's
     *        `allocated` and the per-strategy `allocated` is cleared. Use when the position is
     *        unrecoverable and there is no successor strategy.
     *      - non-zero (migrate): the allocation is moved onto an Active `toStrategy`.
     *        `cachedTotalAssets` and the aggregate allocation are preserved, so the next yield
     *        accrual on the destination reconciles any real shortfall as a loss (or none, if the
     *        position was fully recovered). The physical assets must be moved from the old strategy
     *        to the new one out of band.
     *      In both cases the derived floating amount stays exact (no phantom funds).
     * @dev Only callable by accounts with the STRATEGY_MANAGER role.
     *
     * @param fromStrategy The Halted strategy whose allocation will be reconciled and removed.
     * @param toStrategy   The Active strategy that receives the migrated allocation, or
     *                     `address(0)` to write the position off as a loss.
     *
     * Requirements:
     * - fromStrategy must exist in the vault, be Halted and have a non-zero allocation
     * - When migrating, toStrategy must exist in the vault and be Active
     * - Caller must have STRATEGY_MANAGER role
     *
     * Emits:
     * - StrategyLossRealized (loss branch) or StrategyAllocationMigrated (migrate branch),
     *   plus StrategyRemoved
     *
     * Reverts:
     * - StrategyDoesNotExist if fromStrategy (or, when migrating, toStrategy) is not in the vault
     * - StrategyNotHalted if fromStrategy is not Halted
     * - StrategyHasNoAllocation if fromStrategy has zero allocation
     * - StrategyIsHalted if a non-zero toStrategy is not Active
     */
    function reconcileHaltedStrategy(address fromStrategy, address toStrategy) external;

    /**
     * @dev Toggles a strategy's status between Active and Halted.
     * @dev This is a safety mechanism to isolate problematic strategies or reactivate previously halted ones.
     * @dev Active strategies can receive allocations and participate in yield accrual and withdrawal operations.
     * @dev Halted strategies are skipped during yield accrual and withdrawal operations.
     * @dev Only callable by accounts with the STRATEGY_MANAGER role.
     *
     * @param strategy The address of the strategy contract to toggle.
     *
     * Requirements:
     * - Strategy must exist in the vault
     * - Strategy must be either Active or Halted (cannot toggle Inactive strategies)
     * - Caller must have STRATEGY_MANAGER role
     *
     * Emits:
     * - StrategyStatusToggled event
     *
     * Reverts:
     * - StrategyDoesNotExist if strategy is not in the vault
     */
    function toggleStrategyStatus(address strategy) external;

    /**
     * @notice Executes fund allocation and deallocation operations across multiple strategies.
     * @dev This function performs a yield accrual operation first to update vault accounting,
     *      then executes the allocation operations specified in the data parameter.
     * @dev All operations are performed via delegatecall to the respective modules to maintain
     *      proper storage context and access control.
     * @param data ABI-encoded array of AllocateParams structures containing the allocation
     *             operations to execute. Each param specifies whether to allocate or deallocate
     *             funds, which strategy to use, and any additional data required by the strategy.
     * @dev Only callable by accounts with the ALLOCATOR role.
     * @dev The function automatically triggers yield accrual before allocation to ensure
     *         accurate vault accounting prior to fund movements.
     */
    function allocate(bytes calldata data) external;

    /**
     * @notice Accrues yield and accounts for losses across all active strategies in the vault.
     * @dev This function updates the vault's internal accounting by querying the current
     *      value of all strategy allocations and calculating net yield or losses.
     * @dev Only callable by accounts with the ALLOCATOR role, and only while the vault is not paused.
     *      Yield is also accrued automatically before user and admin operations (`withYieldAccrual`).
     * @dev The yield accrual operation does not trigger actual fund movements, it only
     *         updates the vault's internal state to reflect current strategy values.
     */
    function accrueYield() external;

    /**
     * @notice Generic vault-manager setter that dispatches based on `configType`.
     * @dev Only callable by accounts with VAULT_MANAGER role.
     *      Applies nonReentrant + withYieldAccrual guards once for all config types.
     * @param configType The parameter to configure (see {VaultManagerConfig}).
     * @param data ABI-encoded value(s) for the chosen config type:
     *   - ManagementFee:    abi.encode(uint16 fee)
     *   - PerformanceFee:   abi.encode(uint16 fee)
     *   - HurdleRateOracle: abi.encode(IHurdleRateOracle oracle)
     *   - DepositLimits:    abi.encode(uint256 minTxDeposit, uint256 maxGlobalDeposit)
     *   - WithdrawLimits:   abi.encode(uint256 minTxWithdraw, uint256 maxTxWithdraw)
     *   - CancellationEnabled: abi.encode(bool enabled) (async vaults only)
     */
    function configure(VaultManagerConfig configType, bytes calldata data) external;

    /**
     * @notice Get whether users can cancel pending withdrawal requests.
     * @dev Standard (synchronous) vaults have no cancellation flow and always return false.
     *      Async vaults override this: defaults to true and can be toggled via {configure}
     *      with {VaultManagerConfig.CancellationEnabled}. Exposed on the base interface so
     *      hooks can query cancellation support through a single unconditional call.
     * @return True if cancellation is enabled, false if cancelRequest is blocked or unsupported.
     */
    function cancellationEnabled() external view returns (bool);

    /**
     * @notice Updates the management fee recipient for the vault.
     * @param recipient The new management fee recipient address.
     * @dev Only callable by factory owner.
     * @dev Recipient cannot be address(0).
     */
    function updateManagementFeeRecipient(address recipient) external;

    /**
     * @notice Updates the performance fee recipient for the vault.
     * @param recipient The new performance fee recipient address.
     * @dev Only callable by factory owner.
     * @dev Recipient cannot be address(0).
     */
    function updatePerformanceFeeRecipient(address recipient) external;

    /**
     * @notice Returns the current fee configuration for the vault.
     * @return currentManagementFee The current management fee in basis points.
     * @return currentManagementFeeRecipient The current management fee recipient address.
     * @return currentLastManagementFeeAccrual The timestamp of the last management fee accrual.
     * @return currentPerformanceFee The current performance fee in basis points.
     * @return currentPerformanceFeeRecipient The current performance fee recipient address.
     */
    function getFeeConfig()
        external
        view
        returns (
            uint16 currentManagementFee,
            address currentManagementFeeRecipient,
            uint32 currentLastManagementFeeAccrual,
            uint16 currentPerformanceFee,
            address currentPerformanceFeeRecipient
        );

    /**
     * @notice Sets the hooks for the vault.
     * @dev This function sets the hooks for the vault.
     * @dev Only callable by accounts with the HOOK_MANAGER role.
     * @param hooks The hooks to set.
     */
    function setHooks(Hooks memory hooks) external;

    /**
     * @notice Returns the current hooks configuration for the vault.
     * @return The Hooks struct containing the target address and flags.
     */
    function getHooks() external view returns (Hooks memory);

    /**
     * @notice Previews the total assets that would be available after accruing yield from all strategies.
     * @dev This function simulates the yield accrual operation without actually executing it,
     *      providing a view of what the vault's total assets would be after accounting
     *      for yield and losses across all active strategies.
     * @dev The calculation includes the current lastTotalAssets plus any positive
     *      yield minus any losses that would be realized during yield accrual.
     * @dev This is a view function that does not modify state or trigger any actual
     *      fund movements or strategy interactions.
     *
     * @return The total amount of assets that would be available in the vault after yield accrual,
     *         denominated in the vault's underlying asset token.
     * @return The total amount of shares that would be available in the vault after yield accrual,
     *         calculated as current totalSupply + management fee shares.
     */
    function previewAccrueYield() external view returns (uint256, uint256);

    /**
     * @dev Retrieves the current data and status information for a specific strategy.
     * @dev This function provides read-only access to strategy metadata including allocation amounts and status.
     *
     * @param strategy The address of the strategy contract to query.
     * @return The StrategyData struct containing the strategy's current status and allocated amount.
     *
     * Note:
     * - Returns default values (Inactive status, 0 allocated) for non-existent strategies
     * - Does not revert for invalid strategy addresses
     */
    function getStrategyData(address strategy) external view returns (StrategyData memory);

    /**
     * @dev Returns an array of all strategy addresses currently managed by the vault.
     * @dev This function provides a way to enumerate all active strategies for external integrations and monitoring.
     *
     * @return An array containing the addresses of all strategies added to the vault.
     *
     * Note:
     * - The returned array includes strategies in all statuses (Active, Inactive, Emergency)
     * - The order of strategies in the array is not guaranteed
     * - Returns an empty array if no strategies have been added
     */
    function getStrategies() external view returns (address[] memory);

    /**
     * @dev Returns the address of the allocate module.
     *
     * @return The address of the allocate module.
     */
    function allocateModule() external view returns (address);

    /**
     * @dev Returns the deposit limits.
     * @return maxGlobalDepositAmount The maximum deposit amount for the vault.
     * @return minTxDepositAmount The minimum deposit amount for a single transaction.
     */
    function getDepositLimits() external view returns (uint256 maxGlobalDepositAmount, uint256 minTxDepositAmount);

    /**
     * @dev Returns the withdraw limits.
     * @return maxTxWithdrawAmount The maximum withdraw amount for a single transaction.
     * @return minTxWithdrawAmount The minimum withdraw amount for a single transaction.
     */
    function getWithdrawLimits() external view returns (uint256 maxTxWithdrawAmount, uint256 minTxWithdrawAmount);

    /**
     * @dev Returns the total amount of assets allocated to all strategies.
     *
     * @return The total amount of assets allocated to all strategies.
     */
    function getTotalAllocated() external view returns (uint256);

    /**
     * @dev Returns the cached value of total assets after the last call.
     *
     * @return The cached value of total assets after the last call.
     */
    function cachedTotalAssets() external view returns (uint256);

    /**
     * @notice Transfers donated tokens to recipient.
     * @dev For the underlying asset, only the surplus above floating is swept.
     *      For any other token, the entire balance is swept.
     * @dev Only callable by accounts with the VAULT_MANAGER role.
     * @param token The token to be swept.
     * @param recipient The address to receive the swept tokens.
     */
    function sweepDonatedTokens(address token, address recipient) external;

    /**
     * @dev Emitted when donated tokens are swept out of the vault.
     * @param token The token that was swept.
     * @param recipient The address that received the swept tokens.
     * @param amount The amount of tokens swept.
     */
    event DonationSwept(address indexed token, address indexed recipient, uint256 amount);

    /**
     * @dev Returns the deallocation order from strategies.
     *
     * @return order An array of strategy addresses in the order they should be deallocated.
     */
    function getDeallocationOrder() external view returns (address[] memory order);

    /**
     * @dev Sets the deallocation order for strategies.
     * @dev Only callable by accounts with the ALLOCATOR role.
     * @param order An array of strategy addresses in the order they should be deallocated.
     */
    function setDeallocationOrder(address[] calldata order) external;

    /**
     * @notice Returns the current hurdle rate oracle address.
     * @return The hurdle rate oracle, or address(0) if not set.
     */
    function getHurdleRateOracle() external view returns (IHurdleRateOracle);
}
