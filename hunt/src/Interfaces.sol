// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IUUPS {
    function upgradeTo(address) external;
    function upgradeToAndCall(address, bytes calldata) external payable;
}

interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address) external;
}

interface IRewardPool {
    function rewardPools(uint256)
        external
        view
        returns (
            uint128 payoutStart,
            uint128 decreaseInterval,
            uint256 initialReward,
            uint256 rewardDecrease,
            bool isPublic
        );

    function getPeriodRewards(uint256 index, uint128 startTime, uint128 endTime) external view returns (uint256);
    function isRewardPoolPublic(uint256) external view returns (bool);
}

interface IChainlinkConsumer {
    function getPathId(string memory path) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId) external view returns (uint256);
    function allowedPriceUpdateDelay(address feed) external view returns (uint64);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex) external;
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function minRewardsDistributePeriod() external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function undistributedRewards() external view returns (uint256);
    function l1Sender() external view returns (address);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex, uint256 amount, uint128 claimLockEnd, address referrer) external;
    function withdraw(uint256 rewardPoolIndex, uint256 amount) external;
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (
            uint128 withdrawLockPeriodAfterStake,
            uint128 claimLockPeriodAfterStake,
            uint128 claimLockPeriodAfterClaim,
            uint256 minimalStake,
            uint256 distributedRewards
        );
    function rewardPoolsData(uint256) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function usersData(address, uint256)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function referrerTiers(uint256, uint256) external view returns (uint256 amount, uint256 multiplier);
    function distributor() external view returns (address);
    function depositToken() external view returns (address);
}

interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IPoolAddressesProvider {
    function getPool() external view returns (address);
}
