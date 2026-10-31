# Status Effect System — Design

Item 1 of V2's "Next" list (`docs/combat-system-v2.md` §3). It turns stuns, slows, buffs and meter-driven debuffs into one data-driven system that the server owns and the client mirrors.

Background reference: `skills/game.status-effects.lol-stats-cc.skill.md` (LoL stats, formulas, CC taxonomy). This doc decides how that model lands in **this** codebase.

> **Status (2026-10-31): steps 1–7 of §12 are implemented** in the AiTest place and in `src/`, with 145 specs passing. Step 8 (new CC sources) is still waiting for something that applies Root / Slow / Cripple / Disarm / Silence. The build differs from the design in these ways:
> - **Timing:** effects run on server time (`Core/Clock`, `workspace:GetServerTimeNow()`), not `os.clock()`. They replicate as **server-time frames** on interim `S_Effect(Target, NetId, Stacks, StartFrame, EndsFrame)` / `S_EffectEnd` channels. This replaces the §9 shape, and the move to the Replicator later is a transport swap only. Frames travel as `F64`, because absolute server-time frames don't fit `U32`. Late joiners and respawns ask for a snapshot with `C_EffectSync`.
> - **Tenacity floor:** `MinCCDuration` only limits how far Tenacity can shorten a CC. A CC whose base is already shorter than 0.3 s keeps its base, so chained hitstun (×0.85 per hit) still diminishes as before.
> - **Hitstun diminish** stays in `Resolver.Consequences`; `HitService` passes the result as `Overrides.Duration` (open question 3: kept as-is).
> - **Exhausted** now compounds per level (`AttackSpeed ×0.94ⁿ`, `WalkSpeed ×0.96ⁿ`), as in §4. The old linear rule gave `1 − 0.06·n`.
> - **Airborne knockback** is still applied by `HitService` (physics side effect), alongside the `Airborne` effect that owns the lock. No `OnApply` hook is used.
> - **Intent gate:** `IntentService` drops Attack / Dodge intents that `Can` rejects. Defend intents always pass, so a held F still blocks once a stun ends.
> - **Client lock:** `LockProfile.Combine(stateSample, EffectController.LockTier(character))` takes the higher tier and the smaller Move / Turn.
> - **HUD:** text chips (id, stacks, seconds left) above your posture bar, and an `EffectIcons` billboard over everyone else.

## 1. Goals

1. **One gate for "can I act?"** Today the answer is spread over runtime states (`Stunned`, `GuardBroken`), `WeaponClass.Allowed` and `LockProfile.States`. After this, a combatant's active effects answer `Can("Attack")`, `Can("Move")` and so on, and the lock tier comes from the strongest effect.
2. **Effects are data.** Adding "Freeze" means one table entry plus, at most, an optional hook. No new state, no new remote.
3. **Stats flow through the existing StatBlock.** Effect modifiers are `Stats` modifiers with `Source = <effect id>`, so `RemoveSource` cleans them up, and `AttackSpeed` / `WalkSpeed` changes already reach `Timeline` and movement.
4. **Server-authoritative, client-predicted only for visuals.** The server applies and expires effects. The client mirrors them for HUD icons, VFX and the movement lock.
5. **Pure core, testable in TestKit.** `StatusController` takes `Now` as an argument and never touches Instances, so every rule gets a spec.

Non-goals for this iteration: limb-break effects beyond the default handler, Charm/Taunt/Fear forced movement, Stasis.

## 2. Layout

```
ReplicatedStorage/Shared/StatusEffects/
├─ Effects.luau            -- frozen EffectDef registry (Id → def, NetId → def)
├─ StatusController.luau   -- pure per-combatant controller (apply, stack, expire, gates, lock tier)
└─ EffectTags.luau         -- tag + action name constants shared with gates/HUD
ServerScriptService/Services/EffectService.luau       -- owns controllers, ticks, replicates
StarterPlayerScripts/Controllers/EffectController.luau -- client mirror, HUD icons, VFX hooks
ServerScriptService/Tests/StatusController.spec.luau
ServerScriptService/Tests/Effects.spec.luau
```

`Combatant` gets a `Status : StatusController` field next to `Stats`, created in `Combatant.new` with the same StatBlock.

## 3. EffectDef

