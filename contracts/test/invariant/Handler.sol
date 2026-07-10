// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {RWAVault} from "../../src/RWAVault.sol";
import {Escrow} from "../../src/Escrow.sol";
import {NAVOracle} from "../../src/NAVOracle.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";
import {TBillToken} from "../../src/mocks/TBillToken.sol";

/// @notice Bounded, revert-free action driver for the invariant campaign.
///
/// Design:
///  - The suite runs with `fail-on-revert = true`, so every action guards its
///    own preconditions (busy slot, empty balances, epoch state) and no-ops
///    when an action is illegal — a revert reaching the runner IS a finding.
///  - Ghost accounting mirrors OBSERVED contract effects: entitlements are
///    measured as max*-view deltas across `fulfillEpoch()` (black-box), never
///    recomputed from the vault's own formulas — the invariants compare the
///    implementation against itself across time, not against a copy of its
///    math.
///  - Ghosts roll entitlements eagerly at fulfillment while the contract
///    rolls lazily: legitimate, because the escrow-level identity checked by
///    I4 (pendings + unclaimed + dust) is invariant to WHEN the roll happens.
///  - Dust is tracked on BOTH sides (share dust from sharesMinted, asset dust
///    from assetsSetAside) — I4 is an exact equality, not a >=.
///
/// Assertion placement: I1/I2/I3 fire at each fulfillment; I5/I6 wrap every
/// non-fulfill action; I4/I7/I9 are re-checked globally by the invariant_*
/// functions of the test contract after every call.
contract Handler is Test {
    uint256 internal constant ONE_SHARE = 1e6;
    uint256 internal constant MAX_REQUEST = 10_000_000e6; // 10M USDC/shares per action

    RWAVault public vault;
    Escrow public escrow;
    MockUSDC public usdc;
    TBillToken public tbill;
    NAVOracle public oracle;
    address public manager;
    address public oracleOwner;

    address[] public actors;

    // ---------------- ghost accounting ----------------

    /// @dev Σ deposit pendings sitting in OPEN or CLOSED-unfulfilled epochs.
    uint256 public ghostPendingDepositAssets;
    /// @dev Σ redeem pendings sitting in OPEN or CLOSED-unfulfilled epochs.
    uint256 public ghostPendingRedeemShares;
    /// @dev Σ entitled − Σ paid, deposit side (shares awaiting claim).
    uint256 public ghostUnclaimedDepositShares;
    /// @dev Σ entitled − Σ paid, redeem side (assets awaiting claim).
    uint256 public ghostUnclaimedRedeemAssets;
    /// @dev Σ over fulfilled epochs of (sharesMinted − Σ entitled shares).
    uint256 public ghostDepositShareDust;
    /// @dev Σ over fulfilled epochs of (assetsSetAside − Σ entitled assets).
    uint256 public ghostRedeemAssetDust;

    // lifetime per-controller ledgers (I7)
    mapping(address => uint256) public ghostEntitledShares;
    mapping(address => uint256) public ghostPaidShares;
    mapping(address => uint256) public ghostEntitledAssets;
    mapping(address => uint256) public ghostPaidAssets;

    /// @dev Snapshot of a fulfilled epoch, for I2 re-checks and I9
    /// immutability (the recorded batch results must never change).
    struct GhostEpoch {
        bool fulfilled;
        uint256 totalDepositAssets;
        uint256 totalRedeemShares;
        uint256 sharesMinted;
        uint256 assetsSetAside;
        uint256 sumEntitledShares;
        uint256 sumEntitledAssets;
        uint256 depositRequesters;
        uint256 redeemRequesters;
    }

    mapping(uint256 => GhostEpoch) internal _ghostEpochs;

    /// @dev Working set for fulfillEpoch, kept in memory to stay clear of
    /// stack-too-deep while asserting I1/I2/I3/I5 in one pass.
    struct FulfillSnap {
        uint256 id;
        uint256 totDep;
        uint256 totRed;
        uint256 minted;
        uint256 setAside;
        uint256[] pendDep;
        uint256[] pendRed;
        uint256[] entShares;
        uint256[] entAssets;
    }

    constructor(
        RWAVault vault_,
        MockUSDC usdc_,
        TBillToken tbill_,
        NAVOracle oracle_,
        address manager_,
        address oracleOwner_
    ) {
        vault = vault_;
        escrow = vault_.escrow();
        usdc = usdc_;
        tbill = tbill_;
        oracle = oracle_;
        manager = manager_;
        oracleOwner = oracleOwner_;

        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
        actors.push(makeAddr("actor4"));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function ghostEpoch(uint256 id) external view returns (GhostEpoch memory) {
        return _ghostEpochs[id];
    }

    // ==================================================================
    // Investor actions
    // ==================================================================

    function requestDeposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        if (_slotBusy(true, actor)) return; // D4: CLOSED-unfulfilled window
        assets = bound(assets, 1, MAX_REQUEST);
        usdc.mint(actor, assets);

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        vm.startPrank(actor);
        usdc.approve(address(vault), assets);
        uint256 id = vault.requestDeposit(assets, actor, actor);
        vm.stopPrank();

        assertEq(id, vault.currentEpochId(), "request must join the OPEN epoch");
        _assertUnmoved(supplyBefore, ppsBefore, "requestDeposit");
        ghostPendingDepositAssets += assets;
    }

    function requestRedeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        if (_slotBusy(false, actor)) return;
        shares = bound(shares, 1, Math.min(bal, MAX_REQUEST));

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        vm.prank(actor);
        uint256 id = vault.requestRedeem(shares, actor, actor);

        assertEq(id, vault.currentEpochId(), "request must join the OPEN epoch");
        _assertUnmoved(supplyBefore, ppsBefore, "requestRedeem");
        ghostPendingRedeemShares += shares;
    }

    function cancelDeposit(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        (uint128 pending, uint64 slotEpoch) = vault.depositSlot(actor);
        if (pending == 0 || slotEpoch != vault.currentEpochId()) return; // only OPEN is cancelable

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        uint256 balBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        uint256 refunded = vault.cancelDepositRequest(actor);

        assertEq(refunded, uint256(pending), "cancel must refund the full pending");
        assertEq(usdc.balanceOf(actor) - balBefore, refunded, "refund must reach the controller");
        _assertUnmoved(supplyBefore, ppsBefore, "cancelDeposit");
        ghostPendingDepositAssets -= refunded;
    }

    function cancelRedeem(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        (uint128 pending, uint64 slotEpoch) = vault.redeemSlot(actor);
        if (pending == 0 || slotEpoch != vault.currentEpochId()) return;

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        uint256 balBefore = vault.balanceOf(actor);
        vm.prank(actor);
        uint256 refunded = vault.cancelRedeemRequest(actor);

        assertEq(refunded, uint256(pending), "cancel must refund the full pending");
        assertEq(vault.balanceOf(actor) - balBefore, refunded, "shares must return to the controller");
        _assertUnmoved(supplyBefore, ppsBefore, "cancelRedeem");
        ghostPendingRedeemShares -= refunded;
    }

    // ==================================================================
    // Claims
    // ==================================================================

    function claimDeposit(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        uint256 maxAssets = vault.maxDeposit(actor);
        if (maxAssets == 0) return;
        assets = bound(assets, 1, maxAssets);

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        uint256 balBefore = vault.balanceOf(actor);
        vm.prank(actor);
        uint256 sharesOut = vault.deposit(assets, actor, actor);

        assertEq(vault.balanceOf(actor) - balBefore, sharesOut, "claim must deliver the returned shares");
        _assertUnmoved(supplyBefore, ppsBefore, "claimDeposit");
        ghostUnclaimedDepositShares -= sharesOut;
        ghostPaidShares[actor] += sharesOut;
    }

    function claimMint(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 maxShares = vault.maxMint(actor);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        uint256 balBefore = vault.balanceOf(actor);
        vm.prank(actor);
        vault.mint(shares, actor, actor);

        assertEq(vault.balanceOf(actor) - balBefore, shares, "mint claim must deliver the requested shares");
        _assertUnmoved(supplyBefore, ppsBefore, "claimMint");
        ghostUnclaimedDepositShares -= shares;
        ghostPaidShares[actor] += shares;
    }

    function claimWithdraw(uint256 actorSeed, uint256 assets) external {
        address actor = _actor(actorSeed);
        uint256 maxAssets = vault.maxWithdraw(actor);
        if (maxAssets == 0) return;
        assets = bound(assets, 1, maxAssets);

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        uint256 balBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        vault.withdraw(assets, actor, actor);

        assertEq(usdc.balanceOf(actor) - balBefore, assets, "withdraw claim must pay the requested assets");
        _assertUnmoved(supplyBefore, ppsBefore, "claimWithdraw");
        ghostUnclaimedRedeemAssets -= assets;
        ghostPaidAssets[actor] += assets;
    }

    function claimRedeem(uint256 actorSeed, uint256 shares) external {
        address actor = _actor(actorSeed);
        uint256 maxShares = vault.maxRedeem(actor);
        if (maxShares == 0) return;
        shares = bound(shares, 1, maxShares);

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        uint256 balBefore = usdc.balanceOf(actor);
        vm.prank(actor);
        uint256 assetsOut = vault.redeem(shares, actor, actor);

        assertEq(usdc.balanceOf(actor) - balBefore, assetsOut, "redeem claim must pay the returned assets");
        _assertUnmoved(supplyBefore, ppsBefore, "claimRedeem");
        ghostUnclaimedRedeemAssets -= assetsOut;
        ghostPaidAssets[actor] += assetsOut;
    }

    // ==================================================================
    // Epoch machine (manager)
    // ==================================================================

    function closeEpoch() external {
        uint256 open = vault.currentEpochId();
        if (open > 1 && _fulfilledAt(open - 1) == 0) return; // one settling epoch max (I9)

        (uint256 supplyBefore, uint256 ppsBefore) = _snap();
        vm.prank(manager);
        vault.closeEpoch();

        assertEq(vault.currentEpochId(), open + 1, "cut-off must open the next epoch");
        _assertUnmoved(supplyBefore, ppsBefore, "closeEpoch");
    }

    function fulfillEpoch() external {
        uint256 open = vault.currentEpochId();
        if (open < 2) return;

        FulfillSnap memory s;
        s.id = open - 1;
        if (_cutoffAt(s.id) == 0 || _fulfilledAt(s.id) != 0) return;
        (s.totDep, s.totRed,,,,) = vault.epochs(s.id);

        _ensurePayoutCash(s.totDep, s.totRed);

        // pre-settlement snapshot: per-actor pendings in this epoch and
        // claimable views (the black-box entitlement baseline)
        uint256 n = actors.length;
        s.pendDep = new uint256[](n);
        s.pendRed = new uint256[](n);
        uint256[] memory sharesBefore = new uint256[](n);
        uint256[] memory assetsBefore = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (uint128 p, uint64 e) = vault.depositSlot(actors[i]);
            if (p != 0 && e == s.id) s.pendDep[i] = p;
            (p, e) = vault.redeemSlot(actors[i]);
            if (p != 0 && e == s.id) s.pendRed[i] = p;
            sharesBefore[i] = vault.maxMint(actors[i]);
            assetsBefore[i] = vault.maxWithdraw(actors[i]);
        }

        uint256 p0 = vault.convertToAssets(ONE_SHARE);
        uint256 supplyBefore = vault.totalSupply();

        vm.prank(manager);
        vault.fulfillEpoch();

        (,, s.minted, s.setAside,,) = vault.epochs(s.id);
        assertTrue(_fulfilledAt(s.id) != 0, "epoch must record its fulfillment");

        // I5: supply moves ONLY here, by exactly the recorded batch net
        assertEq(vault.totalSupply(), supplyBefore + s.minted - s.totRed, "I5: settlement supply delta");

        // I3: NAV continuity — never down, up only by bounded rounding dust
        uint256 p1 = vault.convertToAssets(ONE_SHARE);
        assertGe(p1, p0, "I3: fulfillment diluted remaining holders");
        assertLe(p1 - p0, (p0 + ONE_SHARE + 1) / (vault.totalSupply() + 1) + 2, "I3: drift beyond rounding dust");

        // black-box entitlements: what each actor's claimable views gained
        s.entShares = new uint256[](n);
        s.entAssets = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            s.entShares[i] = vault.maxMint(actors[i]) - sharesBefore[i];
            s.entAssets[i] = vault.maxWithdraw(actors[i]) - assetsBefore[i];
        }

        _checkAndRecord(s);
    }

    // ==================================================================
    // Environment (manager / oracle admin / time)
    // ==================================================================

    function warpTime(uint256 secs) external {
        secs = bound(secs, 1, 6 hours); // ≈ up to 360 simulated days at scale 1440
        vm.warp(block.timestamp + secs);
    }

    function shockNAV(int256 shockBps) external {
        shockBps = bound(shockBps, -2_000, 2_000); // ±20% mark-to-market move
        if (shockBps == 0) return;
        vm.prank(oracleOwner);
        oracle.applyShock(shockBps);
    }

    function invest(uint256 assets) external {
        uint256 cash = usdc.balanceOf(address(vault));
        if (cash == 0) return;
        assets = bound(assets, 1, cash);
        if ((assets * oracle.PRICE_SCALE()) / oracle.price() == 0) return; // would round to zero

        uint256 taBefore = vault.totalAssets();
        vm.prank(manager);
        vault.invest(assets);
        uint256 taAfter = vault.totalAssets();

        assertLe(taAfter, taBefore + 1, "invest created value");
        if (taBefore > taAfter) {
            assertLe(taBefore - taAfter, oracle.price() / oracle.PRICE_SCALE() + 2, "invest lost more than floor dust");
        }
    }

    function divest(uint256 tbillAmount) external {
        uint256 tb = tbill.balanceOf(address(vault));
        if (tb == 0) return;
        tbillAmount = bound(tbillAmount, 1, tb);
        if ((tbillAmount * oracle.price()) / oracle.PRICE_SCALE() == 0) return; // would round to zero

        uint256 taBefore = vault.totalAssets();
        vm.prank(manager);
        vault.divest(tbillAmount);
        uint256 taAfter = vault.totalAssets();

        assertLe(taAfter, taBefore + 1, "divest created value");
        if (taBefore > taAfter) {
            assertLe(taBefore - taAfter, oracle.price() / oracle.PRICE_SCALE() + 2, "divest lost more than floor dust");
        }
    }

    // ==================================================================
    // Internals
    // ==================================================================

    /// @dev I2 conservation, I1 pairwise rate equality, ghost roll + epoch
    /// snapshot. Split from fulfillEpoch to stay clear of stack-too-deep.
    function _checkAndRecord(FulfillSnap memory s) internal {
        GhostEpoch storage g = _ghostEpochs[s.id];
        g.fulfilled = true;
        g.totalDepositAssets = s.totDep;
        g.totalRedeemShares = s.totRed;
        g.sharesMinted = s.minted;
        g.assetsSetAside = s.setAside;

        uint256 sumPendDep;
        uint256 sumPendRed;
        for (uint256 i; i < s.pendDep.length; ++i) {
            sumPendDep += s.pendDep[i];
            sumPendRed += s.pendRed[i];
            if (s.pendDep[i] == 0) assertEq(s.entShares[i], 0, "entitlement without a deposit pending");
            else g.depositRequesters++;
            if (s.pendRed[i] == 0) assertEq(s.entAssets[i], 0, "entitlement without a redeem pending");
            else g.redeemRequesters++;
            g.sumEntitledShares += s.entShares[i];
            g.sumEntitledAssets += s.entAssets[i];
            ghostEntitledShares[actors[i]] += s.entShares[i];
            ghostEntitledAssets[actors[i]] += s.entAssets[i];
        }
        // harness sanity: every request in this epoch came from a known actor
        assertEq(sumPendDep, s.totDep, "actors do not cover the epoch (deposit)");
        assertEq(sumPendRed, s.totRed, "actors do not cover the epoch (redeem)");

        // I2: Σ entitlements never exceed the batch; dust < 1 wei/requester
        assertLe(g.sumEntitledShares, s.minted, "I2: deposit side over-allocated");
        assertLe(g.sumEntitledAssets, s.setAside, "I2: redeem side over-allocated");
        uint256 shareDust = s.minted - g.sumEntitledShares;
        uint256 assetDust = s.setAside - g.sumEntitledAssets;
        if (g.depositRequesters == 0) assertEq(shareDust, 0, "I2: share dust without requesters");
        else assertLt(shareDust, g.depositRequesters, "I2: share dust reached 1 wei per requester");
        if (g.redeemRequesters == 0) assertEq(assetDust, 0, "I2: asset dust without requesters");
        else assertLt(assetDust, g.redeemRequesters, "I2: asset dust reached 1 wei per requester");

        // I1: pairwise rate equality inside the epoch. Cross-product bound:
        // |e_i*p_j - e_j*p_i| < max(p_i, p_j)  <=>  identical rate up to the
        // 1-wei pro-rata floor, whatever the amounts.
        for (uint256 i; i < s.pendDep.length; ++i) {
            for (uint256 j = i + 1; j < s.pendDep.length; ++j) {
                if (s.pendDep[i] != 0 && s.pendDep[j] != 0) {
                    _assertSameRate(s.entShares[i], s.pendDep[i], s.entShares[j], s.pendDep[j], "I1: deposit rates differ");
                }
                if (s.pendRed[i] != 0 && s.pendRed[j] != 0) {
                    _assertSameRate(s.entAssets[i], s.pendRed[i], s.entAssets[j], s.pendRed[j], "I1: redeem rates differ");
                }
            }
        }

        // eager ghost roll (escrow identity is invariant to roll timing)
        ghostPendingDepositAssets -= s.totDep;
        ghostPendingRedeemShares -= s.totRed;
        ghostUnclaimedDepositShares += g.sumEntitledShares;
        ghostUnclaimedRedeemAssets += g.sumEntitledAssets;
        ghostDepositShareDust += shareDust;
        ghostRedeemAssetDust += assetDust;
    }

    function _assertSameRate(uint256 e1, uint256 p1, uint256 e2, uint256 p2, string memory err) internal pure {
        uint256 lhs = e1 * p2;
        uint256 rhs = e2 * p1;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        assertLt(diff, Math.max(p1, p2), err);
    }

    /// @dev Institutional pre-settlement step: if the CLOSED epoch's payout
    /// exceeds cash + incoming subscriptions, divest the whole position.
    /// Always sufficient: assetsSetAside = convertToAssets(escrowed shares)
    /// <= totalAssets = cash + floored T-Bill value.
    function _ensurePayoutCash(uint256 totDep, uint256 totRed) internal {
        uint256 setAside = vault.convertToAssets(totRed);
        uint256 cash = usdc.balanceOf(address(vault));
        if (cash + totDep >= setAside) return;
        uint256 tb = tbill.balanceOf(address(vault));
        if (tb == 0) return; // then setAside <= cash by solvency
        vm.prank(manager);
        vault.divest(tb);
    }

    function _slotBusy(bool depositSide, address actor) internal view returns (bool) {
        uint128 pending;
        uint64 slotEpoch;
        if (depositSide) (pending, slotEpoch) = vault.depositSlot(actor);
        else (pending, slotEpoch) = vault.redeemSlot(actor);
        if (pending == 0 || slotEpoch == vault.currentEpochId()) return false;
        return _fulfilledAt(slotEpoch) == 0; // CLOSED & unfulfilled: the D4 window
    }

    function _fulfilledAt(uint256 id) internal view returns (uint64 f) {
        (,,,,, f) = vault.epochs(id);
    }

    function _cutoffAt(uint256 id) internal view returns (uint64 c) {
        (,,,, c,) = vault.epochs(id);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _snap() internal view returns (uint256 supply, uint256 pps) {
        supply = vault.totalSupply();
        pps = vault.convertToAssets(ONE_SHARE);
    }

    /// @dev I5 (supply discipline) + I6 (pending isolation) around every
    /// non-fulfill action. Same-timestamp calls: the oracle cannot move, so
    /// strict equality is the correct assertion.
    function _assertUnmoved(uint256 supplyBefore, uint256 ppsBefore, string memory tag) internal view {
        assertEq(vault.totalSupply(), supplyBefore, string.concat("I5: supply moved by ", tag));
        assertEq(vault.convertToAssets(ONE_SHARE), ppsBefore, string.concat("I6: price moved by ", tag));
    }
}
