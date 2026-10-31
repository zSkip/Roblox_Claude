# Combat System — v1 Plan

OOP, class-based, reaction-based melee combat for Roblox (Luau).
Libraries: **ProfileStore** (data), **GoodSignal** (events), **Packet** (networking), optionally **HitboxClass**. All of them plug in as **adapters** behind small built-in contracts (`Core/Deps`: Signal, Net, Hitbox, SessionStore). The game code never requires a library directly, and each contract also has a zero-dependency implementation (`skills/core.contracts.interfaces`).
Reference skills for every API used here are in [`/skills`](../skills) (see [README](../README.md)).

---

## 1. Goals (from your brief)

| # | Feature | Summary |
|---|---|---|
| G1 | Dual-context constructor | One ModuleScript in ReplicatedStorage builds weapons. No `RunService:IsServer()/IsClient()` inside it. The server and client entry scripts hold the side-specific code. |
| G2 | Schema-driven weapons | A weapon is a stat schema: `Damage {Type, Amount}`, `Animations {...}`, `Keybinds {...}`, plus timings. |
| G3 | Normal combo | M1 chain 1-2-3-4. The last M1 always knocks back. |
| G4 | Directional attacks | A W/A/S/D press followed by M1 inside a time window gives a directional hit. **S+M1 always knocks back.** |
| G5 | Directional parry | Same direction-window system, using F. |
| G6 | Omni block | Holding F blocks from every direction. |
| G7 | Dodge | Q, using the buffered direction. A dodge in the counter direction gets a bonus. It uses the same matching code as parry ("a tie, script wise"). |
| G8 | Exhaustion | A resource that stops players spamming directional and normal actions together. |
| G9 | Reaction-based | Defenders must be able to *see* the incoming attack and its direction, then react in time. |

---

## 2. Review of the current code (what to keep and what to fix)

### Keep
- The **class/metatable** approach: `WeaponMaker.NewWeapon` → `:CreateState` → `:BindEnum / :BindAnimation / :BindFunction / :MaidFunction`. This builder-style API reads well and stays in the plan as sugar.
- The idea that **setting a state active runs bound functions and deactivating runs maids**. This becomes `Entered`/`Exited` signals.
- The time-displacement idea (`TimeDisplacement`, `GeneralDisplacementMax`). This becomes the directional window.

### Bugs and design problems found

| Where | Problem | Fix in v1 |
|---|---|---|
| `BindClassMeta.__newindex` | Every write except `IsActive` is silently dropped. That includes the `AdditionalDictionary` copy loop in `CreateState`. `IsActive` is never stored, so `MainData.IsActive` stays `false` forever. | Explicit `State:SetActive(bool)`, or a proxy that stores values (see `luau.metatables.oop-classes` §4) |
| `__newindex` | Only calls `BoundFunctions[1]()` / `BoundMaids[1]()`, so any second bound function never runs. | Signals (all connections run) |
| `__newindex` | Setting `IsActive = true` twice re-runs the enter logic. There is no guard. | Early return if unchanged |
| `WeaponMaker.CreatedWeapons[Identifier]` holds **the** weapon, with its `States` and `IsActive` | The definition is shared by every player who uses it, so one player's Idle toggles everyone's. On the server, one object serves all players. | **Blueprint/runtime split**: a definition (shared, frozen) plus a runtime per owner |
| `BindAnimation` | `RunService:IsServer()` / `IsClient()` branches (against G1). The client branch captures `LocalPlayer.Character` once, so tracks break after a respawn. The server branch uses a single `Loader` AnimationController just to read `Length`, and `Length` is `0` until the asset loads. | The schema stores animation **ids plus timings**. Each side loads tracks into the right Animator when a runtime is created (per character). Server logic uses schema timings, not `Length`. |
| `BindEnum` | Binds are stored per weapon definition, and keybinds are hard-coded in weapon code. | Keybinds go in the schema (defaults) and can be overridden by player settings (ProfileStore) |
| `CreateGeneralBind` (commented out) | The MouseButton branch writes `AdditionalDictionary` into `self.KeyBinds` instead of `self.MouseBinds`. | Becomes obsolete once the input normaliser exists |
| Input test | `table.remove` inside a forward `for` loop skips elements. The `KeyTrackMax = 2` cap blocks new presses until old ones expire. `#KeyTrack > 1` needs *two* keys before a directional hit works. It uses `KeyTrack[1]` (the oldest press), not the latest. `HitDictionary` loads every animation a second time. `CharacterAdded:Wait()` hangs if the character already exists, and nothing handles respawn. | Single "latest direction + timestamp" buffer (no per-frame cleanup), tracks cached per character |
| Packet | The default `Types/Enums.luau` doesn't include `Enum.UserInputType`, so `Packet.EnumItem` can't send `MouseButton1`. | Send our own `NumberU8` action/direction ids (smaller anyway) |