```luau
export type Action = "Move" | "Rotate" | "Jump" | "Attack" | "Defend" | "Dodge" | "Ability"
export type StackMode = "Refresh" | "Extend" | "Independent" | "Intensity" | "Ignore"

export type EffectDef = {
	Id : string,
	NetId : number,                      -- U8, stable; never reuse a retired id
	Kind : "Buff" | "Debuff" | "CC",
	Tags : { [string]: true },           -- "Stun", "Slow", "Airborne", "Cleansable", "TenacityAffected", ...
	Duration : number,                   -- seconds; math.huge = until removed
	StackMode : StackMode,
	MaxStacks : number?,
	Blocks : { [Action]: true }?,
	Lock : number?,                      -- LockProfile.Tiers value this effect forces (Locked, Forced...)
	Modifiers : { { Stat : string, Kind : Stats.ModKind, Value : number } }?, -- per stack
	Tick : { Interval : number, Damage : number?, DamageType : Stats.DamageType?, Heal : number? }?,
	BreaksOnDamage : boolean?,
	MinDuration : number?,               -- floor after Tenacity (default CombatConfig.Status.MinCCDuration)
	Hooks : { OnApply : ((Ctx) -> ())?, OnRemove : ((Ctx) -> ())?, OnTick : ((Ctx) -> ())? }?, -- server only
}
```

Rules:
- **NetId** is a `U8` so the existing `S_Effect` / `S_EffectEnd` channel shapes from the plan (§`Net`) fit unchanged.
- **Modifiers per stack:** `PercentMult` compounds (`Value ^ Stacks`), `Flat` / `PercentAdd` multiply (`Value × Stacks`). Same as the skill's `_RebuildModifiers`.
- **Hooks** run on the server only and receive `{ Combatant, Instance, Source, Now }`. They exist for side effects that are not stats: knockback velocity, VFX broadcasts, resetting posture.
- Effects are validated at load (`Effects.spec`): unique `Id` and `NetId`, known tags, known actions, `Lock` is a real tier, `Intensity` has `MaxStacks`.

## 4. Starting effect set

| Id | Kind | Duration | Stack | Blocks | Lock | Modifiers / notes | Replaces |
|---|---|---|---|---|---|---|---|
| `Hitstun` | CC | spec `Hitstun` × chain diminish | Refresh | all actions | Locked | T, C | `Stunned` state from hits |
| `Stagger` | CC | `ParriedStagger` 0.7 | Refresh | all | Locked | T | `Stunned` after being parried |
| `GuardBroken` | CC | `GuardBrokenStun` 1.4 | Ignore | all | Locked | not T; OnRemove resets posture | `GuardBroken` state |
| `Airborne` | CC | knockback `Duration` | Refresh | all | Forced | not T, not C; OnApply sends `S_Knockback` | finisher / S+M1 knockback |
| `Root` | CC | per source | Refresh | Move, Jump, Dodge | Rooted | T, C | — |
| `Slow` | Debuff | per source | Independent | — | — | `WalkSpeed` via strongest-slow rule (§6) | — |
| `Cripple` | Debuff | per source | Refresh | — | — | `AttackSpeed` PercentMult | — |
| `Disarm` | CC | per source | Refresh | Attack | — | T, C. arm-break candidate | — |
| `Silence` | CC | per source | Refresh | Ability | — | T, C. no specials yet, wired for later | — |
| `Exhausted` | Debuff | ∞ | Intensity (10) | — | — | `AttackSpeed` ×0.94ⁿ, `WalkSpeed` ×0.96ⁿ, `PostureDamageTaken` +8%·n; driven by `SetIntensity` | `Combatant:RefreshExhausted` |
| `FollowUpReady` | Buff | `FollowUpWindow` 0.45 | Refresh | — | — | grants the `FollowUp` attack state | follow-up window flag |
| `BreakerIFrames` | Buff | 0.4 | Ignore | — | — | tags `Invulnerable`, `Unstoppable` | — (combo breaker, later) |
| `DodgeIFrames` | Buff | `DodgeIFrames` | Refresh | — | — | tag `Invulnerable` | dodge i-frame timer |

`T` = Tenacity reduces it, `C` = cleansable. Values come from `CombatConfig` / the weapon schema at apply time, so tuning stays where it is today.

## 5. StatusController API

