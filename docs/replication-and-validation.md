# Replication & Timeline Validation — Design

**Goals:**
- Replace Roblox's automatic server → client replication of **combat** state with our own replication layer.
- Move to **client-initiated actions**: the client proposes an action timeline, the timeline is replicated to every relevant client, and every client reports what it saw inside the same frame window so the action can be validated by consensus.

**Related:**
- `docs/state-machine-refactor.md` (charts, single scheduler)
- `docs/status-effect-system.md` (effects)
- `skills/game.combat.hit-validation-multiclient.skill.md`

## 1. How effects work today (V2)

There are two different "effects" in the code. Neither has its own replication.

### 1.1 Status effects (gameplay)
There is **no status effect system in code yet**. It's only designed (`docs/status-effect-system.md`). What exists is spread out:

| Thing | Where it lives | How clients learn about it |
|---|---|---|
| Stun / guard break | `Runtime:SetState("Stunned" / "GuardBroken")` + `task.delay` in `CombatService.Stun` | `S_Action` broadcast (state id) |
| Exhausted | StatBlock modifiers in `Combatant:RefreshExhausted` | **Roblox attributes** `Exhausted`, `AttackSpeed`, and `S_Meters` to the owner |
| Walk cap / lock | `ApplyMovement` | **Roblox attribute** `WalkCap` (players), `Humanoid.WalkSpeed` (NPCs, replicated by Roblox) |
| I-frames, follow-up window | `C.IFramesUntil`, `C.FollowUpUntil` timestamps | not replicated at all |
| Knockback | `S_Knockback` to the victim's owner (players), server `LinearVelocity` (NPCs, Roblox physics) | own channel / Roblox |

### 1.2 Visual effects (FX)
`FxController` runs on every client and is **reactive to server broadcasts**:
- `S_Action(actor, state, dir, actionId, attackId)` → `Fx.OnState`. The client recomputes the `Timeline` locally from `attackId` + the actor's `AttackSpeed` attribute. Then it drives the highlight telegraph, the direction label, the slash flash and the procedural grip swing with `task.delay(T.Startup)` / `task.delay(T.Startup + T.Active)`.
- `S_Result` → damage popups and outcome colours. `S_Limb` / `S_LimbBurst` → limb highlights.
- **Animations:** your own character's tracks play on your client, and Roblox's Animator replication shows them to others. NPC tracks play on the server and replicate the same way.
- **Weapon model + Motor6Ds** are server-created Instances that Roblox replicates.

### 1.3 What's wrong with that for a fighting game
- **Timing is receipt-based.** Each client starts the telegraph when `S_Action` arrives, so a client with 150 ms ping sees the windup 150 ms late, and the server uses `os.clock()`. No two machines agree on *when* the active frames are.
- **Server-initiated actions.** The attacker waits about 1 RTT before anything happens on their own screen.
- **Mixed transports.** The same combat fact travels through attributes, Humanoid properties, Animator replication and our `Net` channels. Ordering between them isn't guaranteed. For example, an `AttackSpeed` attribute change can arrive after the `S_Action` that depends on it.
- **Validation is attacker-only.** `HitService.Claim` trusts the attacker's hitbox, only bounded by server hard checks. The victim and witness steps in the skill are not implemented.

## 2. Constraints (be honest about Roblox)

- **There is no peer-to-peer.** Every "client → all clients" message is client → server → clients over our `Net` (one RemoteEvent today). The server is a relay **and** the judge. "Our own replication" means *we decide what is sent, when, to whom, and in what format*, not that we bypass the server.
- **Character physics stays on Roblox replication.** The owner client simulates its character, and Roblox replicates the root CFrame. Replacing that means a custom character controller, which is out of scope. We **record** it into our own history buffers and stop relying on it for anything combat-timed.
- **Clocks:** `workspace:GetServerTimeNow()` is synchronised by Roblox on every peer (about ±10–30 ms). We build frame indices on it, measure per-player RTT ourselves, and never use `os.clock()` across machines.

## 3. Architecture overview

