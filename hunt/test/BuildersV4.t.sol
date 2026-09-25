// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {IERC20, IUUPS} from "../src/Interfaces.sol";
import {Forks} from "./Forks.sol";

interface IBuildersV4 {
    struct Subnet {
        string name;
        address admin;
        uint128 unused1;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unused2;
        uint256 minimalDeposit;
        address claimAdmin;
    }

    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function createSubnet(Subnet calldata subnet, SubnetMetadata calldata metadata) external;
    function deposit(bytes32 subnetId, uint256 amount) external;
    function withdraw(bytes32 subnetId, uint256 amount) external;
    function claim(bytes32 subnetId, address receiver) external;
    function getSubnetId(string memory name) external view returns (bytes32);
    function getCurrentSubnetRewards(bytes32 subnetId) external view returns (uint256);
    function minimalWithdrawLockPeriod() external view returns (uint256);
    function subnetCreationFeeAmount() external view returns (uint256);
    function depositToken() external view returns (address);
    function buildersTreasury() external view returns (address);
    function feeConfig() external view returns (address);
    function networkShare() external view returns (uint256);
    function allSubnetsData() external view returns (uint256, uint256, uint256, uint256);
    function setNetworkShare(uint256) external;
    function version() external pure returns (uint256);
}

interface IFeeConfig {
    function getFeeAndTreasuryForOperation(address sender, bytes32 operation) external view returns (uint256, address);
}

interface ITreasury {
    function withdraw(address receiver, uint256 amount) external;
    function sendRewards(address receiver, uint256 amount) external;
}

