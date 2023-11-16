// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/aave/IPoolAddressProvider.sol";
import "./interfaces/aave/IPool.sol";
import "./interfaces/aave/IPriceOracleGetter.sol";
import "./interfaces/uniswap/ISwapRouter.sol";

contract Strategy is AccessControl, ReentrancyGuard {

    using SafeERC20 for IERC20;
    
    event Deposit(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    /// @dev Owner role to assign manager roles
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    /// @dev Manager role to adjust leverage ratio and call harvest function
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    
    /// @dev Aave V3 pool addresses provider
    address private constant provider = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    /// @dev Uniswap V3 swap router
    address private constant router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    /// @dev underlying assets
    address public constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant wETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    /// @dev Collateral assets
    address public constant aWstETH = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    address public constant aWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;

    /// @dev debt assets
    address public constant vDebtWstETH = 0xC96113eED8cAB59cD8A66813bCB0cEb29F06D2e4;
    address public constant vDebtWETH = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;

    uint256 public leverageRatio = 1;

    /// @notice mapping from user address to staked amount
    mapping(address => uint256) public balanceOf;
    /// @notice Total staked
    uint256 public totalSupply;

    constructor() {
        _grantRole(OWNER_ROLE, msg.sender);
        _setRoleAdmin(MANAGER_ROLE, OWNER_ROLE);
    }

    function setManager(
        address _account
    ) external onlyRole(OWNER_ROLE) {
        grantRole(MANAGER_ROLE, _account);
    }

    function deposit(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        IERC20(wstETH).safeTransferFrom(msg.sender, address(this), _amount);

        balanceOf[msg.sender] += _amount;
        totalSupply += _amount;

        // Supply wstETH to Aave
        _supply(_amount);

        emit Deposit(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Invalid amount");
        require(balanceOf[msg.sender] >= _amount, "Exceeded amount");
        
        // Withdraw wstETH from Aave
        address poolAddress = IPoolAddressProvider(provider).getPool();

        IERC20(aWstETH).approve(poolAddress, _amount);
        IPool(poolAddress).withdraw(wstETH, _amount, address(this));

        balanceOf[msg.sender] -= _amount;
        totalSupply -= _amount;
        IERC20(wstETH).safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    function harvest() external onlyRole(MANAGER_ROLE) nonReentrant {
        // borrow wETH from Aave
        uint256 amountToBorrow = _calcBorrowAmount();
        if (amountToBorrow == 0) {
            leverageRatio = 1;
            return;
        }

        // borrow ETH from Aave
        _borrow(amountToBorrow);

        // mint new wstETH with borrowed ETH
        uint256 outAmount = _swapExactInputSingle(wETH, wstETH, 3000, amountToBorrow);
        
        // redeposit aave to increase leverage
        _supply(outAmount);
    }
    
    function _supply(uint256 _amount) internal {
        address poolAddress = IPoolAddressProvider(provider).getPool();

        IERC20(wstETH).approve(poolAddress, _amount);
        IPool(poolAddress).supply(wstETH, _amount, address(this), 0);
    }

    function _borrow(uint256 _amount) internal {
        // get pool address via address provider
        address poolAddress = IPoolAddressProvider(provider).getPool();

        IERC20(wETH).approve(poolAddress, _amount);
        IPool(poolAddress).borrow(wETH, _amount, 2, 0, address(this));
    }

    function _calcBorrowAmount() internal view returns (uint256) {
        address poolAddress = IPoolAddressProvider(provider).getPool();
        // get account data
        (, , uint256 availableBorrowsBase, , ,) = IPool(poolAddress).getUserAccountData(address(this));

        // get ETH Price in base currency
        address priceOracleAddress = IPoolAddressProvider(provider).getPriceOracle();
        uint256 ethPrice = IPriceOracleGetter(priceOracleAddress).getAssetPrice(wETH);

        require(ethPrice > 0, "Invalid oracle info");
        return availableBorrowsBase / ethPrice;
    }

    function _swapExactInputSingle(
        address _tokenIn,
        address _tokenOut,
        uint24 _poolFee,
        uint256 _amount
    ) internal returns (uint256 amountOut) {
        IERC20(_tokenIn).approve(address(router), _amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: _tokenIn,
                tokenOut: _tokenOut,
                fee: _poolFee,
                recipient: msg.sender,
                deadline: block.timestamp,
                amountIn: _amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });

        amountOut = ISwapRouter(router).exactInputSingle(params);
    }
}
