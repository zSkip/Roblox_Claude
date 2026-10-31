---
name: game.combat.architecture-patterns
description: Combat system design patterns for Roblox fighting games - dual-context (shared) modules with injected adapters, blueprint/runtime split, data-driven weapon schema, action state machine with transition rules, input buffering (directional windows, tap vs hold), M1 combo chains with finisher knockback, directional attack/parry/dodge resolution matrix, block/posture/exhaustion economy, frame data (startup/active/recovery), hitstun/i-frames, cancel windows, server authority + client prediction flow. Use when designing or implementing any combat feature in this project.
---

# Combat — Architecture & Patterns

Project decisions: **R6 only**, weapons are Models on a `Motor6D` (no `Tool`), **client-side hit detection with multi-client validation** (game.combat.hit-validation-multiclient), knockback attacks are **blockable** (they deal higher posture damage), the parry direction rule is a **config value**.

Companion skills: core.contracts.interfaces, game.combat.limb-damage-highlight, game.combat.animation-movement-lock, game.status-effects.lol-stats-cc, roblox.input.userinput-contextaction, roblox.animation.animator-tracks, roblox.spatial.raycast-overlap-hitbox, roblox.physics.movers-knockback, roblox.network.remotes-replication-security.

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
Signals = `Deps.Signal` (any SignalLike from core.contracts.interfaces: immediate, cheap).

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
	ExhaustionStacks: number?,      -- default from Config (regular M1 counting / heavy for knockback)
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
	Feint: { Enabled: boolean, ExhaustionStacks: number, Window: number }?,   -- per weapon class
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

1. Raw input -> **intents**: `Attack(direction?)`, `DefendStart(direction?)`, `DefendEnd`, `Dodge(direction?)`, `Breaker`, `FollowUp`.
2. Directional window: latest W/A/S/D press timestamp; consumed by the next M1/F/Q press if within `DirectionalWindow` (e.g. 0.2-0.3 s).
3. **F with no buffered direction → omni Block immediately** (posture absorbs hits). **F with a buffered direction → directional Parry** window; still holding F after the window → Block. Release → stop.
4. Q: Dodge in the buffered direction, default Back (or current MoveDirection).
5. **Input buffer**: an intent arriving during Recovery is stored for `InputBuffer` seconds and executed when the state allows.

### Shift-lock first (user's choice, built around it)
- Directions are always **character-relative labels** from the keys (W = Front of the character). With shift-lock the character faces the camera, so keys, camera and character agree. That's the reference experience.
- Without shift-lock: at action start, snap the character's yaw to the camera's yaw (`root.CFrame = CFrame.lookAlong(root.Position, flatCameraLook)`), then apply the action's rotation lock. Attacks then still go where the player is looking.
- UI, hitbox offsets and telegraphs assume over-the-shoulder framing (`Humanoid.CameraOffset`).

## 6. Attack registry (modular - new attacks are data)

Every attack is a registered **AttackDef** with an input pattern and a target. Combo M1s, directional M1s and future specials (legs, head, sweeps) all use the same pipeline:

```luau
export type AttackDef = AttackSpec & {
	Id: string,
	Input: { Button: "M1" | "M2" | string, Direction: Direction?, RequiresState: string?, ComboIndex: number? },
	Target: string?,          -- limb group key (see game.combat.limb-damage-highlight), nil = no limb meter
	ExhaustionStacks: number?, -- overrides the default stack cost
	Priority: number?,        -- tie-break when several patterns match
}

local Registry: { AttackDef } = {}
local function Register(def: AttackDef) table.insert(Registry, def) ; table.sort(Registry, function(a, b) return (a.Priority or 0) > (b.Priority or 0) end) end

local function Match(button: string, dir: Direction?, rt): AttackDef?
	for _, def in Registry do
		local i = def.Input
		if i.Button == button and i.Direction == dir
			and (i.RequiresState == nil or rt.Current == i.RequiresState)
			and (i.ComboIndex == nil or i.ComboIndex == rt:PeekComboIndex()) then
			return def
		end
	end
	return nil
end
```
- Weapon schemas register their attacks on `Define`. A later "leg sweep" is one more `Register({Input = {Button = "M2", Direction = "Back"}, Target = "Legs", ...})`. No resolver changes.
- Directional M1s and the combo chain **mix freely**. The chain index advances on combo M1s only and isn't reset by directional M1s. Spam is limited by **exhaustion stacks** (§8), not by chain rules.
- M1 #4 (finisher) and S+M1 carry `Knockback`. Add end-lag after the finisher.

