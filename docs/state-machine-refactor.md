# State Machine Refactor — Plan

**Goal:** combat actions, status effects and keybind/input logic follow statechart norms:
- events in, transitions declared as data, guards and actions named
- state-owned timers, run-to-completion
- one definition shared by server and client

**Background:** `skills/roblox.architecture.state-machines.skill.md`. It covers the vocabulary, the RobloxStateMachine and Arch APIs, the combat patterns and a reference implementation.

**Related:** `docs/status-effect-system.md`. This plan changes how that design connects to actions (§5).

## 1. What's weak today

| # | Problem | Where | Symptom |
|---|---|---|---|
| 1 | **Anyone can set any state.** `Runtime:SetState(Name)` has no transition rules, and the graph only exists across `CombatService`, `HitService` and controllers | `WeaponClass.Runtime.SetState` | Adding a state means auditing every caller |
| 2 | **Exits are `task.delay` + `ActionId` staleness checks** | `CombatService.After`, client `RunOwnAttack` | Timers outlive interrupts. Attack speed can't change mid-swing. Hard to test without waiting |
| 3 | **Hidden sub-states as flags/timestamps** next to the FSM | `C.Holding`, `C.FollowUpUntil`, `C.IFramesUntil`, `C.ParryStart`, combo index/time | Rules like "block again after a stun if F is still held" live in `ToNeutral`'s `if` |
| 4 | **Gating is split** between `WeaponClass.Allowed`, `CanStart`, cooldowns, `Alive()`, and (planned) `Status:Can` | `CanStart`, handlers | Four places to change for a new action |
| 5 | **Attack phases aren't states.** Windup, active and recovery are numbers sampled by `LockProfile` and by client `task.delay`s | `Timeline`, `LockProfile`, `CombatController` | Cancel windows and feints have nowhere to live. Hitbox start/stop is timer-based, not entry/exit-based |
| 6 | **Input logic is if/else + module locals** | `InputController` (`Buffered`, `Pending`, `State == "Idle"`) | Keybinds are read inline, tap-vs-hold on F isn't modelled, and the queued M1 duplicates the server's rules |
| 7 | **Stuns are states with timers.** The planned status effects would then fight the FSM for who owns "stunned" | `CombatService.Stun`, status doc §7 | Two sources of truth for disabled |

## 2. Target architecture

Three machines per combatant, each with a single responsibility. They talk to each other only through **events** and **guards**.

```
              keys ──► InputChart (client) ──intent events──► net ──► CombatChart (server, authoritative)
                          ▲    │ Can(event)?                                │  ▲
                          │    └──────── mirror CombatChart (client) ◄──────┘  │ guards: Status:Can / Has
                          │                 (Sync on S_Action)                 │ events: Disabled / Recovered
                          └──────────────── StatusController (server; client mirror) ◄── hits, abilities
```

### 2.1 `Core/StateChart` (new, dependency-free)
- Our own small statechart, built from the skill's reference: nested states, ordered transition lists with guards, transition actions, entry/exit, `after` timers, run-to-completion queue, `Can(event)`, `In(path)`, `Leaf()`, `Changed` signal, and `Step(now)` for a single scheduler.
- **Why not a library:**
  - **RobloxStateMachine** polls transitions every Heartbeat in undefined order, has no hierarchy and no timers. It's wrong for event-driven combat across many actors.
  - **Arch** has the right model (SCXML), but its lifecycle and API docs are empty, the store model was removed, and it would be our first hard third-party dependency (`core.contracts` rule: none).
  - We borrow Arch's definition shape so the knowledge transfers.
- **Validation at construction:** every `Target` resolves, every compound has an `Initial`, there are no unknown event names (checked against an `Events` enum), and `Dead` is final.

### 2.2 `Shared/Combat/CombatChart` (definition, data)

```
Root
├─ Alive                           On: Died → Dead
│  ├─ Neutral           (history: shallow)     On: Hit [vulnerable] → Disabled.Hitstun
│  │  ├─ Idle           On: Attack [canAttack] / beginAttack → Committed.Attacking
│  │  │                     DefendDown [dir & parryReady] → Committed.Parrying
│  │  │                     DefendDown → Blocking
│  │  │                     Dodge [canDodge] → Committed.Dodging
│  │  └─ Blocking       On: DefendUp → Idle ; Dodge [canDodge] → Committed.Dodging
│  │                        Attack [canAttack] → Committed.Attacking ; GuardBreak → Disabled.GuardBroken
│  ├─ Committed                     On: Hit [vulnerable] → Disabled.Hitstun ; Parried → Disabled.Stagger
│  │  ├─ Attacking      Initial: Windup
│  │  │  ├─ Windup      After: timeline.Startup → Active ; On: Feint [feintWindow] → Neutral
│  │  │  ├─ Active      Entry: startHitbox  Exit: stopHitbox   After: timeline.Active → Recovery
│  │  │  └─ Recovery    After: timeline.Recovery → Neutral ; On: Dodge [cancelWindow] → Dodging
│  │  ├─ Parrying       After: ParryWindow → Neutral
│  │  └─ Dodging        Entry: dash, DodgeIFrames effect   After: DodgeDuration → Neutral
│  └─ Disabled          (entered only via events raised by StatusController)
│     ├─ Hitstun        On: Recovered → Neutral   (Neutral history → Blocking if still held)
│     ├─ Stagger        On: Recovered → Neutral
│     ├─ GuardBroken    On: Recovered → Neutral
│     └─ Airborne       On: Recovered → Neutral
└─ Dead (final)
```

