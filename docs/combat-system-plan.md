# Combat System — v1 Plan

OOP, class-based, reaction-based melee combat for Roblox (Luau).
Libraries: **ProfileStore** (data), **GoodSignal** (events), **Packet** (networking).
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
├─ Packages
│  ├─ Packet                 (Suphi)       - shared networking
│  └─ GoodSignal             (stravant)    - shared events
└─ Combat
   ├─ WeaponClass            ← G1: the single dual-context constructor module
   │   ├─ Definition         (blueprint: schema + states, frozen)
   │   ├─ Runtime            (per owner: state machine, combo, timers, signals)
   │   └─ State              (Entered/Exited signals, Bind sugar)
   ├─ CombatTypes            (export types: schema, enums-as-types)
   ├─ CombatEnums            (frozen id tables: Action, Direction, Outcome, DamageType)
   ├─ CombatConfig           (global tuning: windows, stamina costs)
   ├─ Resolver               (pure: attack vs defense → Outcome; identical on both sides)
   ├─ Net                    (Packet definitions, shared)
   └─ Weapons
      └─ LinkedSword         (definition module: schema + state wiring)

ServerScriptService
├─ Packages/ProfileStore
├─ Data/PlayerData           (ProfileStore sessions, keybind settings, stats)
└─ Combat/CombatServer       (entry: validates intents, owns state/stamina, hitboxes, damage, broadcasts)