---

## 3. Architecture

```
ReplicatedStorage
├─ Core                     (Deps, Signal, Net, Hitbox, Maid: contracts + built-in implementations)
├─ TestKit                  (unit tests, src/ReplicatedStorage/TestKit.luau)
├─ Packages                 (adapters plugged into Core/Deps)
│  ├─ Packet                 (Suphi, v1.7.x)  - shared networking (all combat traffic)
│  ├─ GoodSignal             (stravant)       - shared events
│  ├─ HitboxClass            (RedTrioVirus v1.2.0, + sleitnick Signal) - client-side hit queries
│  └─ IndexerV2              (yours)          - identifier-routed networking (non-combat / or rebuilt on Packet)
└─ Combat
   ├─ WeaponClass            ← G1: the single dual-context constructor module
   │   ├─ Definition         (blueprint: schema + states, frozen)
   │   ├─ Runtime            (per owner: state machine, combo, timers, signals)
   │   └─ State              (Entered/Exited signals, Bind sugar)
   ├─ CombatTypes / CombatEnums / CombatConfig   (ParryRule lives in Config)
   ├─ Resolver               (pure: attack vs defense → Outcome + Consequences; unit-tested)
   ├─ Stats                  (pure: LoL formulas + StatBlock modifiers; unit-tested)
   ├─ StatusEffects          (effect definitions + StatusController)
   ├─ Limbs                  (direction → limb mapping, meter math)
   ├─ Directions / Exhaustion (pure, unit-tested: src/ReplicatedStorage/Combat)
   ├─ Attacks                (AttackDef registry + FromSchema: combo, directional, follow-ups, future specials; unit-tested)
   ├─ Net                    (channel definitions via Deps.Net, shared)
   └─ Weapons
      └─ LinkedSword         (definition module: schema + state wiring)

ServerScriptService
├─ Core/SessionStore         (contract; ProfileStore adapter)
├─ Tests                     (*.spec modules + RunTests, Studio only)
├─ Data/PlayerData           (profile sessions, saved keybinds, stats)
└─ Combat/CombatServer       (entry: intents, authoritative state/posture/exhaustion, claim validation,
                              position + state history, damage, effects, broadcasts)

StarterPlayer/StarterPlayerScripts
└─ Combat/CombatClient       (entry: input → intents, prediction, animations + movement locks,
                              Deps.Hitbox queries → claims, victim/witness answers, highlights, VFX/UI)

Workspace
├─ Alive                     (all player characters + NPCs; needed if the HitboxClass adapter is used)
└─ Effects                   (VFX / projectile folder)
```

### How "dual context with no IsServer" works
- `WeaponClass` and everything in `ReplicatedStorage/Combat` only does **pure logic plus signals**.
- Each side's **entry script** decides what reacts. For example, `Runtime.StateEntered` gets connected to *play animation* on the client and to *open hit window* on the server.
- Anything engine-side that differs (which Animator, how damage is applied, the clock) is passed in through an **adapter** table or connected as a signal handler.
- Infrastructure modules (Core/Net, Packet, ProfileStore) branch on `IsServer` internally. That's fine: game code never does.

---

## 4. Schema: what a weapon looks like (your style)