```
              ┌────────────── Core/Clock ──────────────┐   server time → Frame = floor(t × 60)
              │                                        │
 Input ─► InputChart ─► ActionProposal ──C_Propose──► Server ActionAuthority ──S_Timeline──► all relevant clients
             (client predicts: plays timeline now)       │  accept / reject                      │ schedule by frame
                                                        │                                        ▼
                                          ValidationWindow ◄──C_Observe── attacker, victim(s), witnesses
                                                        │  (frames ActiveStart-Grace … ActiveEnd+Grace)
                                                        ▼
                                                 Verdict ──S_Result──► all relevant clients (FX, HUD, rollback)
 Core/Replicator: entity ids, components (state, timeline, effects, meters, loadout), snapshots + deltas, interest
```

The new modules are: `Core/Clock`, `Core/Replicator`, `Shared/Combat/ActionProtocol` (pure: proposal checks, frame math, vote evaluation), `Services/ActionAuthority` and `Services/ValidationService` (server), and `Controllers/TimelineController` (client).

## 4. Time and frames (`Core/Clock`)

- `Clock.Now()` = `workspace:GetServerTimeNow()` on both sides.
- `Clock.Frame(t?)` = `math.floor(t × 60)`. Animations are authored at 60 fps, so **frame data is exact**: a timeline is a list of frame boundaries, not seconds.
- **RTT per player:** the server sends `S_Ping(seq, serverTime)` every 2 s and the client echoes `C_Pong(seq)`. An EWMA of RTT and jitter is kept on the server. It feeds the proposal back-dating limits and the window close timeout (§7).
- `U32` frame numbers wrap after about 2.2 years, which is fine. On the wire, send `Frame % 65536` as `U16` plus the receiver's reconstruction ("nearest to my current frame").

## 5. Our replication layer (`Core/Replicator`)

It replaces attributes, Humanoid-property replication and ad-hoc channels for combat state.

**Entities:** every combatant gets a `U16` net id, assigned by the server on `CombatService.Register` and sent with its Model once (`S_Spawn(id, model, loadout)`). After that, packets carry ids, not Instances. That's smaller, and it survives streaming-out.

**Components** (each has a version counter):

| Component | Fields | Replaces |
|---|---|---|
| `State` | chart leaf id, entered frame | `S_Action` state part |
| `Timeline` | action key, attack id, start frame, phase frames, speed snapshot | client-side recomputation from attributes |
| `Stats` | AttackSpeed, WalkCap, Exhausted level (quantised U8/U16) | attributes `AttackSpeed`, `WalkCap`, `Exhausted` |
| `Effects` | `{ NetId, Stacks, EndsFrame }` | planned `S_Effect` / `S_EffectEnd` |
| `Meters` | posture, exhaustion stacks, limb fills | `S_Meters`, `S_Limb` |
| `Loadout` | weapon id, skin | server-built weapon Instance (clients build the weapon model and Motor6Ds locally, §9) |

**Delivery:**
- **Reliable, ordered** (current `Net` RemoteEvent, batched per Heartbeat): spawn/despawn, timelines, verdicts, effect changes.
- **Unreliable** (new `UnreliableRemoteEvent` lane in `Net`, latest-wins): meter and stat deltas, debug.
- **Deltas:** per entity, per client, send only components whose version changed since that client's last ack. Acks piggyback on `C_Ack(lastSeq)` every 10 frames.
- **Snapshots** on join or when a client falls too far behind.

**Interest management:**
- A client only receives entities within `RelevanceRadius` (≈150 studs) + its own.
- Timelines and verdicts go to clients within `CombatRadius` (≈80 studs) of the actor.
- This is also the **witness pool** (§7.3).

**Rule:** combat code never reads Roblox attributes for gameplay. Attributes may stay as Studio debug mirrors, written by the Replicator.

## 6. Client-initiated action timeline

### 6.1 Proposal (client)
1. The `InputChart` emits `Attack(dir)`. The local mirror chart says `Can("Attack")`.
2. Build an `ActionProposal`:
```luau
{ Seq = U16 per-player counter, AttackId (registry index U8/U16), Direction U8,
  StartFrame = Clock.Frame() + InputDelayFrames,   -- 0–2 frames of input delay smooths jitter
  SpeedSeen = U16 (AttackSpeed × 1000 from the replicated Stats component),
  Origin = root CFrame (compressed) }
```
3. **Predict:** play the timeline locally now (anim, lock, own hitbox scheduled at frames), and keep the proposal in a `Pending[Seq]` list.
4. `C_Propose(seq, attackId, dir, startFrame, speedSeen, origin)` (≈14 bytes).