StarterPlayer/StarterPlayerScripts
└─ Combat/CombatClient       (entry: input → intents, prediction, animations, VFX/UI, local knockback)
```

### How "dual context with no IsServer" works
- `WeaponClass` and everything in `ReplicatedStorage/Combat` only does **pure logic plus signals**.
- Each side's **entry script** decides what reacts. For example, `Runtime.StateEntered` gets connected to *play animation* on the client and to *open hit window* on the server.
- Anything engine-side that differs (which Animator, how damage is applied, the clock) is passed in through an **adapter** table or connected as a signal handler.
- Packet still uses `IsServer` internally. That's fine: it's a library, and our code doesn't need to branch.

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
		MaxStamina = 100 ;
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

	Keybinds = {                                           -- defaults; player overrides come from ProfileStore
		Attack = Enum.UserInputType.MouseButton1 ;
		Defend = Enum.KeyCode.F ;
		Dodge = Enum.KeyCode.Q ;
		Directions = { [Enum.KeyCode.W] = "Front" ; [Enum.KeyCode.S] = "Back" ; [Enum.KeyCode.A] = "Left" ; [Enum.KeyCode.D] = "Right" } ;
	} ;

	Combo = {
		ResetTime = 1.1 ;
		Attacks = {
			{ Animation = "M1.1" ; Startup = 0.18 ; Active = 0.10 ; Recovery = 0.22 ; StaminaCost = 4 ; Hitstun = 0.35 ; Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
			{ Animation = "M1.2" ; Startup = 0.18 ; Active = 0.10 ; Recovery = 0.22 ; StaminaCost = 4 ; Hitstun = 0.35 ; Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
			{ Animation = "M1.3" ; Startup = 0.18 ; Active = 0.10 ; Recovery = 0.22 ; StaminaCost = 4 ; Hitstun = 0.35 ; Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
			{ Animation = "M1.4" ; Startup = 0.25 ; Active = 0.12 ; Recovery = 0.55 ; StaminaCost = 8 ; Hitstun = 0.6 ;
			  Damage = { Type = "Physical" ; Amount = 12 } ;
			  Knockback = { Speed = 55 ; Up = 18 ; Duration = 0.2 } ; Tags = { Finisher = true } ;
			  Hitbox = { Size = Vector3.new(6, 5, 7) ; Offset = CFrame.new(0, 0, -4) } } ;
		} ;
	} ;

	Directional = {
		Front = { Animation = "Directional.Front" ; Startup = 0.38 ; Active = 0.12 ; Recovery = 0.35 ; StaminaCost = 12 ; Hitstun = 0.5 ; PostureDamage = 20 ; Hitbox = { Size = Vector3.new(4, 5, 8) ; Offset = CFrame.new(0, 0, -4.5) } } ;
		Left  = { Animation = "Directional.Left"  ; Startup = 0.38 ; Active = 0.12 ; Recovery = 0.35 ; StaminaCost = 12 ; Hitstun = 0.5 ; PostureDamage = 20 ; Hitbox = { Size = Vector3.new(7, 5, 5) ; Offset = CFrame.new(0, 0, -3) } } ;
		Right = { Animation = "Directional.Right" ; Startup = 0.38 ; Active = 0.12 ; Recovery = 0.35 ; StaminaCost = 12 ; Hitstun = 0.5 ; PostureDamage = 20 ; Hitbox = { Size = Vector3.new(7, 5, 5) ; Offset = CFrame.new(0, 0, -3) } } ;
		Back  = { Animation = "Directional.Back"  ; Startup = 0.42 ; Active = 0.12 ; Recovery = 0.5  ; StaminaCost = 14 ; Hitstun = 0.6 ; PostureDamage = 25 ;
		          Knockback = { Speed = 60 ; Up = 20 ; Duration = 0.2 } ;                      -- S+M1 always knockback
		          Hitbox = { Size = Vector3.new(5, 5, 6) ; Offset = CFrame.new(0, 0, -3.5) } } ;
	} ;

	Defense = {
		ParryWindow = 0.2 ; ParryCooldown = 0.6 ; ParryStaminaCost = 6 ;
		BlockDamageMultiplier = 0.15 ; BlockWalkSpeedMultiplier = 0.5 ;
		DodgeIFrames = 0.25 ; DodgeDuration = 0.3 ; DodgeSpeed = 45 ; DodgeCooldown = 0.9 ; DodgeStaminaCost = 15 ;
		PerfectDodgeWindow = 0.12 ;
	} ;

	Timings = { DirectionalWindow = 0.25 ; InputBuffer = 0.2 } ;

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
local Signal = require(game.ReplicatedStorage.Packages.GoodSignal) ;
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
		Stamina = self.Schema.Stats.MaxStamina ;
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

**Server entry** (excerpt) hooks hit windows:
```luau
Def.Instantiated:Connect(function(Rt)
	Rt.StateChanged:Connect(function(New, _, Ctx)
		if New == "Attacking" then ScheduleHitWindow(Rt, Ctx.Attack, Rt.ActionId) end ;
	end) ;
end) ;
```

---

## 6. Combat rules (v1 defaults; to confirm with you)

### Input (client)
- **Direction buffer:** keeps the latest W/A/S/D press and its `os.clock()` time. The next action key consumes it if it's within `DirectionalWindow` (0.25s). No per-frame cleanup loop.
- **M1:** with a buffered direction it's a **Directional attack**. Without one, it's the **next combo M1**.
- **F press:** opens a **parry window** (`ParryWindow` 0.2s), directional if a direction is buffered. **Keep holding F** past the window and you're **blocking** (omni). Release stops the block. Parry happens on press, so it has no input delay.
- **Q:** **Dodge** in the buffered direction (default Back). The dodge has i-frames.
- **Input buffer:** an action pressed during Recovery runs as soon as Recovery ends, if pressed within 0.2s of the end.

### Resolution (server, `Resolver` module, pure and unit-testable)
| Defender state | vs normal M1 | vs directional | vs knockback (M1 #4 / S+M1) |
|---|---|---|---|
| Idle / moving | Hit | Hit | Hit + knockback |
| Blocking (facing) | Blocked (chip, stamina/posture loss) | Blocked (heavier posture loss) | **Question for you:** guard break, or blocked? |
| Blocking (hit from behind) | Hit | Hit | Hit + knockback |
| Parry, matching direction | Parried | Parried | Parried |
| Parry, wrong direction | Hit | Hit (punished) | Hit + knockback |
| Parry, no direction (F with no WASD) | **Question:** omni parry for M1 only? | — | — |
| Dodge i-frames | Dodged | Dodged | Dodged |
| Dodge in counter direction, in perfect window | Perfect dodge (bonus) | Perfect dodge | Perfect dodge |

**Direction convention.** The attacker's *Right* swing lands on the defender's *Left* side when they face each other. The defender's parry key is "the side the attack comes from, in the defender's own view". So the defender parries an attacker's `D` with `A`. Counter-direction dodge = dodge *away* from the incoming side (incoming Left → dodge Right). Both checks use the same `MatchesDirection(rule, incoming, chosen)` function. That's the "tie script-wise".

### Exhaustion
One meter for v1: **Stamina**, 0–100, server-owned.
- Costs: M1 4, directional 12–14, parry attempt 6, dodge 15. A successful block costs `PostureDamage × 0.5`.
- Rewards: successful parry +10, perfect dodge +15.
- Regen: 20/s after 0.8s with no spending.
- At 0 → **Exhausted** for 1.5s: no dodge or parry, block breaks on the next hit, walk speed ×0.7.
This lets players mix directional and normal play while making spam self-limiting.

### Knockback
- M1 #4 and S+M1 carry a `Knockback` spec.
- The server sends `Net.Knockback` to the victim's client, which applies a `LinearVelocity` locally because it owns its character's physics.
- NPCs are server-owned (`SetNetworkOwner(nil)`), so the server applies it directly.

---

## 7. Networking (Packet)

```luau
-- ReplicatedStorage/Combat/Net
local Packet = require(game.ReplicatedStorage.Packages.Packet) ;
return {
	-- client → server
	Intent    = Packet("C_Intent", Packet.NumberU8, Packet.NumberU8, Packet.NumberF64) ;   -- Action, Direction, ClientServerTime
	-- server → all
	Action    = Packet("S_Action", Packet.Instance, Packet.NumberU8, Packet.NumberU8, Packet.NumberU8) ; -- Actor, Action, Direction, ComboIndex
	Result    = Packet("S_Result", Packet.Instance, Packet.Instance, Packet.NumberU8, Packet.NumberU16) ; -- Attacker, Defender, Outcome, Damage
	-- server → one
	Stamina   = Packet("S_Stamina", Packet.NumberU8) ;
	Knockback = Packet("S_Knockback", Packet.Vector3F24, Packet.NumberF16, Packet.NumberF64) ;  -- Velocity, Duration, ServerTime
	Cancel    = Packet("S_Cancel", Packet.NumberU8) ;                                         -- reason
} ;
```
- Every incoming `Intent` is validated: ranges, alive, state transition allowed, cooldown, stamina, rate limit.
- **Damage is never sent by the client.**
- `S_Action` broadcasts at attack **startup**, so every client can flash the incoming-direction indicator. That indicator is what makes the system reaction-based.

---

## 8. Data (ProfileStore)

Template: `Equipped.Weapon`, `OwnedWeapons`, `Keybinds` (Enum names), `Settings`, `Combat` stats.
- Runtime combat values (stamina, combo, cooldowns) are never saved.
- Optional combat-log penalty uses `Profile.OnLastSave` (reason ≠ "Shutdown" and in combat).

---

## 9. Build order (milestones)

1. **M0 – Setup.** Folder layout, packages (Packet, GoodSignal, ProfileStore), `CombatTypes`, `CombatEnums`, `Net`, PlayerData loader.
2. **M1 – Core module.** `WeaponClass` (Define / Instantiate / State / Runtime) plus schema validation, then the LinkedSword definition.
3. **M2 – Client input & prediction.** Direction buffer, intents, M1 chain with animations on a dummy, respawn-safe track cache.
4. **M3 – Server authority.** Intent validation, state machine, stamina, schedule-based hitboxes (debug draw), damage, `S_Result`.
5. **M4 – Defense.** Block (hold F), parry (press F, directional), dodge (Q with i-frames, counter bonus), Resolver unit tests.
6. **M5 – Knockback & finishers.** M1 #4, S+M1, victim-side LinearVelocity, NPC path.
7. **M6 – Feedback.** Incoming-direction indicator, hitstop, VFX/SFX, stamina bar, damage numbers.
8. **M7 – Polish.** Input buffer, cancel windows, lag leniency/rewind, rebinding UI, mobile/gamepad.

---

## 10. What I need from you

### Information (decisions)
1. **Direction convention.** Should a defender parry an attacker's `D` swing with `A` (the side it comes from, as I propose) or with `D` (the same key)?
2. **Directional attack trigger.** Only a *tap* within the window, or also "W held while clicking"?
3. **F with no direction.** Should it be an omni parry, an instant block, or nothing until held?
4. **Knockback vs block.** Does a knockback attack guard-break a blocker, push them back, or just get blocked?
5. **Directional attacks and the chain.** Should they reset the M1 chain, continue it, or stay separate?
6. **Counter-dodge bonus.** What does the bonus give: longer i-frames, a stamina refund, a free counter window, or a slow-mo flash?
7. **Exhaustion model.** One stamina meter (proposed), or stamina plus a separate posture/guard meter?
8. **Hit detection authority.** Server hitboxes (proposed: secure, slightly less responsive at high ping), or client-detected hits with server validation (snappier)?
9. **Weapon delivery.** A `Tool` in the Backpack, or a model welded to the character with our own equip key?
10. **Camera.** Is shift-lock forced in combat? This decides whether WASD means "camera-relative" or "character-relative".
11. **Scope.** PvP only or PvE too? Expected players per server? Mobile and gamepad support in v1?
12. **Rig type.** R6 or R15? This affects the animations and hitbox offsets.

### Material (assets)
- Animation asset ids, **owned by the same user/group as the game**, for: idle, M1 ×4, directional ×4, parry ×4 (or 1), block hold, block impact, dodge ×4, hit-react ×4, stagger, guard break, knockback/launch, getting up.
- Animation timing per attack: when the swing becomes dangerous and when it ends (or add `KeyframeMarker`s named `HitStart`/`HitEnd` so I can read them).
- The weapon model(s) with a `Handle`/PrimaryPart and the grip offset.
- VFX and SFX ids if you have them. Placeholders work otherwise.
- The **Packet version** you use. I built the reference from v1.7.x source; tell me if yours is newer.
- Your `IndexerV2` module, if it should stay in the design (its purpose isn't clear from the sample).

---

## 11. What we could add to improve

- **Incoming-attack direction indicator.** Arrows or edge glow on the defender's screen at the attacker's startup. A reaction-based system needs it, since you can't parry what you can't read.
- **Feints.** Cancel a directional attack's startup into another direction for stamina. This adds mind games on top of reactions.
- **Input buffer and cancel windows.** These are what make combos feel responsive and not sticky.
- **Hitstop, camera shake, and Highlight flashes** per outcome (see `roblox.feedback.tween-vfx-sound-camera` §7).
- **Clash rule.** When two attacks' active frames overlap, both get pushed back. This is cheap to add and very readable.
- **Lag compensation.** Rewind defender positions by the attacker's ping (bounded to 200 ms) and judge parries with a bounded client timestamp.
- **Combo-breaker or burst.** Costs stamina and escapes long hitstun chains. It stops infinite combos in group fights.
- **Diminishing hitstun** for repeated hits on the same target.
- **Schema validation and a debug overlay.** Hitbox drawing, state labels over heads, a resolver log.
- **Resolver unit tests.** The resolver is a pure function, so a matrix test catches balance and logic regressions.
- **Rebinding UI** saved in ProfileStore, plus mobile CAS buttons and gamepad mapping (right stick or D-pad for directions).
- **Weapon variety through the schema alone,** for example a heavy weapon (slow startup, high posture damage) and a light weapon (fast chain, low damage).
- **Analytics.** Parry rate and hit rate per weapon, for balancing.

---

## 12. Skills index

See [README](../README.md#skills). Each skill file is under 60 KB and grouped by a `domain.subject.focus` naming scheme.