```luau
-- ReplicatedStorage/Combat/Weapons/LinkedSword
local WeaponClass = require(game.ReplicatedStorage.Combat.WeaponClass) ;

local LinkedSword = WeaponClass.Define({

	Id = "LinkedSword" ;

	Model = script.LinkedSword ;

	Stats = {
		AttackSpeed = 1 ;
		WalkSpeedMultiplier = 0.85 ;
		MaxPosture = 100 ;          -- block meter; full posture damage = GuardBroken
		PostureRegen = 15 ;         -- per second after PostureRegenDelay
		PostureRegenDelay = 1.5 ;
		Armor = 0 ; MagicResist = 0 ; Tenacity = 0 ;   -- LoL-style stats (see status effects)
	} ;

	Damage = { Type = "Physical" ; Amount = 8 } ;          -- default for every attack unless overridden

	Animations = {
		Idle = "rbxassetid://0" ;
		M1 = { "rbxassetid://0", "rbxassetid://0", "rbxassetid://0", "rbxassetid://0" } ;
		Directional = { Front = "rbxassetid://0" ; Back = "rbxassetid://0" ; Left = "rbxassetid://0" ; Right = "rbxassetid://0" } ;
		Parry = { Front = "rbxassetid://0" ; Back = "rbxassetid://0" ; Left = "rbxassetid://0" ; Right = "rbxassetid://0" } ;
		Block = "rbxassetid://0" ;
		BlockImpact = "rbxassetid://0" ;
		Dodge = { Front = "rbxassetid://0" ; Back = "rbxassetid://0" ; Left = "rbxassetid://0" ; Right = "rbxassetid://0" } ;
		HitReact = { Front = "rbxassetid://0" ; Back = "rbxassetid://0" ; Left = "rbxassetid://0" ; Right = "rbxassetid://0" } ;
		Stagger = "rbxassetid://0" ;
		GuardBreak = "rbxassetid://0" ;
	} ;

	Keybinds = {                                           -- defaults; player overrides come from the saved profile
		Attack = Enum.UserInputType.MouseButton1 ;
		Defend = Enum.KeyCode.F ;
		Dodge = Enum.KeyCode.Q ;
		Directions = { [Enum.KeyCode.W] = "Front" ; [Enum.KeyCode.S] = "Back" ; [Enum.KeyCode.A] = "Left" ; [Enum.KeyCode.D] = "Right" } ;
	} ;

	Combo = {
		ResetTime = 1.1 ;
		Attacks = {
			{ Animation = "M1.1" ; Startup = 0.18 ; Active = 0.10 ; Recovery = 0.22 ; Hitstun = 0.35 ; PostureDamage = 10 ; Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
			{ Animation = "M1.2" ; Startup = 0.18 ; Active = 0.10 ; Recovery = 0.22 ; Hitstun = 0.35 ; PostureDamage = 10 ; Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
			{ Animation = "M1.3" ; Startup = 0.18 ; Active = 0.10 ; Recovery = 0.22 ; Hitstun = 0.35 ; PostureDamage = 10 ; Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
			{ Animation = "M1.4" ; Startup = 0.25 ; Active = 0.12 ; Recovery = 0.55 ; Hitstun = 0.6 ; PostureDamage = 35 ;   -- knockback: blockable, just heavy on posture
			  Damage = { Type = "Physical" ; Amount = 12 } ;
			  Knockback = { Speed = 55 ; Up = 18 ; Duration = 0.2 } ; Tags = { Finisher = true } ;
			  Hitbox = { Size = Vector3.new(6, 5, 7) ; Offset = CFrame.new(0, 0, -4) } } ;
		} ;
	} ;

	Directional = {
		Front = { Animation = "Directional.Front" ; Startup = 0.38 ; Active = 0.12 ; Recovery = 0.35 ; Hitstun = 0.5 ; PostureDamage = 20 ; Hitbox = { Size = Vector3.new(4, 5, 8) ; Offset = CFrame.new(0, 0, -4.5) } } ;
		Left  = { Animation = "Directional.Left"  ; Startup = 0.38 ; Active = 0.12 ; Recovery = 0.35 ; Hitstun = 0.5 ; PostureDamage = 20 ; Hitbox = { Size = Vector3.new(7, 5, 5) ; Offset = CFrame.new(0, 0, -3) } } ;
		Right = { Animation = "Directional.Right" ; Startup = 0.38 ; Active = 0.12 ; Recovery = 0.35 ; Hitstun = 0.5 ; PostureDamage = 20 ; Hitbox = { Size = Vector3.new(7, 5, 5) ; Offset = CFrame.new(0, 0, -3) } } ;
		Back  = { Animation = "Directional.Back"  ; Startup = 0.42 ; Active = 0.12 ; Recovery = 0.5  ; Hitstun = 0.6 ; PostureDamage = 40 ;
		          Knockback = { Speed = 60 ; Up = 20 ; Duration = 0.2 } ;                      -- S+M1 always knockback
		          Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
	} ;

	Defense = {
		ParryWindow = 0.2 ; ParryCooldown = 0.6 ;
		BlockDamageMultiplier = 0.15 ; BlockWalkSpeedMultiplier = 0.5 ;
		DodgeIFrames = 0.25 ; DodgeDuration = 0.3 ; DodgeSpeed = 45 ; DodgeCooldown = 0.9 ;
		PerfectDodgeWindow = 0.12 ;
	} ;

	Timings = { DirectionalWindow = 0.25 ; InputBuffer = 0.2 } ;

	LimbTargets = { Right = "Left Arm" ; Left = "Right Arm" ; Front = "Torso" ; Back = "Torso" } ;   -- mirrored, R6 (Legs/Head reserved)
	Limbs = {
		["Left Arm"]  = { Max = 100 ; PerHit = 25 ; Chip = 3 ; BurstDamage = 15 ; Effect = "ArmBroken" } ;
		["Right Arm"] = { Max = 100 ; PerHit = 25 ; Chip = 3 ; BurstDamage = 15 ; Effect = "Disarmed" } ;
		Torso         = { Max = 120 ; PerHit = 25 ; Chip = 4 ; BurstDamage = 20 ; Effect = "Bleeding" } ;
		Legs          = { Max = 100 ; PerHit = 30 ; Chip = 3 ; BurstDamage = 12 ; Effect = "Hobbled" } ;
	} ;

	Feint = { Enabled = true ; ExhaustionStacks = 1 ; Window = 0.2 } ;   -- per weapon class

	-- Every attack spec may also carry Locks = { { From, To, Move, Rotate, Jump } } (animation-timeline locks).

} :: WeaponClass.WeaponSchema) ;

-- Your builder sugar still works; these become signal connections on each runtime.
-- The weapon module stays shared: put side-specific reactions in the entry scripts.
local Idle = LinkedSword:CreateState({ StateName = "Idle" }) ;

return LinkedSword ;
```