```luau
StatusController.new(Stats : StatBlock, OnChanged : ((Event) -> ())?) -> StatusController

:Apply(Id, Source?, Now, Overrides?) -> Instance?   -- Overrides = { Duration?, Stacks?, Modifiers? }
:Remove(Id, Reason?)                                -- Reason: "Expired" | "Cleansed" | "Damage" | "Replaced"
:SetIntensity(Id, Stacks, Now)                      -- meter-driven (Exhausted); 0 removes
:Cleanse(Filter?)                                   -- removes every Cleansable effect (optionally by tag)
:Has(Tag) -> boolean      :Get(Id) -> Instance?     :Stacks(Id) -> number
:Can(Action) -> boolean                             -- false if any active effect blocks it
:LockTier() -> number                               -- max Lock of active effects, Free if none
:OnDamaged(Now)                                     -- removes BreaksOnDamage effects
:Update(Now) -> { Instance }                        -- expires and ticks; returns ticks due (server applies damage)
:Snapshot() -> { { NetId, Stacks, EndsAt } }        -- for late joiners
:Destroy()
```

`Instance = { Def, Stacks, StartedAt, EndsAt, Source, NextTick? }`. `Independent` effects key their instance as `"<Id>#<n>"` so several coexist; `Has`, `Can`, and modifiers treat them like any other instance.

Apply order (pure, all in `Apply`):
1. `Unstoppable` active and `Kind == "CC"` → reject. `Invulnerable` does **not** reject CC (only damage).
2. Duration = `Overrides.Duration or Def.Duration`, then Tenacity if tagged `TenacityAffected`: `Stats.CCDuration(D, Tenacity, CCType)`, then `math.max(MinDuration, D)` (LoL floor 0.3 s, `CombatConfig.Status.MinCCDuration`).
3. Existing instance → stack per `StackMode`; otherwise create.
4. Rebuild modifiers on the StatBlock (`AddModifier("<Id>:<i>", …, Source = Id)`).
5. Fire `OnChanged({ Kind = "Applied" | "Stacked", Id, Instance })`.

## 6. Stat rules that live outside a single modifier

- **Strongest slow only.** `Slow` instances don't add `WalkSpeed` modifiers directly. After any change the controller recomputes `Stats.StrongestSlow(slows, SlowResist)` and writes one modifier `"Slow"` (`PercentMult`, `1 - strongest`).
- **Tenacity** stays `Stats.CombinedTenacity` over the StatBlock's `Tenacity` modifiers; it is read at apply time only (a later Tenacity buff does not shorten running stuns, as in LoL).
- **Exhausted** moves from `Combatant:RefreshExhausted` into `SetIntensity("Exhausted", Level)`. `Combatant` keeps computing `Level` from stacks; only the modifier writing moves.

## 7. How the rest of the combat code uses it

| Place | Today | After |
|---|---|---|
| `CombatService.Stun(C, D, State)` | sets `Stunned` / `GuardBroken` state + `task.delay` | `C.Status:Apply("Hitstun" / "Stagger" / "GuardBroken", Source, Now, { Duration = D })`; runtime state becomes `Stunned` while `LockTier() >= Locked` and returns to Idle on the last lock effect's removal |
| `WeaponClass.Allowed` | state whitelist per action | unchanged **and** `C.Status:Can(Action)`; both must pass |
| `IntentService` | state check | rejects intents where `Can` is false (no state change, no ack) |
| `LockProfile.Sample` | per-state table | `max(StateSample.Tier, Status:LockTier())`; Move/Turn take the min of both |
| `Resolver.Consequences` | returns hitstun, knockback, posture | unchanged (pure); `HitService` turns its `Hitstun` / `Knockback` fields into `Apply` calls |
| `HitService` damage | `Humanoid:TakeDamage` | also `Status:OnDamaged(Now)`; `Invulnerable` tag skips damage |
| Dodge i-frames, follow-up window | timers on the runtime | `DodgeIFrames` / `FollowUpReady` effects; Resolver reads `Has("Invulnerable")` via the defender snapshot |
| Exhaustion | `RefreshExhausted` writes modifiers | `SetIntensity("Exhausted", Level, Now)` |

The runtime state machine keeps `Stunned` and `GuardBroken` as **names** for animation and HUD, but they become derived: the effect owns the timing. That removes the `After(C, Id, Duration)` race where a new action id silently cancels a stun's end.

