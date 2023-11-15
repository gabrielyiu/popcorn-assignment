// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/aave/IPoolAddressProvider.sol";
import "./interfaces/aave/IPool.sol";
import "./interfaces/balancer/IFlashLoans.sol";
import "./interfaces/uniswap/ISwapRouter.sol";

contract Strategy is AccessControl, ReentrancyGuard {

    using SafeERC20 for IERC20;

    error NOT_BALANCER();
    
    event Deposit(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    event LeverageAdded(address indexed user, uint256 amount, uint256 debt);

    /// @dev Owner role to assign manager roles
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");
    /// @dev Manager role to adjust leverage ratio and call harvest function
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @dev Aave V3 pool addresses provider
    address private constant provider = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    /// @dev Balancer vault, flashloan fee = 0
    address private constant balancerVault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
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

    uint256 public leverageRatio;

    uint8 private flashMode;

    constructor() {
        _grantRole(OWNER_ROLE, msg.sender);
        _setRoleAdmin(MANAGER_ROLE, OWNER_ROLE);
    }

    function setManager(
        address _account
    ) external onlyRole(OWNER_ROLE) {
        grantRole(MANAGER_ROLE, _account);
    }

    function setLeverageRatio(uint256 _leverageRatio) external onlyRole(MANAGER_ROLE) {
        leverageRatio = _leverageRatio;
    }

    function deposit(uint256 _amount) external {
        IERC20(wstETH).safeTransferFrom(msg.sender, address(this), _amount);

        // supply
        address poolAddress = IPoolAddressProvider(provider).getPool();
        IERC20(wstETH).approve(poolAddress, _amount);
        IPool(poolAddress).supply(wstETH, _amount, address(this), 0);

        emit Deposit(msg.sender, _amount);
    }

    function borrow(uint256 _amount) external {
        address poolAddress = IPoolAddressProvider(provider).getPool();
        IERC20(wETH).approve(poolAddress, _amount);
        IPool(poolAddress).borrow(wETH, _amount, 2, 0, address(this));
        IERC20(wETH).safeTransfer(msg.sender, _amount);

        emit Borrow(msg.sender, _amount);
    }

    function repay(uint256 _amount) external {
        IERC20(wETH).safeTransferFrom(msg.sender, address(this), _amount);

        address poolAddress = IPoolAddressProvider(provider).getPool();

        IERC20(wETH).approve(poolAddress, _amount);
        IPool(poolAddress).repay(wETH, _amount, 2, address(this));

        emit Repay(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        address poolAddress = IPoolAddressProvider(provider).getPool();

        IERC20(aWstETH).approve(poolAddress, _amount);
        IPool(poolAddress).withdraw(wstETH, _amount, address(this));

        IERC20(wstETH).safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _amount);
    }

    /**
     * @dev use flashloan of balancer vault instead of leverage looping
     * flashloan callback, called by balancer vault
     */
    function receiveFlashLoan(
        address[] memory,
        uint256[] memory,
        uint256[] memory feeAmounts,
        bytes calldata params
    ) external nonReentrant {
        if (msg.sender != balancerVault) revert NOT_BALANCER();

        uint256 feeAmount = 0;
        if (feeAmounts.length > 0) {
            feeAmount = feeAmounts[0];
        }
        if (flashMode == 1) _flAddLeverage(params, feeAmount);
        /* if (flashMode == 2) _flRemoveLeverage(params, feeAmount);
        if (flashMode == 3) _flSwitchAsset(params, feeAmount);
        if (flashMode == 4) _flSwitchDebt(params, feeAmount);
        if (flashMode == 5) _flCloseLeverage(params, feeAmount); */
    }

    /**
     * @dev process:
     * flashloan the expected debt -> swap the expected debt to asset -> 
     * supply the asset -> borrow to repay the flashloan
     */
    function addLeverage(uint256 _amount, uint256 _debt) external {
        address poolAddress = IPoolAddressProvider(provider).getPool();
        if (_amount > 0) {
            IERC20(wstETH).safeTransferFrom(msg.sender, address(this), _amount);

            // supply
            IERC20(wstETH).approve(poolAddress, _amount);
            IPool(poolAddress).supply(wstETH, _amount, address(this), 0);
        }

        if (_debt > 0) {
            // execute flashloan
            bytes memory params = abi.encode(_debt, poolAddress);
            address[] memory tokens = new address[](1);
            tokens[0] = wETH;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = _debt;
            flashMode = 1; // addLeverage

            IFlashLoans(
                balancerVault
            ).flashLoan(address(this), tokens, amounts, params);

            flashMode = 0;
        }

        emit LeverageAdded(msg.sender, _amount, _debt);
    }

    function _flAddLeverage(bytes calldata _params, uint256 _feeAmount) internal {
        // decode params
        (uint256 amount, address poolAddress) = abi.decode(_params, (uint256, address));

        // swap debt to asset
        // the only solution to convert from memory to calldata
        uint256 outAmountDebt = _swapBySelf(wETH, wstETH, 3000, amount);

        // supply
        IERC20(wstETH).approve(poolAddress, outAmountDebt);
        IPool(poolAddress).supply(wstETH, outAmountDebt, address(this), 0);

        // borrow the equivalent amount using our new collateral
        IPool(poolAddress).borrow(wETH, amount + _feeAmount, 2, 0, address(this));

        // repay debt Flashloan
        IERC20(wETH).safeTransfer(balancerVault, amount + _feeAmount);
    }

    function _swapBySelf(
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
