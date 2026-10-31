---
name: game.combat.architecture-patterns
description: Combat system design patterns for Roblox fighting games - dual-context (shared) modules with injected adapters, blueprint/runtime split, data-driven weapon schema, action state machine with transition rules, input buffering (directional windows, tap vs hold), M1 combo chains with finisher knockback, directional attack/parry/dodge resolution matrix, block/posture/exhaustion economy, frame data (startup/active/recovery), hitstun/i-frames, cancel windows, server authority + client prediction flow. Use when designing or implementing any combat feature in this project.
---

# Combat — Architecture & Patterns

Project decisions: **R6 only**, weapons are Models on a `Motor6D` (no `Tool`), **client-side hit detection with multi-client validation** (game.combat.hit-validation-multiclient), knockback attacks are **blockable** (they deal higher posture damage), the parry direction rule is a **config value**.

Companion skills: lib.hitboxclass.hitbox, game.combat.limb-damage-highlight, game.combat.animation-movement-lock, game.status-effects.lol-stats-cc, lib.packet.networking, lib.goodsignal.events, roblox.input.userinput-contextaction, roblox.animation.animator-tracks, roblox.spatial.raycast-overlap-hitbox, roblox.physics.movers-knockback, roblox.network.remotes-replication-security.

## 1. Dual-context modules (no IsServer/IsClient in shared code)

Shared module (ReplicatedStorage) contains: schema, types, enums, the state machine, the resolver, and **signals**. It never touches UserInputService, Animator loading, DataStores, or damage application directly.

Each side injects its behaviour:
```luau
-- shared: WeaponClass
local WeaponClass = {}
WeaponClass.Adapter = nil :: Adapter?     -- set once by the entry script of each side

export type Adapter = {
	Now: () -> number,                                    -- server: os.clock / client: os.clock
	OnStateEntered: (runtime: any, state: string, ctx: any) -> (),
	OnStateExited: (runtime: any, state: string, ctx: any) -> (),
}

function WeaponClass.SetAdapter(adapter: Adapter) WeaponClass.Adapter = adapter end
```
Or (more decoupled, reaction-based) the shared runtime only **fires signals**; the server entry connects hitbox/damage logic, the client entry connects animation/VFX:
```luau
Runtime.StateEntered:Connect(function(state, ctx) ... end)   -- server: start hit window; client: play track
```
Signals = GoodSignal (immediate, cheap).

## 2. Blueprint vs runtime

| Blueprint (`WeaponDefinition`) | Runtime (`WeaponRuntime`) |
|---|---|
| one per weapon type, immutable (frozen schema) | one per owner per side |
| stats, animation ids, keybinds, timings, combo data, state list | current state, combo index, last M1 time, cooldowns, loaded tracks, active maid, hit registry |
| defined in `Weapons/LinkedSword` module | created on equip: `definition:Instantiate(character)` |

## 3. Data-driven weapon schema (suggested shape)

```luau
export type DamageType = "Physical" | "Magical" | "True"
export type Direction = "Front" | "Back" | "Left" | "Right"

export type HitboxSpec = { Size: Vector3, Offset: CFrame, Start: number, Duration: number }

export type AttackSpec = {
	Damage: { Type: DamageType, Amount: number },
	PostureDamage: number,          -- block pressure
	StaminaCost: number,
	Animation: string,              -- key into Animations
	Startup: number,                -- seconds before active (frame data)
	Active: number,
	Recovery: number,
	Hitbox: HitboxSpec,
	Knockback: { Speed: number, Up: number, Duration: number }?,
	Hitstun: number,
	Locks: { { From: number, To: number, Move: boolean?, Rotate: boolean?, Jump: boolean? } }?,  -- animation-timeline locks
	Tags: { [string]: true }?,      -- "Finisher", "Unblockable"
}

export type WeaponSchema = {
	Id: string,
	Model: Model?,
	Stats: { AttackSpeed: number, MaxPosture: number, WalkSpeedMultiplier: number },
	Animations: { [string]: string | { [string]: string } | { string } },
	Keybinds: { Attack: Enum.UserInputType | Enum.KeyCode, Block: Enum.KeyCode, Dodge: Enum.KeyCode,
		Directions: { [Enum.KeyCode]: Direction } },
	Combo: { Attacks: { AttackSpec }, ResetTime: number, FinisherIndex: number },
	Directional: { [Direction]: AttackSpec },
	LimbTargets: { [Direction]: string },   -- see game.combat.limb-damage-highlight
	Feint: { Enabled: boolean, StaminaCost: number, Window: number }?,   -- per weapon class
	Defense: { ParryWindow: number, ParryCooldown: number, BlockDamageMultiplier: number,
		DodgeIFrames: number, DodgeCooldown: number, DodgeDistance: number, PerfectDodgeWindow: number },
	Timings: { DirectionalWindow: number, InputBuffer: number },
}
```
Keep numbers in seconds; scale `Startup/Active/Recovery` by `1 / AttackSpeed`.

