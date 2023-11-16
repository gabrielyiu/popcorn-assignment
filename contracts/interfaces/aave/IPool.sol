// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

interface IPool {
    function supply(
        address asset, 
        uint256 amount, 
        address onBehalfOf, 
        uint16 referralCode
    ) external;

    function withdraw(
        address asset, 
        uint256 amount, 
        address to
    ) external returns (uint256);

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    function repay(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external returns (uint256);
    
    /**
    * @notice Returns the user account data across all the reserves
    * @param user The address of the user
    * @return totalCollateralBase The total collateral of the user in the base currency used by the price feed
    * @return totalDebtBase The total debt of the user in the base currency used by the price feed
    * @return availableBorrowsBase The borrowing power left of the user in the base currency used by the price feed
    * @return currentLiquidationThreshold The liquidation threshold of the user
    * @return ltv The loan to value of The user
    * @return healthFactor The current health factor of the user
    */
    function getUserAccountData(
        address user
    ) external view returns (
        uint256 totalCollateralBase,
        uint256 totalDebtBase,
        uint256 availableBorrowsBase,
        uint256 currentLiquidationThreshold,
        uint256 ltv,
        uint256 healthFactor
    );
}
