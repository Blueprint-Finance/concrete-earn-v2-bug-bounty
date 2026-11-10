// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

struct Hooks {
    address target;
    uint96 flags;
}

interface IHook {
    /// @notice The vault this hook is bound to. Implementations backed by ClonesWithImmutableArgs
    ///         may tighten this to `pure` (the value is read from calldata, not state).
    function VAULT() external view returns (address);
    /// @notice The factory authorized to initialize this hook clone. Implementations backed by
    ///         ClonesWithImmutableArgs may tighten this to `pure` (read from calldata, not state).
    function FACTORY() external view returns (address);
    // USER ACTION HOOKS

    /// @notice Fires before every deposit that mints shares, on every vault flavour — including a
    ///         non-base deposit on a multi-asset vault, which fires this *and* {preMultiDeposit}.
    /// @dev `assets` is a base-asset-equivalent *notional*, not necessarily base liquidity the vault
    ///      received: on a non-base deposit no `asset()` enters the vault at all. Gate and accounting
    ///      logic keyed on `sender` / `receiver` / `shares` is safe; never reconcile `assets` against
    ///      `asset().balanceOf(vault)`. Use {preMultiDeposit} to discriminate by deposit token.
    function preDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;
    /// @notice Fires before a share-denominated deposit (`mint`). Same parameters as {preDeposit};
    ///         `shares` is the requested amount and `assets` the cost derived from it.
    function preMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;
    /// @notice Fires before an asset-denominated exit (`withdraw`), before shares are burnt.
    /// @dev `owner` is the account whose shares are burnt; `sender` may differ when spending an
    ///      allowance, and `receiver` is where the assets go. Gate on `owner` for balance-based rules.
    function preWithdraw(
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 totalAssets
    ) external;
    /// @notice Fires before a share-denominated exit (`redeem`), before shares are burnt.
    /// @dev Same `sender` / `owner` / `receiver` distinction as {preWithdraw}.
    function preRedeem(
        address sender,
        uint256 assets,
        uint256 shares,
        address receiver,
        address owner,
        uint256 totalAssets
    ) external;
    /// @notice Fires after every deposit that mints shares, on every vault flavour — including a
    ///         non-base deposit on a multi-asset vault. Shares are already minted when this runs.
    /// @dev `assets` carries the same base-asset-equivalent notional caveat as {preDeposit}.
    function postDeposit(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;
    /// @notice Fires after a `mint`. Shares are already minted when this runs.
    function postMint(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;
    /// @notice Fires after a `withdraw`. Shares are already burnt and the assets sent.
    /// @dev No `owner` parameter here, unlike {preWithdraw}: post-exit hooks observe the settled
    ///      transfer rather than gating it.
    function postWithdraw(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets)
        external;
    /// @notice Fires after a `redeem`. Shares are already burnt and the assets sent.
    function postRedeem(address sender, uint256 assets, uint256 shares, address receiver, uint256 totalAssets) external;

    // MULTI-ASSET USER ACTION HOOKS

    /// @notice Pre-deposit validation for a non-base deposit on a multi-asset deposit vault.
    /// @dev Unlike {preDeposit}, which only ever carries the base-asset-equivalent value, this
    ///      also carries the deposit token and its raw amount so hooks can reason per token.
    /// @param sender The address initiating the deposit.
    /// @param depositAsset The token being deposited (never the vault's base `asset()`).
    /// @param depositAssetAmount The raw amount of `depositAsset`, in that token's own decimals.
    /// @param baseAssets The base-asset-equivalent value of `depositAssetAmount`.
    /// @param shares The shares the deposit will mint.
    /// @param receiver The address that will receive the vault shares.
    /// @param totalAssets The total assets in the vault before this deposit.
    function preMultiDeposit(
        address sender,
        address depositAsset,
        uint256 depositAssetAmount,
        uint256 baseAssets,
        uint256 shares,
        address receiver,
        uint256 totalAssets
    ) external;

    // TRANSFER HOOKS

    /// @notice Fires before a share transfer, so a hook can block it (e.g. a lock or an allowlist).
    /// @dev Raised on plain transfers only — the mint and burn legs of deposit/redeem are skipped
    ///      (they have their own lifecycle points). `from` is the account sending the shares;
    ///      `sender` is the caller, which differs under `transferFrom`. Gate on `from` for
    ///      balance-based rules.
    function preTransfer(address sender, address from, address to, uint256 shares) external;
    /// @notice Fires after a share transfer has settled.
    function postTransfer(address sender, address from, address to, uint256 shares) external;
}
