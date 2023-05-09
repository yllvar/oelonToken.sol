// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./IUniswapV2Router02.sol";

contract OELON is ERC20Burnable, ERC20Capped, ERC20Pausable, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Declare state variables
    address public marketingWallet;
    address public liquidityPool;
    address public rewardToken;
    address public dogeToken;
    address public token;
    uint256 public liquidityPoolFee = 1;
    uint256 public marketingFee = 2;
    uint256 public rewardFee = 2;
    uint256 public rewardInterval = 4 * 24 * 60 * 60 + 20 * 60;
    uint256 public lastRewardTime;
    uint256 public nextRewardTime;
    IUniswapV2Router02 public uniswapV2Router;
    mapping(address => uint256) public lastRewardClaim;
    mapping(address => uint256) public tokenPercentage;
    mapping(address => uint256) private _balanceOf;
    address[] public holders;

    // Declare events
    event LiquidityAdded(uint256 amountToken, uint256 amountETH, uint256 liquidity);
    event RewardsDistributed(uint256 totalReward);

    // Constructor
    constructor(
        address _marketingWallet,
        address _liquidityPool,
        address _rewardToken,
        address _dogeToken,
        uint256 _cap,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) ERC20Capped(_cap) {
        marketingWallet = _marketingWallet;
        liquidityPool = _liquidityPool;
        rewardToken = _rewardToken;
        dogeToken = _dogeToken;
        lastRewardTime = block.timestamp;
        nextRewardTime = block.timestamp.add(rewardInterval);

        // Initialize uniswapV2Router
        uniswapV2Router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    }

    function setFees(uint256 _liquidityPoolFee, uint256 _marketingFee, uint256 _rewardFee) external onlyOwner {
        require(_liquidityPoolFee.add(_marketingFee).add(_rewardFee) == 5, "OELON: invalid total fees");
        liquidityPoolFee = _liquidityPoolFee;
        marketingFee = _marketingFee;
        rewardFee = _rewardFee;
    }

    function setLiquidityPoolFee(uint256 _liquidityPoolFee) external onlyOwner {
        liquidityPoolFee = _liquidityPoolFee;
    }

    function setMarketingFee(uint256 _marketingFee) external onlyOwner {
        marketingFee = _marketingFee;
    }

    function setRewardFee(uint256 _rewardFee) external onlyOwner {
        rewardFee = _rewardFee;
    }

    function setRewardInterval(uint256 _rewardInterval) external onlyOwner {
        require(_rewardInterval > 0, "OELON: invalid reward interval");
        rewardInterval = _rewardInterval;
    }

    function setLiquidityPool(address _liquidityPool, address _uniswapV2Router) external onlyOwner {
        require(_liquidityPool != address(0), "OELON: invalid liquidity pool");
        require(_uniswapV2Router != address(0), "OELON: invalid Uniswap V2 router");

        // Update the liquidity pool address
        liquidityPool = _liquidityPool;

        // Initialize the uniswapV2Router if it is not already initialized
        if (address(uniswapV2Router) == address(0)) {
            uniswapV2Router = IUniswapV2Router02(_uniswapV2Router);
        }

        // Approve the router to spend the token's maximum allowance
        _approve(address(this), address(uniswapV2Router), type(uint256).max);
    }

    function setRewardToken(address _rewardToken) external onlyOwner {
        require(_rewardToken != address(0), "OELON: invalid reward token");
        rewardToken = _rewardToken;
    }

    function setDogeToken(address _dogeToken) external onlyOwner {
        require(_dogeToken != address(0), "OELON: invalid DOGE token");
        dogeToken = _dogeToken;
    }

    function setToken(address _token) external onlyOwner {
        require(_token != address(0), "OELON: invalid token");
        token = _token;
    }

    function setMarketingWallet(address _marketingWallet) external onlyOwner {
        require(_marketingWallet != address(0), "OELON: invalid marketing wallet");
        marketingWallet = _marketingWallet;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return super.balanceOf(account);
    }

    function _mint(address account, uint256 amount) internal override(ERC20, ERC20Capped) {
        // delegate to the implementation in ERC20Capped
        super._mint(account, amount);
    }

    function _getLastRewardTime(address account) internal view returns (uint256) {
        uint256 lastClaim = lastRewardClaim[account];
        if (lastClaim == 0 || lastClaim >= block.timestamp) {
            return block.timestamp;
        }
        return lastClaim;
    }

    function _indexOf(address account) internal view returns (uint256) {
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == account) {
                return i;
            }
        }
        return holders.length;
    }

    function getTokenHolders() public view returns (address[] memory) {
        address[] memory holdersList = new address[](holders.length);
        uint256 holderCount = 0;

        for (uint256 i = 0; i < holders.length; i++) {
            address holder = holders[i];
            if (balanceOf(holder) > 0) {
                holdersList[holderCount++] = holder;
            }
        }

        // Resize the holdersList array to remove any empty slots
        assembly {
            mstore(holdersList, holderCount)
        }

        return holdersList;
    }

    function hasTokenHolder(address holder, address[] memory holdersList) private pure returns (bool) {
        for (uint256 i = 0; i < holdersList.length; i++) {
            if (holdersList[i] == holder) {
                return true;
            }
        }
        return false;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        // Ensure that the sender has enough tokens to transfer
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        // Transfer the tokens from the sender to the recipient
        _transfer(msg.sender, to, amount);

        // Add the recipient to the list of token holders if they are not already in it
        if (balanceOf(to) > 0 && !hasTokenHolder(to, holders)) {
            holders.push(to);
        }

        return true;
    }

    function _transferWithFees(address sender, address recipient, uint256 amount) private nonReentrant {
        uint256 liquidityPoolAmount = amount.mul(liquidityPoolFee).div(100);
        uint256 marketingAmount = amount.mul(marketingFee).div(100);
        uint256 rewardAmount = amount.mul(rewardFee).div(100);

        // Transfer the liquidity pool fee to the contract
        _transfer(sender, address(this), liquidityPoolAmount);

        // Calculate the token amounts needed for liquidity
        uint256 tokenAmount = balanceOf(address(this));
        uint256 ethAmount = address(this).balance;

        // Swap tokens for ETH and add liquidity to the UniswapV2 pool
        if (tokenAmount > 0 && ethAmount > 0) {
            IUniswapV2Router02 router = IUniswapV2Router02(uniswapV2Router);
            address[] memory path = new address[](2);
            path[0] = address(this);
            path[1] = router.WETH();

            _approve(address(this), address(router), tokenAmount);
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                tokenAmount,
                0,
                path,
                address(this),
                block.timestamp
            );
            (uint256 amountToken, uint256 amountETH, uint256 liquidity) = router.addLiquidityETH{value: ethAmount}(
                address(this),
                tokenAmount,
                0,
                0,
                address(this),
                block.timestamp
            );

            emit LiquidityAdded(amountToken, amountETH, liquidity);
        }

        // Transfer the remaining fees
        _transfer(sender, marketingWallet, marketingAmount);
        _transfer(sender, address(this), rewardAmount);
        _transfer(sender, recipient, amount.sub(liquidityPoolAmount).sub(marketingAmount).sub(rewardAmount));

        // Trigger reward distribution if necessary
        if (block.timestamp >= nextRewardTime && IERC20(rewardToken).balanceOf(address(this)) > 0) {
            _distributeRewards();
            lastRewardTime = nextRewardTime;
            nextRewardTime = block.timestamp.add(rewardInterval);
        }
    }

    function SwapAndDistribute() public nonReentrant {
        // Get the balance of the contract
        uint256 contractBalance = balanceOf(address(this));
        
        // Calculate the total amount of tokens to distribute
        uint256 totalDistribution = contractBalance.mul(2).div(100); // 2% of contract balance
        
        // Ensure that there are enough tokens to distribute
        require(totalDistribution > 0, "Insufficient balance to distribute");
        
        // Distribute tokens to each holder
        for (uint i = 0; i < holders.length; i++) {
            address holder = holders[i];
            uint256 distribution = balanceOf(holder).mul(totalDistribution).div(totalSupply());
            _transfer(address(this), holder, distribution);
        }
    }

    function calculateReward(address holder) public view returns (uint256) {
        if (lastRewardTime == 0 || IERC20(dogeToken).balanceOf(address(this)) == 0) {
            return 0;
        }

        uint256 timeElapsed = block.timestamp.sub(lastRewardTime);
        uint256 rewardPerToken = IERC20(dogeToken).balanceOf(address(this)).div(balanceOf(address(this)));

        uint256 lastReward = lastRewardClaim[holder];
        uint256 unclaimedRewards = rewardPerToken.mul(balanceOf(holder)).sub(lastReward);

        if (timeElapsed > rewardInterval) {
            return unclaimedRewards.add(rewardPerToken.mul(balanceOf(holder)));
        }

        uint256 timeRemaining = rewardInterval.sub(timeElapsed);
        uint256 additionalReward = timeRemaining.mul(rewardPerToken).mul(balanceOf(holder)).div(rewardInterval);

        return unclaimedRewards.add(additionalReward);
    }

    function removeHolder(address holder) private {
        if (!hasTokenHolder(holder, holders)) {
            return;
        }

        uint256 indexToRemove = 0;
        for (uint256 i = 0; i < holders.length; i++) {
            if (holders[i] == holder) {
                indexToRemove = i;
                break;
            }
        }

        if (indexToRemove >= holders.length) {
            return;
        }

        for (uint256 i = indexToRemove; i < holders.length - 1; i++) {
            holders[i] = holders[i + 1];
        }

        holders.pop();
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Pausable) {
        super._beforeTokenTransfer(from, to, amount);

        if (from == address(0) || to == address(0)) {
            // Exclude mint and burn transactions
            return;
        }

        // Update last reward claim time for sender and receiver
        lastRewardClaim[from] = _getLastRewardTime(from);
        lastRewardClaim[to] = _getLastRewardTime(to);

        // Update balance of sender and receiver
        _balanceOf[from] = _balanceOf[from].sub(amount);
        _balanceOf[to] = _balanceOf[to].add(amount);

        // Update holders array if necessary
        if (_balanceOf[from] == 0) {
            uint256 index = _indexOf(from);
            if (index != holders.length - 1) {
                holders[index] = holders[holders.length - 1];
            }
            holders.pop();
        }
        if (_balanceOf[to] > 0 && _indexOf(to) == holders.length) {
            holders.push(to);
        }

        // Apply fees
        uint256 liquidityPoolAmount = amount.mul(liquidityPoolFee).div(100);
        uint256 marketingAmount = amount.mul(marketingFee).div(100);
        uint256 rewardAmount = amount.mul(rewardFee).div(100);

        _balanceOf[liquidityPool] = _balanceOf[liquidityPool].add(liquidityPoolAmount);
        _balanceOf[marketingWallet] = _balanceOf[marketingWallet].add(marketingAmount);
        _balanceOf[rewardToken] = _balanceOf[rewardToken].add(rewardAmount);
        _balanceOf[dogeToken] = _balanceOf[dogeToken].add(rewardAmount);

        // Emit transfer event
        emit Transfer(from, to, amount);

        // Distribute rewards if necessary
        if (block.timestamp >= nextRewardTime) {
            _distributeRewards();
        }
    }

    function _distributeRewards() private {
        uint256 totalReward = balanceOf(address(this));
        uint256 count = holders.length;
        uint256 totalTokenBalance = totalSupply();

        for (uint256 i = 0; i < count; i++) {
            address holder = holders[i];
            uint256 holderBalance = _balanceOf[holder];

            // Calculate the percentage of tokens held by the account
            uint256 currentPercentage = tokenPercentage[holder];
            uint256 newPercentage = holderBalance.mul(100).div(totalTokenBalance);
            tokenPercentage[holder] = newPercentage;

            // Calculate the Doge rewards based on the account's percentage of tokens
            uint256 holderReward = totalReward.mul(newPercentage.sub(currentPercentage)).div(100);
            _balanceOf[holder] = holderBalance.add(holderReward);

            totalReward = totalReward.sub(holderReward);
        }

        _balanceOf[address(this)] = totalReward;

        uint256 currentTime = block.timestamp;
        uint256 timeElapsed = currentTime.sub(lastRewardTime);

        if (timeElapsed >= rewardInterval) {
            lastRewardTime = currentTime;
            emit RewardsDistributed(totalReward);
        }
    }

        function claimReward() external {
            require(balanceOf(msg.sender) > 0, "OELON: sender balance is 0");
            require(lastRewardClaim[msg.sender] + rewardInterval <= block.timestamp, "OELON: reward already claimed");

            uint256 holderBalance = balanceOf(msg.sender);
            uint256 holderReward = calculateReward(msg.sender);

            _balanceOf[msg.sender] = holderBalance.add(holderReward);
            lastRewardClaim[msg.sender] = block.timestamp;

            IERC20(rewardToken).safeTransfer(msg.sender, holderReward);

            if (holderBalance == 0) {
                removeHolder(msg.sender);
            }
        }

        function _approve(address spender, uint256 amount) internal {
            IERC20(token).approve(spender, amount);
        }

        function pause() external onlyOwner {
            _pause();
        }

        function unpause() external onlyOwner {
            _unpause();
        }

        receive() external payable {}

        fallback() external payable {}

        }
