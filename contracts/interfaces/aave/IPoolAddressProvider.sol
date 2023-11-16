// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

interface IPoolAddressProvider {
    function getPool() external view returns (address);

    function getPriceOracle() external view returns (address);
}