## 8. Ticking

`EffectService` runs one `RunService.Heartbeat` loop over all controllers (`Update(workspace:GetServerTimeNow())`). This is also the first step toward V2 "Next" item 5 (one scheduler instead of `task.delay` chains). Ticks (`Tick.Interval`) return from `Update`; the service applies `Stats.FinalDamage` with the effect's `Source` as attacker and routes healing through `Stats.Heal` (Grievous Wounds later).

## 9. Networking

> **Superseded by `docs/replication-and-validation.md` §8:** effects replicate as the Replicator's `Effects` component with `StartFrame` / `EndsFrame` on the shared server-time frame clock, and verdicts carry the effects they cause. The channel sketch below assumed receipt-time replication.

Two server → client channels in `CombatNet`, already sketched in the plan:

```luau
Effect    = Net.Define("S_Effect",    { "Instance", "U8", "U8", "F64" }), -- Target, NetId, Stacks, EndsAt (server time)
EffectEnd = Net.Define("S_EffectEnd", { "Instance", "U8" }),               -- Target, NetId
```

- Sent to **all** clients for visible effects; an effect tagged `Private` (e.g. `Exhausted`) goes only to its owner, whose `S_Meters` already carries the count.
- `Independent` instances replicate as one entry per NetId with the summed stack count and the latest `EndsAt` (clients only need icons).
- Late joiners: `PlayerService` sends `Status:Snapshot()` for every combatant on join.
- The client mirror (`EffectController`) holds `{ [Model]: { [NetId]: { Stacks, EndsAt } } }`, expires locally by `EndsAt` as a fallback, and exposes `Signal`s for HUD and FX. The owner's `MovementController` reads its own mirrored `LockTier` so the lock feels instant; the server's `WalkCap` attribute stays the authority.

## 10. Config

```luau
-- CombatConfig
Status = table.freeze({
	MinCCDuration = 0.3,     -- LoL floor after Tenacity
	DefaultCleanseTags = { Cleansable = true },
}),
```

## 11. Tests (TestKit)

`StatusController.spec`:
- Refresh resets `EndsAt`; Extend adds; Intensity caps at `MaxStacks`; Ignore keeps the original; Independent keeps two instances.
- Tenacity shortens `TenacityAffected` only, never `Airborne`; `MinCCDuration` floor.
- `Unstoppable` rejects CC, accepts buffs.
- Modifiers: `PercentMult` compounds per stack; `Remove` restores the stat exactly (StatBlock `RemoveSource`).
- Strongest-slow: 30% + 50% → 50%; removing the 50% falls back to 30%.
- `Can` / `LockTier` with overlapping Root + Hitstun; `OnDamaged` removes `BreaksOnDamage`.
- `Update` expires on the boundary and returns due ticks.

`Effects.spec`: registry validation (§3), every NetId fits `U8`, every `Lock` is a `LockProfile.Tiers` value.

Integration (Studio playtest): hit → `Hitstun` icon on the dummy, locked for the spec duration; S+M1 → `Airborne`; guard break → posture resets on removal; exhausted attacker's `AttackSpeed` drops in the debug print.

## 12. Migration order

1. `Effects`, `StatusController` + specs (pure, nothing wired). 
2. `EffectService` with the Heartbeat loop and the two channels; `Combatant.Status`.
3. Move `Exhausted` (smallest blast radius, already modifier-based).
4. Move `Hitstun` / `Stagger` / `GuardBroken` and derive the runtime states; delete `After`-based stun ends.
5. `LockProfile` reads `LockTier`; `IntentService` checks `Can`.
6. `Airborne`, `DodgeIFrames`, `FollowUpReady`.
7. `EffectController` + HUD icons.
8. New CC (`Root`, `Slow`, `Cripple`, `Disarm`, `Silence`) once there is something that applies them (limb breaks, specials).

## 13. Open questions

- Should blocked hits apply a tiny `Slow` (block chip pressure)?
- Do limb breaks map as in the skill (§8: arm → Disarm/Cripple, leg → Slow + Grounded, torso → Bleed)? The default break handler stays a no-op until decided.
- Should `Hitstun` keep diminishing (×0.85 per chained hit) inside the effect, or should that move into an `Intensity` "ChainResist" buff on the defender?
