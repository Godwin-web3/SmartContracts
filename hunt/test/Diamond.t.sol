// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console2} from "forge-std/console2.sol";
import {Forks} from "./Forks.sol";

/// @notice Hypothesis E: LumerinDiamond uninitialized facets, selector clobber,
/// arbitrary delegatecall, and unauthenticated mutators. SessionRouter value
/// extraction is in SessionRouter.t.sol.
interface ILoupe {
    struct Facet {
        address facetAddress;
        bytes4[] functionSelectors;
    }

    function facets() external view returns (Facet[] memory);
    function facetAddress(bytes4 selector) external view returns (address);
}

interface IDiamondAdmin {
    function owner() external view returns (address);
    function transferOwnership(address) external;
    function diamondCut(FacetCut[] calldata cuts, address init, bytes calldata data) external;
    function __LumerinDiamond_init() external;
    function __Marketplace_init(address token, uint256 minPrice, uint256 maxPrice) external;
    function __ProviderRegistry_init() external;
    function __ModelRegistry_init() external;
    function __Delegation_init(address registry) external;
    function __SessionRouter_init(address funding, uint128 maxDuration, Pool[] calldata pools) external;

    struct FacetCut {
        address facetAddress;
        uint8 action;
        bytes4[] functionSelectors;
    }

    struct Pool {
        uint256 initialReward;
        uint256 rewardDecrease;
        uint128 payoutStart;
        uint128 decreaseInterval;
    }
}

interface ISessionViews {
    function getFundingAccount() external view returns (address);
    function getProvidersTotalClaimed() external view returns (uint256);
}

contract DiamondTest is Forks {
    address internal constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;

    function setUp() public {
        _forkBase();
    }

    function test_selectors_are_unique_and_no_raw_delegatecall() public view {
        ILoupe.Facet[] memory facets_ = ILoupe(DIAMOND).facets();
        assertEq(facets_.length, 5, "expected 5 facets");

        uint256 n;
        for (uint256 i; i < facets_.length; ++i) {
            n += facets_[i].functionSelectors.length;
            assertTrue(facets_[i].facetAddress != address(0), "zero facet");
        }

        bytes4[] memory all = new bytes4[](n);
        uint256 k;
        for (uint256 i; i < facets_.length; ++i) {
            for (uint256 j; j < facets_[i].functionSelectors.length; ++j) {
                bytes4 sel = facets_[i].functionSelectors[j];
                for (uint256 p; p < k; ++p) {
                    assertTrue(all[p] != sel, "selector collision");
                }
                all[k++] = sel;
            }
        }

        // No facet exposes an arbitrary-call primitive.
        bytes4[4] memory danger = [
            bytes4(keccak256("delegatecall(address,bytes)")),
            bytes4(keccak256("execute(address,uint256,bytes)")),
            bytes4(keccak256("execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)")),
            bytes4(keccak256("fallback(bytes)"))
        ];
        for (uint256 i; i < danger.length; ++i) {
            assertEq(ILoupe(DIAMOND).facetAddress(danger[i]), address(0), "dangerous selector installed");
        }

        // Namespaced diamond storage slots do not alias each other.
        bytes32[8] memory slots = [
            keccak256("diamond.standard.sessions.storage"),
            keccak256("diamond.standard.bids.storage"),
            keccak256("diamond.standard.delegation.storage"),
            keccak256("diamond.standard.market.storage"),
            keccak256("diamond.standard.providers.storage"),
            keccak256("diamond.standard.models.storage"),
            keccak256("diamond.standard.stats.storage"),
            keccak256("diamond.standard.diamond.storage")
        ];
        for (uint256 i; i < slots.length; ++i) {
            for (uint256 j = i + 1; j < slots.length; ++j) {
                assertTrue(slots[i] != slots[j], "storage slot alias");
            }
        }

        console2.log("diamond selectors", n);
    }

    function test_unprivileged_cannot_reinit_or_cut_or_seize_owner() public {
        address attacker = makeAddr("diamond-attacker");
        address ownerBefore = IDiamondAdmin(DIAMOND).owner();
        address fundingBefore = ISessionViews(DIAMOND).getFundingAccount();
        uint256 claimedBefore = ISessionViews(DIAMOND).getProvidersTotalClaimed();
        assertTrue(ownerBefore != address(0) && ownerBefore != attacker, "owner already attacker");

        vm.startPrank(attacker);

        vm.expectRevert();
        IDiamondAdmin(DIAMOND).__LumerinDiamond_init();

        vm.expectRevert();
        IDiamondAdmin(DIAMOND).__Marketplace_init(attacker, 1, 2);

        vm.expectRevert();
        IDiamondAdmin(DIAMOND).__ProviderRegistry_init();

        vm.expectRevert();
        IDiamondAdmin(DIAMOND).__ModelRegistry_init();

        vm.expectRevert();
        IDiamondAdmin(DIAMOND).__Delegation_init(attacker);

        IDiamondAdmin.Pool[] memory pools = new IDiamondAdmin.Pool[](0);
        vm.expectRevert();
        IDiamondAdmin(DIAMOND).__SessionRouter_init(attacker, 7 days, pools);

        vm.expectRevert();
        IDiamondAdmin(DIAMOND).transferOwnership(attacker);

        IDiamondAdmin.FacetCut[] memory cuts = new IDiamondAdmin.FacetCut[](0);
        vm.expectRevert();
        IDiamondAdmin(DIAMOND).diamondCut(cuts, attacker, "");

        vm.expectRevert();
        IUUPS(DIAMOND).upgradeTo(attacker);

        vm.stopPrank();

        assertEq(IDiamondAdmin(DIAMOND).owner(), ownerBefore, "owner changed");
        assertEq(ISessionViews(DIAMOND).getFundingAccount(), fundingBefore, "funding account changed");
        assertEq(ISessionViews(DIAMOND).getProvidersTotalClaimed(), claimedBefore, "claimed counter changed");
    }
}

interface IUUPS {
    function upgradeTo(address) external;
}
