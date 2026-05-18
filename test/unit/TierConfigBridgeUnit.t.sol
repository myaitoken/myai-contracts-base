// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {TierConfigBridge} from "../../contracts/TierConfigBridge.sol";

contract TierConfigBridgeUnitTest is Test {
    event TierConfigUpdated(
        string  indexed tier,
        int128  maxAgentsPerWallet,
        int128  dailyEarningsCapPerWalletMyai,
        int128  dailyEmissionCapMyai,
        uint64  multiplierAttestedBps,
        uint64  multiplierUnattestedBps,
        uint64  slashCapPctBps
    );

    TierConfigBridge public bridge;
    address governance = address(0xC0DE);
    address attacker   = address(0xBAD);

    function setUp() public {
        bridge = new TierConfigBridge(governance);
    }

    // 1. Constructor wires governance and rejects zero address.
    function test_constructor_sets_governance() public {
        assertEq(bridge.governance(), governance);
    }

    function test_constructor_rejects_zero() public {
        vm.expectRevert(TierConfigBridge.ZeroGovernance.selector);
        new TierConfigBridge(address(0));
    }

    // 2. setTier from governance: OK.
    function test_setTier_from_governance_ok() public {
        TierConfigBridge.TierCfg memory cfg = TierConfigBridge.TierCfg({
            maxAgentsPerWallet: int128(3),
            dailyEarningsCapPerWalletMyai: int128(1000),
            dailyEmissionCapMyai: int128(75000),
            multiplierAttestedBps: uint64(10000),
            multiplierUnattestedBps: uint64(5000),
            slashCapPctBps: uint64(5000)
        });
        vm.prank(governance);
        bridge.setTier("browser", cfg);
        assertTrue(bridge.initialised("browser"));
    }

    // 3. setTier from non-governance reverts with NotGovernance.
    function test_setTier_from_non_governance_reverts() public {
        TierConfigBridge.TierCfg memory cfg;
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(TierConfigBridge.NotGovernance.selector, attacker));
        bridge.setTier("browser", cfg);
    }

    // 3b. setTier rejects unknown tier names (defence in depth).
    function test_setTier_rejects_unknown_tier() public {
        TierConfigBridge.TierCfg memory cfg;
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(TierConfigBridge.UnknownTier.selector, "bogus"));
        bridge.setTier("bogus", cfg);
    }

    // 4. Event emitted with correct values.
    function test_setTier_emits_event() public {
        TierConfigBridge.TierCfg memory cfg = TierConfigBridge.TierCfg({
            maxAgentsPerWallet: int128(5),
            dailyEarningsCapPerWalletMyai: int128(2000),
            dailyEmissionCapMyai: int128(60000),
            multiplierAttestedBps: uint64(11000),
            multiplierUnattestedBps: uint64(6000),
            slashCapPctBps: uint64(4000)
        });
        vm.expectEmit(true, false, false, true);
        emit TierConfigUpdated(
            "browser",
            int128(5),
            int128(2000),
            int128(60000),
            uint64(11000),
            uint64(6000),
            uint64(4000)
        );
        vm.prank(governance);
        bridge.setTier("browser", cfg);
    }

    // 5. Packed-struct round-trip: write then read returns identical values.
    function test_packed_struct_round_trip() public {
        TierConfigBridge.TierCfg memory cfg = TierConfigBridge.TierCfg({
            maxAgentsPerWallet: int128(-1),
            dailyEarningsCapPerWalletMyai: int128(-1),
            dailyEmissionCapMyai: int128(200000),
            multiplierAttestedBps: uint64(10000),
            multiplierUnattestedBps: uint64(10000),
            slashCapPctBps: uint64(5000)
        });
        vm.prank(governance);
        bridge.setTier("datacenter", cfg);

        TierConfigBridge.TierCfg memory got = bridge.getTier("datacenter");
        assertEq(got.maxAgentsPerWallet, int128(-1));
        assertEq(got.dailyEarningsCapPerWalletMyai, int128(-1));
        assertEq(got.dailyEmissionCapMyai, int128(200000));
        assertEq(uint256(got.multiplierAttestedBps), uint256(10000));
        assertEq(uint256(got.multiplierUnattestedBps), uint256(10000));
        assertEq(uint256(got.slashCapPctBps), uint256(5000));
    }
}