### 6.2 Authority (server, `ActionAuthority`)
Pure checks live in `ActionProtocol.CheckProposal`:
- **Chart guard:** the server chart, evaluated *as of `StartFrame`*, accepts `Attack` (state history, so a stun that started after `StartFrame` but arrived first still wins).
- **`StartFrame` bounds:** `nowFrame − (RTT/2 + jitter + 3) ≤ StartFrame ≤ nowFrame + 2`. Back-dating is capped (≈ `MaxRewind` 0.25 s ≈ 15 frames).
- **`AttackId`:** the registry match for this direction / combo index / follow-up is recomputed by the server. The client's choice must equal it.
- **Speed:** `SpeedSeen` must equal the server's AttackSpeed at `StartFrame` within one quantum. If it doesn't, the server's value wins and the client gets corrected.
- **Rate:** per-player token bucket (existing `IntentRate`). `Seq` must be newer than the last.
- **Origin** within `SlideSlack` of the server's history sample at `StartFrame`.

On **accept**, the server builds the canonical `Timeline` in frames (from `Timeline.Compute` → frame boundaries) and puts the chart into `Committed.Attacking` at `StartFrame`. Then it sends `S_Timeline` to all clients in `CombatRadius`:
```luau
S_Timeline = (actorId U16, seq U16, attackId U16, dir U8, startFrame U16, windupF U8, activeF U8, recoveryF U8)   -- 12 bytes
```
On **reject**: `S_Reject(seq, reason U8)` to the proposer only. The client rolls back (stops the anim, restores the lock, drops `Pending[seq]`).

### 6.3 Scheduling on every client (`TimelineController`)
- Every client schedules the timeline **by frame**, not by arrival: `ActiveStart = startFrame + windupF`.
- A late receiver (arrival frame > startFrame) fast-forwards. It plays the animation from `(arrival − start)` frames in, at `WindupSpeed` adjusted to land the first hit frame exactly on `ActiveStart`. If the windup is already over, it skips straight to active.
- FX (`FxController`) subscribes to timeline phase events instead of `task.delay`. A remote attacker's telegraph is therefore frame-aligned on every screen.
- The attacker's own prediction is reconciled against `S_Timeline`. If the frames match, nothing changes. If the server corrected speed or start, the remaining phases are retimed.

## 7. Validation window (multi-client consensus)

### 7.1 Window
```
ValidateFrom = ActiveStart − GraceBefore        GraceBefore ≈ 2 frames
ValidateTo   = ActiveEnd   + GraceAfter         GraceAfter  ≈ 3 frames
CloseAt      = ValidateTo  + ceil(max RTT of participants / 2 × 60) + 2, capped at +12 frames (200 ms)
```
The server opens a `Validation` record for the action key when the timeline is accepted. It closes the record at `CloseAt` on the server frame clock, never waiting longer, and decides with whatever arrived.

### 7.2 Who reports what (`C_Observe`)
Each client sends **one** message per action when its local view passes `ValidateTo` (or earlier, on a hit). That's about 16–30 bytes each.