`WeaponClass.Define` validates the schema once (missing animations, negative timings) and freezes it.

---

## 5. WeaponClass core (sketch of the single shared module)

```luau
--!strict
-- ReplicatedStorage/Combat/WeaponClass
local Signal = require(game.ReplicatedStorage.Core.Deps).Signal ;   -- GoodSignal adapter or the built-in one
local Types = require(script.Parent.CombatTypes) ;

export type WeaponSchema = Types.WeaponSchema ;

local WeaponClass = { Definitions = {} :: { [string]: any } } ;

---------------------------------------------------------------- State (per runtime)
local State = {} ; State.__index = State ;

function State.new(Name: string)
	return setmetatable({
		Name = Name ;
		IsActive = false ;
		Entered = Signal.new() ;   -- (Runtime, Context)
		Exited = Signal.new() ;    -- (Runtime, Context, Reason)
	}, State) ;
end ;

function State:SetActive(Active: boolean, Runtime: any, Context: any?, Reason: string?)
	if self.IsActive == Active then return end ;
	self.IsActive = Active ;
	if Active then self.Entered:Fire(Runtime, Context) else self.Exited:Fire(Runtime, Context, Reason) end ;
end ;

---------------------------------------------------------------- Definition (blueprint, shared)
local Definition = {} ; Definition.__index = Definition ;

function WeaponClass.Define(Schema: WeaponSchema)
	assert(WeaponClass.Definitions[Schema.Id] == nil, `duplicate weapon {Schema.Id}`) ;
	local self = setmetatable({
		Id = Schema.Id ;
		Schema = table.freeze(Schema) ;
		StateHooks = {} :: { [string]: { Enter: { (any, any) -> () }, Exit: { (any, any, string?) -> () } } } ;
		Instantiated = Signal.new() ;  -- (Runtime) - entry scripts hook per-owner setup here
	}, Definition) ;
	WeaponClass.Definitions[Schema.Id] = self ;
	return self ;
end ;

-- Builder sugar (keeps your API): definition-level hooks copied into every runtime's states
function Definition:CreateState(Data: { StateName: string })
	local Hooks = { Enter = {}, Exit = {} } ;
	self.StateHooks[Data.StateName] = Hooks ;
	return {
		BindFunction = function(_, Fn) table.insert(Hooks.Enter, Fn) end ;
		MaidFunction = function(_, Fn) table.insert(Hooks.Exit, Fn) end ;
	} ;
end ;

---------------------------------------------------------------- Runtime (per owner, per side)
local Runtime = {} ; Runtime.__index = Runtime ;

function Definition:Instantiate(Owner: Model)
	local Rt = setmetatable({
		Definition = self ;
		Schema = self.Schema ;
		Owner = Owner ;
		States = {} :: { [string]: any } ;
		Current = nil :: string? ;
		ActionId = 0 ;
		ComboIndex = 0 ;
		LastM1Time = -math.huge ;
		Exhaustion = Exhaustion.New() ;   -- in-combat stacks (src/ReplicatedStorage/Combat/Exhaustion)
		Cooldowns = {} :: { [string]: number } ;
		StateChanged = Signal.new() ;   -- (NewState, OldState, Context)
		Destroyed = Signal.new() ;
	}, Runtime) ;
	for Name, Hooks in self.StateHooks do
		local S = State.new(Name) ;
		for _, Fn in Hooks.Enter do S.Entered:Connect(Fn) end ;
		for _, Fn in Hooks.Exit do S.Exited:Connect(Fn) end ;
		Rt.States[Name] = S ;
	end ;
	self.Instantiated:Fire(Rt) ;
	return Rt ;
end ;

function Runtime:SetState(Name: string, Context: any?, Reason: string?): boolean
	if self.Current == Name then return false end ;
	local Old = self.Current ;
	self.ActionId += 1 ;
	if Old and self.States[Old] then self.States[Old]:SetActive(false, self, Context, Reason) end ;
	self.Current = Name ;
	if self.States[Name] then self.States[Name]:SetActive(true, self, Context) end ;
	self.StateChanged:Fire(Name, Old, Context) ;
	return true ;
end ;

function Runtime:NextComboIndex(Now: number): number
	local Combo = self.Schema.Combo ;
	if Now - self.LastM1Time > Combo.ResetTime then self.ComboIndex = 0 end ;
	self.ComboIndex = self.ComboIndex % #Combo.Attacks + 1 ;
	self.LastM1Time = Now ;
	return self.ComboIndex ;
end ;

function Runtime:Destroy()
	if self.Current then self.States[self.Current]:SetActive(false, self, nil, "Destroyed") end ;
	self.Destroyed:Fire() ;
	for _, S in self.States do S.Entered:DisconnectAll() ; S.Exited:DisconnectAll() end ;
	self.StateChanged:DisconnectAll() ;
end ;

return WeaponClass ;
```