## 7. Resolution matrix (server, pure function)

Inputs: attack def, attack direction (attacker-local), attacker & defender CFrames, defender state + its direction + timing (all **at claim time**).

```luau
local function Resolve(attack, atkDir, attackerPos, defender, now): Outcome
	local incoming = IncomingSide(defender.Root, attackerPos)   -- side of the defender being hit
	local s = defender.State
	if s == "Dodging" and now <= defender.IFramesUntil then
		if MatchesDirection(Config.CounterDodgeRule, atkDir, incoming, defender.DodgeDir) and now - defender.DodgeStart <= Config.PerfectDodgeWindow then
			return "PerfectDodge"
		end
		return "Dodged"
	end
	if s == "Parrying" and now - defender.ParryStart <= Config.ParryWindow then
		if MatchesDirection(Config.ParryRule, atkDir, incoming, defender.ParryDir) then return "Parried" end
		return "Hit"                                   -- wrong-direction parry = punished
	end
	if (s == "Blocking" or s == "Parrying") and IsFacing(defender.Root, attackerPos) then
		-- knockback attacks are blocked like any other; they just carry a higher PostureDamage
		if defender.Posture - attack.PostureDamage <= 0 then return "GuardBreak" end
		return "Blocked"
	end
	if s == "Attacking" and defender.Phase == "Active" and Config.ClashEnabled then return "Clash" end
	return "Hit"
end
```

| Outcome | Attacker | Defender |
|---|---|---|
| Hit | combo continues, exhaustion stacks | damage, hitstun, knockback if spec, limb meter if `Target` |
| Blocked | small recoil | chip × BlockDamageMultiplier, **posture** damage |
| Parried | Parried (stagger ~0.6 s), posture damage | posture refund |
| Dodged | whiff | nothing |
| PerfectDodge | short stagger (optional) | extended i-frames + **FollowUp window** (§8b) |
| GuardBreak | — | GuardBroken (long stun), posture reset |
| Clash | pushed back | pushed back |

One configurable matcher serves parry and counter-dodge (the "tie script-wise"):
```luau
-- rule "Mirrored": chosen == side the attack comes FROM in the defender's view (attacker D -> A)
-- rule "Same":     chosen == attacker's key (attacker D -> D)
-- rule "Away":     chosen == opposite of the incoming side (counter-dodge default: incoming Left -> dodge Right)
local Opposite = { Left = "Right", Right = "Left", Front = "Back", Back = "Front" }
local function MatchesDirection(rule: string, atkDir: Direction?, incoming: Direction, chosen: Direction?): boolean
	if chosen == nil then return false end
	if rule == "Same" then return chosen == atkDir end
	if rule == "Away" then return chosen == Opposite[incoming] end
	return chosen == incoming
end
-- Config.ParryRule = "Mirrored" ; Config.CounterDodgeRule = "Away"
```

## 8. Meters: posture + in-combat exhaustion stacks

**Posture** (guard): filled by blocked hits (`PostureDamage`); regenerates after `PostureRegenDelay`; full → GuardBreak.

**Exhaustion stacks** (in-combat only, replaces a stamina bar as the anti-spam stat):
| Source | Stacks |
|---|---|
| every `M1sPerStack` M1s (combo or directional; config 1-3, default 2) | +1 (regular) |
| a knockback attack landing or being thrown (`Tags.Knockback`) | +`HeavyStack` (default 3) |
| dodge / parry attempt (optional) | +1 |
| combo breaker | +`BreakerStacks` |

- Stacks decay only **out of combat**: no combat action and no hits taken for `OutOfCombatDelay` (e.g. 4 s), then −1 per `DecayInterval`.
- Past `Threshold` (e.g. 6) the **Exhausted** debuff applies and scales per extra stack: `intensity = stacks - Threshold + 1`. Each intensity level gives, for example, −6% attack speed, +8% posture damage taken, +0.05 s recovery and −4% walk speed, capped at `MaxIntensity`.
- Implemented as an **Intensity-stacking status effect** (`game.status-effects.lol-stats-cc`), so its modifiers flow through the StatBlock.

