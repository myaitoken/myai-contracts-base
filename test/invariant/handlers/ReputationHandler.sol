// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {MyAIReputation} from "../../../contracts/MyAIReputation.sol";
import {MockERC20} from "../../../contracts/mocks/MockERC20.sol";

contract ReputationHandler is CommonBase, StdCheats, StdUtils {
    MyAIReputation public rep;
    MockERC20 public token;
    address public coordinator;
    address[] public actors;

    uint256 public ghostTotalStaked;
    mapping(address => uint256) public ghostStakeOf;
    mapping(address => uint256) public ghostSuccessJobs;
    mapping(address => uint256) public ghostTotalJobs;
    mapping(address => uint256) public ghostLatencySum;
    mapping(address => bool) public registered;
    address[] public actorsTouched;

    constructor(MyAIReputation _rep, MockERC20 _token, address _coordinator, address[] memory _actors) {
        rep = _rep;
        token = _token;
        coordinator = _coordinator;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function register(uint256 actorSeed) external {
        address a = _actor(actorSeed);
        if (registered[a]) return;
        vm.prank(a);
        try rep.register() {
            registered[a] = true;
            actorsTouched.push(a);
        } catch {}
    }

    function recordCompletion(uint256 actorSeed, bool pocPassed, uint256 latencyMs, uint256 tokens) external {
        address provider = _actor(actorSeed);
        latencyMs = bound(latencyMs, 0, 60_000);
        tokens = bound(tokens, 0, 1_000_000);
        vm.prank(coordinator);
        try rep.recordCompletion(provider, pocPassed, latencyMs, tokens) {
            if (!registered[provider]) {
                registered[provider] = true;
                actorsTouched.push(provider);
            }
            ghostTotalJobs[provider] += 1;
            if (pocPassed) {
                ghostSuccessJobs[provider] += 1;
                ghostLatencySum[provider] += latencyMs;
            }
        } catch {}
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        amount = bound(amount, 1, 100 ether);
        if (token.balanceOf(a) < amount) {
            deal(address(token), a, token.balanceOf(a) + amount);
        }
        vm.startPrank(a);
        token.approve(address(rep), amount);
        try rep.stake(amount) {
            ghostStakeOf[a] += amount;
            ghostTotalStaked += amount;
            if (!registered[a]) {
                registered[a] = true;
                actorsTouched.push(a);
            }
        } catch {}
        vm.stopPrank();
    }

    function touched(uint256 i) external view returns (address) { return actorsTouched[i]; }
    function touchedCount() external view returns (uint256) { return actorsTouched.length; }
}