**Client entry** (excerpt) hooks animations without the shared module knowing about Animators:
```luau
for _, Def in WeaponClass.Definitions do
	Def.Instantiated:Connect(function(Rt)
		if Rt.Owner ~= Players.LocalPlayer.Character then return end ;
		Rt.Tracks = LoadTracks(Rt.Owner, Rt.Schema.Animations) ;   -- per character, reloaded on respawn
		Rt.StateChanged:Connect(function(New, Old, Ctx) PlayStateAnimation(Rt, New, Ctx) end) ;
	end) ;
end ;
```

**Server entry** (excerpt) opens the window in which hit claims are accepted:
```luau
Def.Instantiated:Connect(function(Rt)
	Rt.StateChanged:Connect(function(New, _, Ctx)
		if New == "Attacking" then OpenClaimWindow(Rt, Ctx.Attack, Rt.ActionId) end ;   -- ActiveStart/ActiveEnd from schema timings
	end) ;
end) ;
```
The **client entry** starts the local `Deps.Hitbox` query for the same window and sends claims (see §10).

---

## 6. Decisions log (revision 2)

| Topic | Decision |
|---|---|
| Parry key | **Configurable**: `CombatConfig.ParryRule = "Mirrored"` (defender presses the side the attack comes from: attacker D → defender A) or `"Same"` (defender presses the attacker's key). Default `"Mirrored"`. |
| Knockback vs block | Knockback attacks are **blocked** like others. They don't guard-break by tag; they carry higher `PostureDamage`, so they break guard only when posture runs out. |
| Posture | New stat: `MaxPosture`, `PostureRegen`, `PostureRegenDelay`, and `PostureDamage` on every attack spec. |
| Hit detection | **Client-side** (a `Deps.Hitbox` query, built-in or HitboxClass adapter, running locally on the attacker) with **multi-client validation** (server hard checks + rewind, victim corroboration for borderline claims, witness sampling for a trust score). See `game.combat.hit-validation-multiclient`. |
| Rig | **R6 always.** |
| Animations | Placeholder ids (`rbxassetid://0`) + schema timings. Swapping in real animations doesn't change any logic. |
| Weapon model | Model attached with a **Motor6D** (`Handle` joint on `Right Arm`), not a Tool grip. No `Tool` class anywhere. |
| Packet | v1.7.x (the newest source I could read; Wally mirrors go up to 1.7.3). |
| Indexer | Your network module. Documented in `project.indexer.networking`, including bugs to fix and a version that runs your API on top of Packet. |
| Incoming-attack telegraph | **White Highlight** on the attacker's body during startup (client-side). |
| Feints | Yes, configured **per weapon class** (`Feint = {Enabled, ExhaustionStacks, Window}`). |
| Lag compensation | Yes: server position/state history, rewind bounded to 250 ms. |
| Combo breaker | **Yes.** Spec in §9. |
| Rebinds | Saved in the profile (`Keybinds` as Enum names). |
| Unit tests | **Yes.** `TestKit` + Studio runner + specs for `Directions`, `Exhaustion`, `Resolver`, `Attacks` and `Stats` are in `src/`. |
| W+M1 / S+M1 targets | **Both Torso.** Legs and Head are registered limb groups reserved for future attacks (modular `AttackDef` registry). |
| Limb break functionality | Decided later. The framework has pluggable `BreakHandlers`. |
| Directional M1s vs chain | They mix freely; spam is limited by **in-combat exhaustion stacks** (every 1-3 M1s = 1 stack, knockback = heavy stack, past a threshold a scaling debuff). Replaces the stamina bar. |
| F with no direction | **Omni block** with posture, immediately. F + direction = directional parry, then block while held. |
| Counter-dodge bonus | A **follow-up window** for a registered follow-up attack. |
| Camera | Shift-lock is the user's choice, but everything is **built around shift-lock** (character yaw snaps to camera at action start when it's off). |
| Scope | **PvP and PvE.** Shared `Combatant` abstraction; NPCs use server-side hitboxes and emit the same intents. |
| Skills | Every non-library skill codes against `core.contracts.interfaces`; no skill hard-requires a library. |