- **Held-key memory replaces `C.Holding`/`ToNeutral`.** `DefendDown`/`DefendUp` while not in Neutral are recorded by a targetless transition on `Alive` (`Holding = true/false` in context). `Neutral`'s initial choice is a guarded transient: `Holding → Blocking`, else `Idle`.
- **Combo / follow-up stay data, matched by guards.** `beginAttack` calls `Runtime:MatchAttack`. `FollowUpReady` is a status effect (status doc §4), so the guard reads `Status:Has("FollowUpReady")` instead of `C.FollowUpUntil`.
- **Weapons extend the chart** through the schema, e.g. `Schema.Chart = { Patch = { ["Alive.Committed.Attacking.Windup"] = { On = { Feint = ... } } } }`. Merged at `WeaponClass.Define`, validated, then frozen.
- **Side-specific actions** are bound at instantiation: `CombatChart.new(Def, { beginAttack = ServerBeginAttack, startHitbox = ... })`. Shared code never branches on side.
  - **Server binds:** exhaustion, broadcast, server hitbox (NPCs), walk cap.
  - **Client binds:** animation, procedural FX, own hitbox, dash.

### 2.3 Status effects connect, they don't nest
`StatusController` keeps set semantics (overlap, stacks, tenacity) as designed in `docs/status-effect-system.md`. The changes are in how it connects:
- `Apply` of an effect with `Lock >= Locked` sends `Disabled` + the effect id to the chart. The chart targets `Disabled.<EffectId>` (`Hitstun`, `Stagger`, `GuardBroken`, `Airborne`). A higher-priority lock while already disabled is a sibling transition.
- Removal of the last lock effect sends `Recovered`.
- Guards read the controller: `canAttack = Status:Can("Attack") and Runtime:CooldownReady(...)`, `vulnerable = not Status:Has("Invulnerable")`, `canDodge = Status:Can("Dodge") and not Status:Has("Grounded")`.
- Effects own **duration**. The chart owns **what you're doing**. That removes `CombatService.Stun`'s timer and `Stunned`/`GuardBroken` as independent states (status doc §7 already plans to derive them; this plan makes the chart the place where they're derived).

### 2.4 `InputChart` (client) + keybind table

```
Input (parallel)
├─ Direction   Empty ⇄ Buffered(dir)   After: DirectionalWindow → Empty ; consumed by Press*
├─ Attack      Ready → Queued(dir) [not combat:Can("Attack")]   After: InputBuffer → Ready
│                      Queued → Ready / send Attack on combat Changed when combat:Can("Attack")
└─ Defend      Up → Down (send DefendDown(dir)) → Up (send DefendUp)
```

- **Keybinds become a table** in `Shared/Combat/Keybinds`. It maps raw input to input events: `{ [Enum.UserInputType.MouseButton1] = "PressAttack", [Enum.KeyCode.F] = { Down = "PressDefend", Up = "ReleaseDefend" }, [Enum.KeyCode.Q] = "PressDodge", W/A/S/D = { Event = "Direction", Payload = "Front" ... } }`.
  - The weapon schema's `Keybinds` becomes an optional per-weapon override merged over the default.
  - Saved rebinds (ProfileStore, plan M0) are just another override layer.
  - Gamepad support is another table.
- **`InputController` shrinks to plumbing:** UserInputService (or the 2025 Input Action System) → table lookup → `InputChart:Send`.
- **The client asks its mirrored CombatChart `Can(event)`** instead of comparing to `"Idle"`, so buffering follows the same rules as the server.

### 2.5 Client mirror
- The client instantiates the same `CombatChart` for its own character with client actions bound.
- On `S_Action` it applies the server's leaf id with `Chart:Sync(leafPath, context)`, which exits and enters without guards. It never takes damage-relevant transitions on its own.
- Optional prediction (later): the client takes `Attack`/`Dodge` locally for animation responsiveness, and a `Sync` with a different leaf rolls back.
- **Wire format:** `S_Action` sends a **leaf id** (a U8 enum generated from the chart paths) instead of today's flat `CombatEnums.States`. The HUD and FX key off leaf paths (`Alive.Committed.Attacking.Active`).

### 2.6 One scheduler
`Core/Scheduler` (or inside `CombatService.Start`): one Heartbeat calls `Chart:Step(now)` for every chart and `Status:Update(now)` for every controller.
- `after` delays that come from a `Timeline` are recomputed when `AttackSpeed` changes mid-phase (`remaining × oldSpeed / newSpeed`).
- This is V2 "Next" item 5, done as part of this refactor.

## 3. Mapping old → new

| Today | After |
|---|---|
| `Runtime:SetState(Name, Context)` (public) | `Chart:Send(Event, Payload)`. `SetState` is removed, and `Sync` is client-only |
| `WeaponClass.Allowed`, `Runtime:CanStart` | Transitions + guards. `Chart:Can("Attack")` |
| `CombatService.After(C, Id, D, Fn)`, `ActionId` stale checks | `After` on states, cancelled on exit. `ActionId` stays only as the hit-claim NetId |
| `ToNeutral` + `C.Holding` | `Neutral` initial transient + `Holding` context set by targetless transitions |
| `CombatService.Stun(C, D, State)` | `Status:Apply(effect)` → `Disabled` event |
| `C.FollowUpUntil`, `C.IFramesUntil` | `FollowUpReady`, `DodgeIFrames` effects (status doc) read by guards |
| `C.ParryStart`, `C.ParryDirection` | `Parrying` entry stores them in context. The Resolver reads `In("Alive.Committed.Parrying")` + context |
| Client `RunOwnAttack` `task.delay`s | `Active` entry/exit bound to the client hitbox |
| `LockProfile.States[state]` | Keyed by leaf path (`Attacking.Windup` → Steer...). Timeline sampling stays for the curve |
| `InputController` locals `Buffered`, `Pending` | `InputChart` regions `Direction`, `Attack` |
| `Schema.Keybinds` read inline | `Shared/Combat/Keybinds` default ⊕ schema override ⊕ saved rebinds |
| `CombatEnums.States` (8 names) | Generated `CombatChart.LeafIds` |
| `WeaponClass` `CreateState():BindFunction()` hooks | Kept as sugar: they register entry/exit listeners on chart paths |

## 4. Migration steps (each step ships with green specs)

1. **`Core/StateChart` + `StateChart.spec`.** Covers nesting, ordered guards, entry/exit order, self/targetless transitions, `after` with a fake clock, run-to-completion (an event sent from an action is queued) and validation errors. Pure; nothing wired yet.
2. **`CombatChart` definition + `CombatChart.spec`.** A table-driven spec over `(leaf, event, guards) → leaf`, generated from the definition, plus invariants (§9 of the skill). It mirrors today's behaviour exactly; `Feint`/cancel windows are left out for now.
3. **Server switch-over behind `CombatConfig.UseChart`.**
   - `Combatant` owns a `Chart`.
   - `CombatService.StartAttack`, `DefendStart`/`DefendEnd` and `Dodge` become `Chart:Send`.
   - `After`/`ToNeutral` are deleted.
   - The runtime's `Current` becomes a read-only projection of `Chart:Leaf()`, so existing readers keep working.
   - Run the 118 specs and the Studio playtest (W+M1, combo chain, parry, dodge, guard break).
4. **Status effects implemented per `docs/status-effect-system.md`**, with §2.3 wiring (`Disabled`/`Recovered`). `CombatService.Stun` is deleted.
5. **Single scheduler.** Charts and controllers step from one Heartbeat. Mid-phase attack-speed rescale.
6. **Leaf ids on the wire + client mirror** (`Sync`). `CombatController` and `AnimationController` key off leaf paths. The client hitbox follows `Active` entry/exit.
7. **`InputChart` + `Keybinds` table.** `InputController` becomes plumbing. Specs for buffering windows and tap-vs-hold with a fake clock.
8. **New mechanics as transitions:** feint (`Windup → Neutral`, exhaustion cost), dodge-cancel in recovery, and the combo breaker (`Disabled.Hitstun: Breaker [cooldown] → Committed.Breaker`).
9. **Cleanup:** remove `UseChart`, `WeaponClass.Allowed`, `CombatEnums.States`, and the flag fields on `Combatant`. Update the V2 doc and skills.

**Risk control:**
- Steps 1–2 change no behaviour.
- Step 3 is behind a flag, and the chart is checked against the old FSM: in Studio, both run side by side and log disagreements for one playtest session.
- Every later step is independently revertible.

## 5. Changes to the status effect design
- `Lock` on an effect now *raises chart events* rather than overriding `LockProfile` directly. `LockProfile` reads the chart leaf, which already reflects `Disabled.*`.
- `StatusController.OnChanged` gains `FirstLock(effectId)` / `LastLockCleared()` notifications. EffectService forwards them to `Chart:Send("Disabled", id)` / `Chart:Send("Recovered")`.
- Status doc §7's "runtime state becomes derived" is now concrete: it is the `Disabled` subtree.

## 6. Open questions
1. ~~Client prediction for `Attack`/`Dodge`?~~ **Decided: yes.** Actions are client-initiated timelines with reject → rollback (`docs/replication-and-validation.md` §6, §11).
2. Should `Blocking` → `Attacking` (attack out of block) stay allowed? Today it's not: `Allowed.Attack = { Idle }`. The chart above includes it as an option to decide.
3. Saved keybinds: per weapon, or global with weapon overrides?
4. NPC AI (`NpcService`): do dummies get a separate `AiChart` that sends the same events as players (recommended: the same combat path for PvE and PvP), or a RobloxStateMachine-style polled machine?
