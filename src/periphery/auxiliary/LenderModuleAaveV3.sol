import {ILenderModule} from "../interface/ILenderModule.sol";
import {ILenderStaging} from "../interface/ILenderStaging.sol";
import {AaveV3LenderAdapter} from "../lenders/AaveV3LenderAdapter.sol";
import {IStrategyTemplate} from "../../interface/IStrategyTemplate.sol";
import {AaveV3LenderAdapterStorageLib as AV3LADSL} from "../lenders/AaveV3LenderAdapterStorageLib.sol";
import {LenderModuleAaveV3StorageLib as LMAaveV3SL} from "./LenderModuleAaveV3StorageLib.sol";

import {SafeERC20} from "@openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin-contracts/token/ERC20/IERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";

contract LenderModuleAaveV3 is AaveV3LenderAdapter, ILenderStaging, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    error InsufficientStagedAmount();

    constructor(address collateralToken, address borrowToken, address dataProvider)
        AaveV3LenderAdapter(collateralToken, borrowToken, dataProvider)
    {}

    function initialize(address admin_, uint256 interestRateMode_) external reinitializer(1) {
        __AaveV3LenderAdapter_init(admin_, interestRateMode_);
        // set the staged amount to the current collateral amount
        LMAaveV3SL.fetch().staged = IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
    }

    function stage(uint256 amount) external override {
        if (amount == 0) return;
        // pull from the msg.sender the collateral tokens and record it
        IERC20(COLLATERAL_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        // update the staged amount
        LMAaveV3SL.fetch().staged += amount;
    }

    function staged() external view override returns (uint256) {
        return LMAaveV3SL.fetch().staged;
    }

    function engage(uint256 amount) external override onlyStrategyOrOwner {
        if (amount == 0) return;
        LMAaveV3SL.LenderModuleAaveV3Storage storage $ = LMAaveV3SL.fetch();
        if (amount > $.staged) revert InsufficientStagedAmount();
        // engage the staged collateral at the lender
        _supply(amount);
        $.staged -= amount;
    }

    function send(uint256 amount) external onlyStrategyOrOwner {
        if (amount == 0) return;
        LMAaveV3SL.LenderModuleAaveV3Storage storage $ = LMAaveV3SL.fetch();
        if (amount > $.staged) revert InsufficientStagedAmount();
        address strategy = AV3LADSL.fetch().strategy;
        IERC20(COLLATERAL_TOKEN).safeTransfer(IStrategyTemplate(strategy).getVault(), amount);
        $.staged -= amount;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