/// @notice Hypothesis D: new subnet inherits historical rewards, claim changes
/// deposits, or an unprivileged caller pulls the treasury.
contract BuildersV4Test is Forks {
    address internal constant BUILDERS = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    uint256 internal constant PRECISION = 1e25;

    function setUp() public {
        _forkBase();
    }

    function test_contract_is_solvent_and_unprivileged_cannot_touch_admin_flows() public {
        IBuildersV4 b = IBuildersV4(BUILDERS);
        assertEq(b.version(), 4, "not BuildersV4");
        address mor = b.depositToken();
        (, , uint256 totalDeposited,) = b.allSubnetsData();
        assertEq(IERC20(mor).balanceOf(BUILDERS), totalDeposited, "MOR balance != totalDeposited");
        console2.log("builders totalDeposited", totalDeposited);

        address attacker = makeAddr("builders-attacker");
        address treasury = b.buildersTreasury();
        vm.startPrank(attacker);
        vm.expectRevert();
        b.setNetworkShare(PRECISION);
        vm.expectRevert();
        ITreasury(treasury).withdraw(attacker, 1);
        vm.expectRevert();
        ITreasury(treasury).sendRewards(attacker, 1);
        vm.expectRevert();
        IUUPS(BUILDERS).upgradeTo(attacker);
        vm.expectRevert();
        IUUPS(treasury).upgradeTo(attacker);
        vm.stopPrank();
    }

    function test_new_subnet_gets_no_historical_rewards_and_claim_is_pro_rata() public {
        IBuildersV4 b = IBuildersV4(BUILDERS);
        address mor = b.depositToken();
        uint256 lock = b.minimalWithdrawLockPeriod();
        uint256 fee = b.subnetCreationFeeAmount();
        (, , uint256 depositedBefore,) = b.allSubnetsData();
        assertEq(IERC20(mor).balanceOf(BUILDERS), depositedBefore, "insolvent before");

        // Let existing subnets accrue, then join. A new subnet must start at zero.
        vm.warp(block.timestamp + 30 days);

        address adminA = makeAddr("subnet-a");
        address adminB = makeAddr("subnet-b");
        address stranger = makeAddr("subnet-stranger");
        uint256 amountA = 1_000 ether;
        uint256 amountB = 3_000 ether;

        bytes32 idA = _createAndDeposit(b, mor, adminA, "cursor-hunt-a-cfe6", lock, fee, amountA);
        bytes32 idB = _createAndDeposit(b, mor, adminB, "cursor-hunt-b-cfe6", lock, fee, amountB);

        assertEq(b.getCurrentSubnetRewards(idA), 0, "new subnet inherited historical rewards");
        assertEq(b.getCurrentSubnetRewards(idB), 0, "new subnet inherited historical rewards");

        (, , uint256 depositedMid,) = b.allSubnetsData();
        assertEq(depositedMid, depositedBefore + amountA + amountB, "deposit accounting");
        assertEq(IERC20(mor).balanceOf(BUILDERS), depositedMid, "insolvent after deposit");

        vm.warp(block.timestamp + 14 days);
        uint256 owedA = b.getCurrentSubnetRewards(idA);
        uint256 owedB = b.getCurrentSubnetRewards(idB);
        console2.log("owed A", owedA);
        console2.log("owed B", owedB);
        assertGt(owedB, 0, "no rewards accrued");
        assertApproxEqRel(owedA * 3, owedB, 0.001e18, "rewards are not proportional to stake");

        vm.prank(stranger);
        vm.expectRevert();
        b.claim(idB, stranger);
        assertEq(b.getCurrentSubnetRewards(idB), owedB, "stranger claim mutated rewards");

        (uint256 feePart, address feeTreasury) = IFeeConfig(b.feeConfig()).getFeeAndTreasuryForOperation(
            BUILDERS, bytes32("claim")
        );
        uint256 feeAmount = (owedB * feePart) / PRECISION;
        uint256 adminBefore = IERC20(mor).balanceOf(adminB);
        uint256 treasuryBefore = IERC20(mor).balanceOf(feeTreasury);
        (, , uint256 depositedAtClaim,) = b.allSubnetsData();

        vm.prank(adminB);
        b.claim(idB, adminB);

        (, , uint256 depositedAfterClaim,) = b.allSubnetsData();
        assertEq(depositedAfterClaim, depositedAtClaim, "claim changed deposits");
        assertEq(IERC20(mor).balanceOf(BUILDERS), depositedAfterClaim, "claim moved staked MOR");

        uint256 adminGain = IERC20(mor).balanceOf(adminB) - adminBefore;
        uint256 feeGain = IERC20(mor).balanceOf(feeTreasury) - treasuryBefore;
        console2.log("admin gain", adminGain);
        console2.log("fee gain", feeGain);
        assertApproxEqAbs(adminGain + feeGain, owedB, 2, "claim paid a different amount than owed");
        assertLe(adminGain, owedB, "admin received more than owed");

        vm.warp(block.timestamp + lock + 1);
        uint256 balBefore = IERC20(mor).balanceOf(adminA);
        vm.prank(adminA);
        b.withdraw(idA, amountA);
        assertEq(IERC20(mor).balanceOf(adminA) - balBefore, amountA, "withdraw did not return the deposit");
        (, , uint256 depositedFinal,) = b.allSubnetsData();
        assertEq(IERC20(mor).balanceOf(BUILDERS), depositedFinal, "insolvent after withdraw");
    }

    function _createAndDeposit(
        IBuildersV4 b,
        address mor,
        address admin,
        string memory name,
        uint256 lock,
        uint256 creationFee,
        uint256 amount
    ) internal returns (bytes32 id) {
        IBuildersV4.Subnet memory subnet = IBuildersV4.Subnet({
            name: name,
            admin: admin,
            unused1: 0,
            withdrawLockPeriodAfterDeposit: uint128(lock),
            unused2: 0,
            minimalDeposit: 1 ether,
            claimAdmin: admin
        });
        IBuildersV4.SubnetMetadata memory meta = IBuildersV4.SubnetMetadata({
            slug: name,
            description: "hunt",
            website: "https://hunt.invalid",
            image: ""
        });
        deal(mor, admin, amount + creationFee + 1 ether);
        vm.startPrank(admin);
        IERC20(mor).approve(BUILDERS, type(uint256).max);
        b.createSubnet(subnet, meta);
        id = b.getSubnetId(name);
        b.deposit(id, amount);
        vm.stopPrank();
    }
}