| Role | Sends | Weight |
|---|---|---|
| **Attacker** | hits: `{targetId, hitFrame}` from its own hitbox + its root CFrame at hitFrame | **Claim**. Required for a hit; never sufficient alone |
| **Victim** | its own root CFrame at the frames it saw the active window + its own state view (blocking / parry press frame / dodge) | **Strong when self-incriminating** (it confirms being in range). A denial only counts inside the borderline band |
| **Witnesses** (server picks 1–2 per action at random from the relevant pool, told in `S_Timeline`'s witness bitmask) | interpolated attacker and victim positions at the frames it rendered, plus "in hitbox?" per target | **Tie-breaker**, feeds trust |
| **Server** | its own history (root CFrames recorded every frame from Roblox physics replication + its chart state history) | **Veto** on hard checks; truth for state (block/parry/dodge) |

Clients **never decide outcomes** (hit / blocked / parried). They report geometry and their own inputs. The Resolver runs on the server against state history at `hitFrame`.

### 7.3 Evaluation (`ActionProtocol.Evaluate`, pure, unit-tested)
```
1. Hard checks (server truth) — any fail → Rejected:
   action still valid at hitFrame, hitFrame ∈ [ValidateFrom, ValidateTo], target alive and relevant,
   no duplicate target, anti-slide (LockProfile.MaxTravel), attacker CFrame vs server history ≤ 4 studs.
2. Geometry from server history at hitFrame (lag-compensated):
   inside box (≤ 0.5 stud outside)  → Pass
   ≤ leniency (BASE + RTT × speed × TrustScale) → Borderline
   else → Fail
3. Votes:
   Pass       → Confirmed (victim/witness reports only update trust)
   Borderline → victim confirms OR ≥ 1 witness confirms → Confirmed
                victim denies AND no witness confirms → Rejected
                no reports (timeout) → Confirmed if attacker Trust ≥ 0.8, else Rejected
   Fail       → Rejected; if victim AND a witness both confirm → Confirmed + flag "server history disagrees" (log)
4. Outcome: Resolver.Resolve(attack, defender state at hitFrame from chart history, parry press frame from the
   victim's server-timestamped intent, not from C_Observe) → S_Result(actionKey, targetId, outcome, damage).
```

**Trust** (per player, 0.5–1.2, starts at 1.0):
- Lowered by: claims that fail hard checks, denials of clear hits, witness reports that contradict both server history and the majority.
- Raised slowly by agreement.
- `TrustScale` widens or narrows leniency. Very low trust is logged and can kick at a threshold.

**Anti-collusion:**
- Witnesses are chosen by the server, unpredictably, and never on the same team or party as the attacker when teams exist.
- A witness can't push a `Fail` to `Confirmed` alone. A victim can't deny a `Pass`.

### 7.4 What players see
- **Attacker:** predicted swing, and predicted hit spark/hitstop on its own hitbox contact. Damage numbers and the victim's reaction only on `S_Result`.
- **Victim:** the hit reaction (stun anim) on `S_Result`, which applies its `Hitstun` effect with `EndsFrame` from the verdict frame, not from arrival.
- **Everyone:** telegraphs are frame-aligned (§6.3), so a parry is pressed against the same active frames the server judges.

## 8. Status effects under this model
- Effects replicate as the `Effects` component: `{ NetId, Stacks, StartFrame, EndsFrame }`. Clients expire them locally by frame. No `S_EffectEnd` is needed except for early removal (cleanse).
- Verdicts carry the effects they caused (`S_Result` → `Hitstun` with frames), so the victim's lock starts on the same frame everywhere.
- This **replaces** §9 of `docs/status-effect-system.md` (`S_Effect` with `F64 EndsAt`), which assumed receipt-time replication.

## 9. What leaves Roblox replication

| Today via Roblox | After |
|---|---|
| Attributes `Weapon`, `AttackSpeed`, `WalkCap`, `Exhausted` | `Loadout` / `Stats` components |
| Server-played NPC animation tracks | Clients play NPC tracks from `S_Timeline` (frame-aligned, no track replication) |
| Weapon model + Motor6Ds created on the server | Clients build them from `Loadout` with `WeaponModel.Attach` locally; the server keeps its own invisible copy only for NPC hitboxes. The Tool6D rules (motor per link, cleanup) are unchanged |
| NPC `Humanoid.WalkSpeed` | NPC movement stays server physics (Roblox replicates the root), plus the lock tier comes from the `State` component |
| **Stays on Roblox:** player character physics (network ownership), Instances that aren't combat (map, UI) | |

## 10. Channels

```luau
-- client → server
C_Propose = { U16 seq, U16 attackId, U8 dir, U16 startFrame, U16 speedSeen, CFrame origin }
C_Observe = { U16 actorId, U16 seq, U8 role, String/buffer payload }   -- payload packed with buffer (§ lib.packet)
C_Defend  = { U8 kind (down/up), U8 dir, U16 frame }                  -- parry press frame, back-dating bounded like proposals
C_Pong    = { U16 seq }
C_Ack     = { U32 lastSeq }

-- server → clients
S_Spawn    = { U16 id, Instance model, U16 weaponId }
S_Despawn  = { U16 id }
S_Timeline = { U16 actorId, U16 seq, U16 attackId, U8 dir, U16 startFrame, U8 windupF, U8 activeF, U8 recoveryF, U8 witnessMask }
S_Reject   = { U16 seq, U8 reason }
S_Result   = { U16 actorId, U16 seq, U16 targetId, U8 outcome, U16 damage, U16 frame }
S_Delta    = buffer (component deltas, unreliable lane for Stats/Meters; reliable for Effects/State)
S_Ping     = { U16 seq, F64 serverTime }
```
- `Net` gains: a `buffer` type token, an unreliable lane (`UnreliableRemoteEvent`, 900-byte limit per fire), and per-player relevance filtering (`FireRelevant(actorId, ...)`).
- Inbound flood limits move from "64 messages per batch" to per-channel token buckets.

## 11. How it fits the state machine plan
- The chart's `after` deadlines become **frame deadlines** from the timeline. The single scheduler steps by frame.
- `Chart:Sync(leaf, frame)` on the client applies server truth retroactively. A state entered at an earlier frame fast-forwards like a late timeline.
- Open question 1 in `docs/state-machine-refactor.md` (client prediction) is answered: **yes**. Actions are client-initiated and predicted, with reject → rollback.
- Server chart transitions must be evaluable **as of a past frame**, so the server keeps a short chart-state history (last ~30 frames of `{frame, leaf, context}`) per combatant.

## 12. Migration steps (each keeps the 118 specs green)
1. **`Core/Clock`:** server-time frames, ping/RTT. Swap every cross-machine `os.clock()` in combat (`CombatService`, `HitService`, `IntentService`, `MovementController`) for `Clock.Now()`.
2. **`ActionProtocol` (pure) + specs:** proposal bounds, frame conversion from `Timeline`, late-join fast-forward math, `Evaluate` vote matrix (every row of §7.3).
3. **`Net` upgrades:** `buffer` token, unreliable lane, relevance filtering, per-channel buckets. Specs for pack/unpack and limits.
4. **`Core/Replicator`:** entity ids + `State`/`Stats`/`Loadout` components. Stop writing gameplay attributes (keep debug mirrors). Clients build weapons locally.
5. **Client-initiated attacks:** `C_Propose` / `S_Timeline` / `S_Reject`, prediction + rollback, `TimelineController` + `FxController` on phase events. `C_Intent(Attack)` is retired, and block/dodge follow the same pattern after.
6. **Server position + chart history** at 60 Hz. Lag-compensated geometry in `HitService`.
7. **Validation windows:** `C_Observe` from attacker and victim, `Evaluate`, `S_Result` with frames. Witnesses + trust after victim reports are stable.
8. **Status effects** implemented with the `Effects` component (status doc, with §8 above).
9. **Remove the old paths:** `S_Action`, attribute reads, `HitClaim`.

**Studio test plan:**
- Incoming Replication Lag at 0 / 100 / 250 ms, with two clients plus a third as a witness (Test → Clients and Servers, 3 players).
- Log every verdict with its reason, and tune leniency until honest 200 ms players drop < 2% of borderline hits.

## 13. Risks and open questions
1. **Bandwidth:** with 3–4 observers per action and ~3 actions/s per fighter, about 400 B/s per fighter in a busy fight. That's fine, but interest radius and witness count are the knobs.
2. **Exploit surface moves to proposals:** back-dated `StartFrame` (bounded by RTT), speed spoofing (server recomputes), origin teleport (history check). The server never accepts a value it can compute itself.
3. **Victim's own physics is client-owned:** a victim can lie about its position by moving its character. Server history records what Roblox replicated, so a lying victim is still judged on server history. Its denials only matter in the borderline band.
4. **NPC actors:** the server proposes on their behalf (same `S_Timeline`), and only clients report as victims/witnesses. Should NPC attacks skip consensus entirely (server geometry only)? Recommended: yes, to start.
5. **Input delay frames** (0–2) trade responsiveness for fewer corrections. Make it a config knob, default 1.
6. **Witness privacy/cost on low-end devices:** witnesses sample only 1–2 actions per second at most, and the server caps per-client witness load.
