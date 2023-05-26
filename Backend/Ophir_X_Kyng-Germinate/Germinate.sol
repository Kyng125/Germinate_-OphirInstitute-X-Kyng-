// SPDX-License-Identifier: MIT

/** NatSpec
/// @title GERMINATE: AN ERC20 STAKING CONTRACT //////////////////
/// @notice Seed token holders stake Seed to earn Fruit as rewards
/// @notice Staking and Reward Tokens are deployed on Polygon Mumbai testnet
/// @dev Tokens must be approved before thy can be staked
/// Seed CA: 0x3bf87216ef8d57a5ee0e86f5ee791027f299d9a1
/// Fruit CA: 0x7e8d83b0c828acfb06799ebb973ad3bd2d5f2579
/// Germinate CA: 0x82996037c676bb4479a155f5103d4c0926567eb5
*/


////////////////// PROJECT OVERVIEW //////////////////
// 1. Brainstorming on what Libraries to use to build the Dapp {Math/Address/SafeERC20/IERC20/Reentrancy}
// 2. Import Libraries
// 3. Create and Deploy a Stake Token (Seed) and a Reward Token (Fruit)
// 4. Build the Staking Contract
// 5. Lastly deploy and verify the contracts {multi-file verification}
/////////////////////////////////////////////////////

// Import other Libraries
import "./Math.sol";
import "./Address.sol";
import "./ReentrancyGuard.sol";
import "./SafeERC20.sol";
import "./IERC20.sol";
import "./PoolManager.sol";

pragma solidity ^0.8.0;

contract Germinate is ReentrancyGuard {

    using SafeERC20 for IERC20;
    using PoolManager for PoolManager.PoolState;

    // STEP 1: Declare the necessary variables
    PoolManager.PoolState private _stake;

    uint256 private _totalStake; // Total amount of SEED  Tokens Staked
    mapping (address => uint256) private _userRewardPerTokenPaid;
    mapping (address => uint256) private _rewards;
    mapping (address => uint256) private _balances;

    // STEP 2: Inherit the ERC20 Interface
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;

    // STEP 3: Build the Constructor
    constructor (address _distributor, IERC20 stakingToken_, IERC20 rewardToken_, uint64 _duration) {
        stakingToken = stakingToken_;
        rewardToken = rewardToken_;
        _stake.distributor = uint160(_distributor);
        _stake.rewardsDuration = _duration * 1 days;
    }

    ////////////////////// MODIFIERS /////////////////////
    // STEP 4: Create modifiers
    // 1. onlyDistributor
    modifier  onlyDistributor() {
        require(msg.sender == address(_stake.distributor), "Not Distributor");
        _;
    }

    // 2. updateRewards
    modifier updateRewards(address account) {
        _stake.updateReward(_totalStake);

        if(account != address(0)) {
            //_rewards[account] - earned(account);
            _userRewardPerTokenPaid[account] - _stake.rewardPerTokenStored;
        }
        _;
    }
    /////////////////////////////////////////////////////

    ////////////////////// VIEWS /////////////////////
    // STEP 5: Create functions to read the contract
    function totalAmountStaked() external view returns(uint256) {
        return _totalStake;
    }

    function balanceOf(address account) external view returns(uint256) {
        return _balances[account];
    }

    function getOwner() external view returns (address)
    {
        return address(_stake.distributor);
    }

    function lastTimeRewardApplicable() external view returns (uint256)
    {
        return _stake.lastTimeRewardApplicable();
    }

    function rewardPerToken() external view returns (uint256)
    {
        return _stake.rewardPerToken(_totalStake);
    }

    function getRewardForDuration() external view returns (uint256)
    {
        return _stake.getRewardForDuration();
    }

    function  earned(address account) public view returns(uint256) 
    {
        return _balances[account] * (_stake.rewardPerToken(_totalStake) - _userRewardPerTokenPaid[account]) / 1e18 + _rewards[account];
    }

    // STEP 6: Build the writable functions
    /** 
    ** Stake | Claim - getReward | Withdraw - exit | depositRewardsToken
    */
    function stake(uint256 _amount) external payable nonReentrant updateRewards(msg.sender) {
        require(_amount > 0, "Stake must be greater than zero");

        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        _totalStake += _amount;
        _balances[msg.sender] += _amount;

        // Emit an Event
        emit Staked(msg.sender, _amount);
    }

    function getReward() public payable nonReentrant updateRewards(msg.sender) {
        uint256 reward = _rewards[msg.sender];

        if(reward > 0) {
            _rewards[msg.sender] = 0;
            rewardToken.safeTransfer(msg.sender, reward);

            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external payable nonReentrant {
        _stake.updateReward(_totalStake);

        uint256 balance = _balances[msg.sender];
        uint256 reward = earned(msg.sender);

        _userRewardPerTokenPaid[msg.sender] = _stake.rewardPerTokenStored;
        _balances[msg.sender] -= balance;
        _rewards[msg.sender] = 0;
        _totalStake -= balance;

        _stake.updateReward(_totalStake);
        
        if (stakingToken == rewardToken) {
            stakingToken.safeTransfer(msg.sender, balance + reward);
        }
        else{
            stakingToken.safeTransfer(msg.sender, balance);
            rewardToken.safeTransfer(msg.sender, reward);
        }

        emit Withdrawn(msg.sender, balance);
        emit RewardPaid(msg.sender, reward);
    }

    ////////////////////// PROTECTED FUNCTIONS /////////////////////
    // STEP 7: Add protected functions for reward distributor
    function setDistributor(address newDistributor) external payable onlyDistributor
    {
        require(newDistributor != address(0), "Cannot set to zero addr");
        _stake.distributor = uint160(newDistributor);
    }

    function depositRewardTokens(uint256 amount) external payable onlyDistributor
    {
        require(amount > 0, "Must be greater than zero");

        rewardToken.safeTransferFrom(msg.sender, address(this), amount);

        notifyRewardAmount(amount);
    }

    function notifyRewardAmount(uint256 reward) public payable updateRewards(address(0)) onlyDistributor
    {
        uint256 duration = _stake.rewardsDuration;

        if (block.timestamp >= _stake.periodFinish) {
            _stake.rewardRate = reward / duration;
        } else {
            uint256 remaining = _stake.periodFinish - block.timestamp;
            uint256 leftover = remaining * _stake.rewardRate;
            _stake.rewardRate = (reward + leftover) / duration;
        }

        uint256 balance = rewardToken.balanceOf(address(this));

        if (rewardToken == stakingToken) {
            balance -= _totalStake;
        }

        require(_stake.rewardRate <= balance / duration, "Reward too high");

        _stake.lastUpdateTime = uint64(block.timestamp);
        _stake.periodFinish = uint64(block.timestamp + duration);

        emit RewardAdded(reward);
    }

    /* ========== EVENTS ========== */
    // STEP 8: Emit events
    event RewardAdded(uint256 reward);
    event Withdrawn(address indexed user, uint256 _amount);
    event RewardPaid(address indexed user, uint256 reward);
    event DistributorUpdated(address indexed newDistributor);
    event Staked(address indexed user, uint256 _amount);
    
}