## 4. Action state machine

States: `Idle`, `Attacking` (sub-phase Startup/Active/Recovery), `Blocking`, `Parrying`, `Dodging`, `Stunned` (hitstun), `Parried` (stagger), `GuardBroken`, `Knocked`, `Dead`.

Transition table (who can interrupt whom):
```luau
local CanEnter = {
	Idle      = { Attacking = true, Blocking = true, Parrying = true, Dodging = true },
	Attacking = { Dodging = "CancelWindow", Stunned = true, Parried = true, Knocked = true },  -- feint/dodge-cancel only in window
	Blocking  = { Parrying = true, Attacking = true, Dodging = true, GuardBroken = true, Stunned = false },
	Parrying  = { Blocking = true, Stunned = true },
	Dodging   = { Attacking = "Recovery" },
	Stunned   = { },                -- only timer exits (to Idle)
	Parried   = { },
	GuardBroken = { },
	Knocked   = { },
}
```
Forced transitions (from server: Stunned/Parried/GuardBroken/Knocked/Dead) bypass the table.

Use an `ActionId` counter so delayed callbacks from an interrupted action are ignored.

## 5. Input layer (client)

1. Raw input -> **intents**: `Attack(direction?)`, `BlockStart`, `BlockEnd`, `Parry(direction?)`, `Dodge(direction?)`.
2. Directional window: latest W/A/S/D press timestamp; consumed by the next M1/F/Q press if within `DirectionalWindow` (e.g. 0.2-0.3s).
3. F: **press** -> Parry (directional if a direction is buffered, else omni/neutral parry or none - design choice); **held** past `ParryWindow` -> Block (omni). Release -> stop block.
4. Q: Dodge in buffered direction, default Back (or current MoveDirection).
5. **Input buffer**: if an intent arrives during Recovery, store it for `InputBuffer` seconds and execute when the state allows (makes combos feel responsive).

## 6. M1 chain

```luau
-- runtime fields: ComboIndex, LastM1Time
local function NextComboIndex(rt, now, schema)
	if now - rt.LastM1Time > schema.Combo.ResetTime then rt.ComboIndex = 0 end
	rt.ComboIndex = rt.ComboIndex % #schema.Combo.Attacks + 1
	rt.LastM1Time = now
	return rt.ComboIndex
end
```
- Last index (`FinisherIndex`) has `Knockback` + `Tags.Finisher`.
- **S + M1** (Back directional) also uses a knockback spec - in the schema: `Directional.Back.Knockback = {...}`.
- After the finisher, add an end-lag (longer Recovery) so the chain can't loop infinitely.
- Directional attacks: do they advance/reset the chain? Pick one rule (recommend: directional attacks are separate and reset the chain to 0).

## 7. Resolution matrix (server, pure function)

Inputs: attack spec, attack direction (attacker-local), attacker & defender CFrames, defender state + its direction + timing.

```luau
-- returns Outcome
local function Resolve(attack, atkDir, defender, now)
	local incoming = IncomingSide(defender.Root, attacker.Root.Position, atkDir) -- side of defender being hit
	local s = defender.State
	if s == "Dodging" and now <= defender.IFramesUntil then
		if defender.DodgeDir == CounterDirection[incoming] and now - defender.DodgeStart <= PERFECT then
			return "PerfectDodge"
		end
		return "Dodged"
	end
	if s == "Parrying" and now - defender.ParryStart <= schema.ParryWindow then
		if defender.ParryDir == nil or ParryMatches(Config.ParryRule, atkDir, incoming, defender.ParryDir) then return "Parried" end
		return "Hit"                          -- wrong-direction parry = punished
	end
	if s == "Blocking" and IsFacing(defender.Root, attacker.Root.Position) then
		-- knockback attacks are blocked like any other; they just carry a higher PostureDamage
		if defender.Posture - attack.PostureDamage <= 0 then return "GuardBreak" end
		return "Blocked"
	end
	if s == "Attacking" and defender.Phase == "Active" and defender.ActionStartedBefore(attackStart) then
		return "Clash"                        -- optional trade rule
	end
	return "Hit"
end
```
Outcome effects:
| Outcome | Attacker | Defender |
|---|---|---|
| Hit | combo continues | damage, hitstun, (knockback if spec) |
| Blocked | small recoil | chip damage × BlockDamageMultiplier, posture damage, block-stun |
| Parried | Parried state (stagger ~0.6s), posture damage | stamina/posture refund, counter window |
| Dodged | whiff | nothing |
| PerfectDodge | short stagger or none | i-frames extended, stamina refund, counter window / free directional |
| GuardBreak | — | GuardBroken (long stun), posture reset |
| Clash | both pushed back | both pushed back |