```luau
local function AddExhaustion(rt, amount: number, now: number)
	rt.InCombatUntil = now + Config.OutOfCombatDelay
	rt.ExhaustionStacks = math.min(rt.ExhaustionStacks + amount, Config.MaxStacks)
	local intensity = rt.ExhaustionStacks - Config.Threshold + 1
	if intensity > 0 then rt.Status:SetIntensity("Exhausted", math.min(intensity, Config.MaxIntensity), now)
	else rt.Status:Remove("Exhausted") end
end
local function OnM1(rt, now)
	rt.M1Counter += 1
	if rt.M1Counter >= Config.M1sPerStack then rt.M1Counter = 0 ; AddExhaustion(rt, 1, now) end
end
```
Server owns stacks; replicate to the owner (`Meters` channel) and show stacks over heads for readability.

## 8b. Counter-dodge follow-up window

On `PerfectDodge` the defender gets `FollowUp = { Window = 0.45, Attack = "CounterSlash" }`. Pressing M1 (or a configured key) inside the window performs the registered follow-up attack: faster startup, guaranteed stagger on hit, or a free directional. The window is server-tracked (`rt.FollowUpUntil`); the follow-up is an AttackDef with `Input.RequiresState = "FollowUp"`.

## 8c. Feints (per weapon class)

During **Startup** of a directional attack the attacker cancels into another direction or back to idle (`Feint = {Enabled, Window, ExhaustionStacks}` per weapon). The white telegraph already showed, which baits parries. Max one feint per attack; the server validates it like any intent.

## 8d. Combo breaker

- Usable **only while in hitstun** (`Stunned` from hits, not GuardBroken/Parried), once per `BreakerCooldown` (e.g. 20 s).
- Costs `BreakerStacks` exhaustion (e.g. +3) and requires being below a stack cap, so an exhausted player can't escape for free.
- Effect: removes hitstun, short radial push (LinearVelocity on attackers within ~8 studs, owner-applied via the Knockback channel), 0.4 s i-frames, a white flash.
- Server validates: in hitstun, cooldown ready, stacks < cap. It's an intent like any other (`Breaker`).
- Optional companion: **diminishing hitstun**. Each consecutive hit within a chain on the same target gives ×0.85 hitstun.

## 9. Frame data

`Startup` (telegraph, readable by defender) -> `Active` (hitbox on) -> `Recovery` (punishable). For a reaction-based game, startup must exceed human reaction + ping: total ~0.35-0.5s for directional attacks, parry window ~0.15-0.25s, and show the incoming-direction indicator at startup.

## 10. Server/client flow (one attack)

1. Client: input -> intent `Attack(Left)`; checks local state; enters `Attacking` locally (predict), plays animation, fires `Net.Input`.
2. Server: validate (alive, state, cooldown, status `Can("Attack")`), set authoritative state, count exhaustion, broadcast `Net.Action(actor, Attack, Left, comboIndex)` -> other clients show direction indicator/VFX (animation already replicates via Animator).
3. Attacker client: during `Active` the client-local hitbox query (`Deps.Hitbox`) runs; hits → `Net.HitClaim(ActionId, target, time, cf)`.
   Server: validates the claim (state, window, rewound geometry, victim corroboration if borderline), runs `Resolve` against the defender's state **at claim time**, applies effects (damage, posture, limb meter, status effects), broadcasts `Net.Result(attacker, defender, outcome, damage)`.
4. Clients: play reactions/VFX for `Result`; defender's client applies knockback / stun locally (it owns physics).
5. If the server rejected step 2, it sends `Net.Cancel` to the attacker -> client stops animation and returns to Idle.

## 11. Combatants: PvP and PvE

- A **Combatant** wraps any `Model` with a Humanoid: `{ Model, Root, Humanoid, Player?, Runtime, Status, Stats, Posture, Limbs }`. Players and NPCs share all resolver, effect and limb code.
- **Player attackers**: client hitbox → claim → validation (game.combat.hit-validation-multiclient).
- **NPC attackers**: the server runs the hitbox query itself (NPCs are server-owned, `root:SetNetworkOwner(nil)`). No claims.
- **NPC victims**: the server answers victim corroboration itself (it owns NPC physics).
- NPC brains are separate modules that emit the same intents a client would (`Attack(dir)`, `DefendStart(dir)`, `Dodge(dir)`), so AI is just another input source.
- PvE tuning knobs: per-NPC schema overrides (slower startup, longer telegraph), damage multipliers by faction.

## 12. Testing

- Unit tests for pure modules (resolver, MatchesDirection, exhaustion math, registry matching): see luau.testing.unit-tests, which includes a TestKit you can drop in.
- Dummies (NPC combatants) with a scripted brain that blocks/parries on a timer to test outcomes in play mode.
- Debug flags: draw hitboxes, print resolve inputs, simulated latency (Studio Settings → Network → Incoming Replication Lag).