## 7. Combat rules (current)

### Input (client)
- **Direction buffer:** keeps the latest W/A/S/D press and its time. The next M1/F/Q press consumes it if within `DirectionalWindow` (0.25 s).
- **M1:** with a buffered direction → **directional M1** (targets a limb). Without one → **next combo M1** (1-2-3-4; #4 knocks back).
- **S + M1:** directional Back; always knockback; targets the Torso.
- **F with no buffered direction:** omni **block** immediately (posture). **F + buffered direction:** directional parry window, then block while held. Release ends the block.
- **Q:** dodge in the buffered direction (default Back), with i-frames. A counter-direction dodge inside the perfect window = perfect dodge → **follow-up window** (0.45 s) for the weapon's follow-up attack.
- **Combo breaker:** usable only in hitstun; costs exhaustion stacks; removes hitstun, pushes attackers away, short i-frames; long cooldown.

### Resolution matrix (pure `Resolver`, judged at the claim's time)
| Defender state | vs combo M1 | vs directional M1 | vs knockback (M1 #4 / S+M1) |
|---|---|---|---|
| Idle / moving | Hit | Hit + limb meter | Hit + knockback (+ limb meter if directional) |
| Blocking, facing | Blocked (posture) | Blocked (more posture) | **Blocked (high posture)**; posture empty → GuardBreak |
| Blocking, hit from behind | Hit | Hit + limb | Hit + knockback |
| Parry, direction matches `ParryRule` | Parried | Parried | Parried |
| Parry, wrong direction | Hit | Hit + limb (punished) | Hit + knockback |
| Dodge i-frames | Dodged | Dodged | Dodged |
| Counter-direction dodge in perfect window | PerfectDodge | PerfectDodge | PerfectDodge |

Parry and counter-dodge share one function, `MatchesDirection(rule, attackDir, incomingSide, chosenDir)` (the "tie script-wise").

### Meters
- **Exhaustion stacks** (in combat): every `M1sPerStack` M1s (1-3, default 2) = +1; a knockback = +`HeavyStack` (3); feint/breaker add stacks. Past `Threshold` (6) the `Exhausted` debuff scales per extra stack (attack speed, move speed, posture damage taken, recovery). Decays only out of combat. Pure math in `src/ReplicatedStorage/Combat/Exhaustion.luau`, unit-tested.
- **Posture** (guard): filled by blocked hits (`PostureDamage`), regenerates after `PostureRegenDelay`; full → `GuardBroken` (long stun).
- **Limb meters**: filled by directional hits (see §8).

## 8. Directional limb system (how I interpret your idea)

1. A directional M1 picks a **target limb** on the defender from the direction (schema `LimbTargets`, mirrored because the fighters face each other):
   D+M1 → defender's **Left Arm**, A+M1 → **Right Arm**, W+M1 → **Torso**, S+M1 → **Torso** (+ knockback).
   **Legs** and **Head** are registered limb groups for future attacks. Each attack names its `Target` in the `AttackDef` registry, so adding them later is pure data.
2. A landed hit does **small chip damage** and adds `PerHit` to that limb's meter.
3. That limb gets a **red Highlight** whose fill goes from transparent to **solid** as the meter rises.
4. At full: **burst**. Extra damage, then the limb group's **break handler** runs. Handlers are pluggable (`BreakHandlers[group]`); the default just resets the meter and applies a generic `LimbBroken` effect, so the actual functionality can be decided later.
5. Blocked hits fill **posture**, not the limb meter. Parried or dodged hits fill nothing.
6. Highlights are client-side with a budget (Roblox renders ~31 at once), with an overlay-part fallback. See `game.combat.limb-damage-highlight`.

## 9. Features added in this revision

### Status effects (League of Legends model)
- Stats: AD/AP-style scaling, Armor/MR (`100/(100+resist)`), penetration order, Tenacity (multiplicative, doesn't affect Airborne), strongest-slow-only, ability haste, life steal, heal/shield power, Grievous Wounds.
- Modifiers: Flat / PercentAdd / PercentMult in a `StatBlock`.
- CC taxonomy: Stun, Root, Slow, Cripple, Silence, Disarm, Grounded, Blind, Nearsight, Airborne, Suppression, Charm/Taunt/Fear, Sleep, Polymorph, Stasis. Each one says what it blocks: move, rotate, attack, defend, dodge.
- Stack modes: Refresh / Extend / Independent / Intensity / Ignore.
- Server-authoritative `StatusController` with `Can("Move")`-style gates and `SetIntensity` for meter-driven debuffs (Exhausted), replicated as compact channel events.
- **Your Trello card couldn't be opened from my environment.** Paste its contents and I'll align names and values. See `game.status-effects.lol-stats-cc`.

### Animation-timeline movement locks
- Each attack spec has `Locks = { {From, To, Move, Rotate, Jump} }` in seconds, scaled by attack speed. They can be replaced by `KeyframeMarker`s later.
- Locks are applied as self-inflicted status effects, so stuns and locks share one movement gate.
- Client enforcement: PlayerModule `Controls:Disable()` for movement, `AutoRotate = false` plus a rigid `AlignOrientation` for rotation (shift-lock safe), and jumping disabled.
- The server checks displacement during locked windows (anti-slide) and feeds the trust score. See `game.combat.animation-movement-lock`.

### Feints (per weapon class)
During a directional attack's startup, cancel into another direction or into idle for `Feint.ExhaustionStacks`, inside `Feint.Window`, once per attack.

### Combo breaker (decided: yes)
- Usable **only while in hitstun** from hits (not during GuardBroken or Parried stagger). Cooldown about 20 s.
- Costs `BreakerStacks` exhaustion (e.g. +3) and is refused above a stack cap, so it's a real resource decision.
- Effect: clears hitstun, radial push on attackers within ~8 studs, 0.4 s i-frames (`BreakerIFrames`), white burst VFX.
- Plus **diminishing hitstun** (×0.85 per consecutive hit on the same target) so chains naturally loosen.

### Unit tests (explanation)
**Now included:** `src/ReplicatedStorage/TestKit.luau`, `src/ServerScriptService/Tests/RunTests.server.luau`, and specs for `Directions`, `Exhaustion`, `Resolver` (the full §7 matrix), `Attacks` and `Stats`. Press Play in Studio and results print to Output. A unit test is a tiny script that calls one function with fixed inputs and checks the answer. For example: "an idle defender hit by a knockback M1 returns Hit + knockback", or "a block against a knockback returns Blocked, not GuardBreak, when posture is 100". The resolver, stat math, combo index and direction→limb mapping are pure functions, so a table of cases can run in Studio in milliseconds whenever balance changes. If a change breaks parry logic, a test fails before players notice. See `luau.testing.unit-tests` (zero-dependency runner, TestEZ, Jest Lua, Lune).

### Pure logic modules (milestone M1)
All live in `src/ReplicatedStorage/Combat`, take `Now` and snapshots as arguments, and touch no Instances or clocks.

| Module | API | Notes |
|---|---|---|
| `Resolver` | `Resolve(Attack, Defender, Now, Config?) → Outcome`, `Consequences(Outcome, Spec, Defense?, ChainHits?)`, `IncomingSide`, `OutcomeIds` | Priority: i-frames (PerfectDodge / Dodged) → parry window (Parried, or Hit if wrong direction) → block or parry held past its window (Blocked / GuardBreak; covers everything but the back) → optional Clash → Hit. A directional swing from the front lands mirrored (D → defender's Left); flank and back attacks use the geometric side. `PostureDamageTaken` carries the Exhausted multiplier. `Consequences` applies chip (`BlockDamageMultiplier`), posture, limb target, knockback and diminishing hitstun (×0.85 per chained hit). |
| `Attacks` | `NewRegistry()`, `:Register(Def)`, `:Match({Button, Direction?, State?, ComboIndex?})`, `:Get(Id)`, `FromSchema(Schema)` | Pattern: `Direction` nil = none, `"Any"` = wildcard. The highest `Priority` wins, and equal priorities keep registration order. `FromSchema` builds `<Id>.M1.<i>`, `<Id>.Directional.<Dir>` (Target from `LimbTargets`) and `<Id>.FollowUp.<Name>` (priority 10, `RequiresState = "FollowUp"`), plus any custom `Schema.Attacks`; specs inherit `Schema.Damage`. Defs are frozen. |
| `Stats` | `ResistMultiplier`, `EffectiveResist`, `FinalDamage`, `CombinedTenacity`, `CCDuration`, `StrongestSlow`, `Cooldown`, `AttackSpeed`, `Heal`, `NewBlock(Base, Bounds?, OnChanged?)` | StatBlock: `(Base + ΣFlat) × (1 + ΣPercentAdd) × ΠPercentMult`, clamped to bounds; the lowest `Override` wins over everything. `AddModifier` with an existing id replaces it, and `RemoveSource` clears an effect's modifiers. `OnChanged` fires only on real changes (wire it to a `Deps.Signal`), and `Snapshot()` feeds `FinalDamage`. |

## 10. Networking (Deps.Net channels; Packet adapter in production)

```luau
-- ReplicatedStorage/Combat/Net
local Net = require(game.ReplicatedStorage.Core.Deps).Net ;
return {
	-- client → server
	Intent    = Net.Define("C_Intent", { "U8", "U8", "F64" }) ;                    -- Action, Direction, ClientServerTime
	HitClaim  = Net.Define("C_HitClaim", { "U16", "Instance", "F64", "CFrame" }) ; -- ActionId, Target, Time, AttackerCF
	-- server → all
	Action    = Net.Define("S_Action", { "Instance", "U8", "U8", "U8" }) ;         -- Actor, Action, Direction, ComboIndex (→ white telegraph)
	Result    = Net.Define("S_Result", { "Instance", "Instance", "U8", "U16" }) ;  -- Attacker, Defender, Outcome, Damage
	Limb      = Net.Define("S_Limb", { "Instance", "U8", "U8" }) ;                 -- Target, LimbGroupId, Fill(0-255)
	LimbBurst = Net.Define("S_LimbBurst", { "Instance", "U8" }) ;
	Effect    = Net.Define("S_Effect", { "Instance", "U8", "U8", "F64" }) ;        -- Target, EffectId, Stacks, EndsAt
	EffectEnd = Net.Define("S_EffectEnd", { "Instance", "U8" }) ;
	-- server → one
	Meters    = Net.Define("S_Meters", { "U8", "U8" }) ;                           -- Posture%, ExhaustionStacks
	Knockback = Net.Define("S_Knockback", { "Vector3", "F32", "F64" }) ;           -- Velocity, Duration, ServerTime
	Cancel    = Net.Define("S_Cancel", { "U8" }) ;
	-- server → one, with response (multi-client validation)
	HitCheck  = Net.Request("S_HitCheck", { "Instance", "F64", "U8" }, { "U8" }, 0.15) ;
	Witness   = Net.Request("S_Witness", { "Instance", "Instance", "F64" }, { "F32" }, 0.5) ;
} ;
```
- With the Packet adapter these map to `Packet.NumberU8`, `Packet.Instance`, … (table in `core.contracts.interfaces` §2). With the built-in Net they travel over one batched RemoteEvent with type checks.
- The client never sends damage, direction for a claim, or outcome. The server takes those from the validated intent and the schema.
- Your Indexer can implement the same contract for non-combat traffic (`project.indexer.networking`).

## 11. Data (SessionStore contract; ProfileStore adapter)

Template: `Equipped.Weapon`, `OwnedWeapons`, **`Keybinds`** (Enum names, e.g. `{Defend = "F", Dodge = "Q", Attack = "MouseButton1", Front = "W", ...}`), `Settings` (including the player's parry-rule preference if you later allow per-player choice), `Combat` stats.
Runtime values (exhaustion, posture, limb meters, effects, combo) are never saved. Optional combat-log penalty via `Profile.OnLastSave`.

## 12. Build order (milestones)

1. **M0 – Core.** `Core/Deps` with contracts and adapters (Packet, GoodSignal, ProfileStore; HitboxClass optional), TestKit + runner, Alive/Effects folders, `CombatTypes/Enums/Config`, `Net`, PlayerData with saved keybinds.
2. **M1 – Pure logic + tests. ✅ Done.** `Directions`, `Exhaustion`, `Resolver`, `Attacks` (AttackDef registry matching), `Stats` (StatBlock math), each with specs. Details in §9 ("Pure logic modules").
3. **M2 – WeaponClass.** Define/Instantiate/State/Runtime, schema validation, LinkedSword, Motor6D attach (R6), `Combatant` for players and NPCs.
4. **M3 – Client input & prediction.** Direction buffer, F block/parry split, intents, M1 chain with placeholder animations, movement locks, shift-lock yaw snap.
5. **M4 – Server authority.** Intent validation, state machine, posture, exhaustion stacks + debuff, position/state history.
6. **M5 – Hits.** Client hitbox queries → claims → hard checks + rewind → Resolver → damage. Victim corroboration, then the witness trust score. NPC server-side hitboxes.
7. **M6 – Defense & escapes.** Block/parry/dodge, perfect dodge → follow-up window, guard break, combo breaker + diminishing hitstun.
8. **M7 – Limbs & status effects.** StatusController, limb meters + highlights + bursts with default break handlers, knockback.
9. **M8 – Feedback & polish.** White telegraph, hitstop, VFX/SFX, meters UI, feints, input buffer, rebinding UI, mobile/gamepad.

## 13. Still open

1. **Directional trigger:** only a tap inside the window, or also "W held while clicking"? (Default: tap only.)
2. **Follow-up attack:** what does the counter-dodge follow-up do (guaranteed stagger, extra damage, free directional)? Placeholder: fast slash that staggers on hit.
3. **Limb break functionality:** decided later (handlers are ready).
4. **Numbers:** exhaustion threshold, stacks per action, debuff strength per level. Placeholders are in `Exhaustion.DefaultConfig`.

## 14. Skills index

See [README](../README.md#skills). Each skill file is under 60 KB and grouped by a `domain.subject.focus` naming scheme.