Configurable parry rule (`Config.ParryRule`):
```luau
-- "Mirrored": defender presses the side the attack comes FROM in their own view (attacker D -> defender A)
-- "Same":     defender presses the same key the attacker used (attacker D -> defender D)
local function ParryMatches(rule: "Mirrored" | "Same", atkDir, incomingSide, parryDir): boolean
	if rule == "Same" then return parryDir == atkDir end
	return parryDir == incomingSide
end
```

`CounterDirection` ("counter-direction dodge"): dodging *away from / perpendicular to* the incoming side. Define explicitly, e.g. incoming Left -> perfect dodge Right; incoming Right -> Left; incoming Front -> Back; Back -> Front. Using the same "direction matches a rule" check as directional parry keeps it one code path ("a tie script-wise").

## 8. Exhaustion / stamina / posture economy

Two meters are common:
- **Stamina** (spent by actions: M1 small, directional medium, dodge large, parry attempt small; regenerates after `RegenDelay`). At 0 -> **Exhausted**: can't dodge/parry, slower, until refilled to a threshold.
- **Posture** (defender's block bar; filled by blocked hits; full -> GuardBreak; decays over time; parries reduce your own and add to attacker's).
One meter ("Exhaustion") is simpler: everything raises it, it decays, high exhaustion slows recovery, max = stunned/guard broken. Pick one for v1.

Server owns the values; replicate to the owner (Packet `Stamina`) and optionally others (attribute for UI over heads).

## 8b. Feints (per weapon class)

During **Startup** of a directional attack the attacker presses the feint key (or a different direction + M1) to cancel into another direction / back to idle for `Feint.StaminaCost`. The white telegraph already showed. This baits parries, so readable startup and feints together make the mind game. Rules: only within `Feint.Window` from the start, max one feint per attack, the server validates like any intent.

## 8c. Combo breaker (optional)

A "burst" button usable **while in hitstun**: costs a big chunk of stamina (or needs a full meter), pushes nearby attackers back and grants brief i-frames. It stops infinite M1 chains in 2v1s. Alternatives: hitstun decay (each consecutive hit within a chain gives less hitstun) or a max chain length before a forced knockback.

## 9. Frame data

`Startup` (telegraph, readable by defender) -> `Active` (hitbox on) -> `Recovery` (punishable). For a reaction-based game, startup must exceed human reaction + ping: total ~0.35-0.5s for directional attacks, parry window ~0.15-0.25s, and show the incoming-direction indicator at startup.

## 10. Server/client flow (one attack)

1. Client: input -> intent `Attack(Left)`; checks local state; enters `Attacking` locally (predict), plays animation, fires `Net.Input`.
2. Server: validate (alive, state, cooldown, stamina), set authoritative state, deduct stamina, broadcast `Net.Action(actor, Attack, Left, comboIndex)` -> other clients show direction indicator/VFX (animation already replicates via Animator).
3. Attacker client: during `Active` the client-local HitboxClass hitbox runs; hits → `Net.HitClaim(ActionId, target, time, cf)`.
   Server: validates the claim (state, window, rewound geometry, victim corroboration if borderline), runs `Resolve` against the defender's state **at claim time**, applies effects (damage, posture, limb meter, status effects), broadcasts `Net.Result(attacker, defender, outcome, damage)`.
4. Clients: play reactions/VFX for `Result`; defender's client applies knockback / stun locally (it owns physics).
5. If the server rejected step 2, it sends `Net.Cancel` to the attacker -> client stops animation and returns to Idle.

## 11. Testing

- Dummies (NPC Model + Humanoid) with a server-driven "AI" that blocks/parries on a timer to test outcomes.
- Debug flags: draw hitboxes, print resolve inputs, simulated latency (Studio: File > Studio Settings > Network > Incoming Replication Lag).
- Unit-test the resolver as a pure function (TestEZ / Jest-Lua or a simple assert script).
