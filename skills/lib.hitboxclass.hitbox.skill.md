---
name: lib.hitboxclass.hitbox
description: RedTrioVirus HitboxClass (v1.2.0) - OOP spatial-query hitbox module. Setup (Alive/Projectile folders, auto-created remote + LocalScript), HitboxParams, spatial options (Magnitude/InBox/InRadius/InPart), Start/Stop/Check/WeldTo/SetSize/ClearTaggedChars, signals (HitSomeone/HitObject), DotProductRequirement, velocity prediction, IntervalTimer, UseClient mode internals, and its security gaps. Use when creating hitboxes for this project.
---

# HitboxClass (RedTrioVirus) — v1.2.0

Repo/releases: `https://github.com/RedTrioVirus/HitboxClass/releases` (tags v1.0, v1.1, v1.1A, v1.1B, v1.2.0 adds `SetSize`). MIT.
Wally: `HitboxClass = "redtriovirus/hitboxclass@1.2.0"` (depends on `sleitnick/signal@2.0.3`, **not** GoodSignal).

## 1. Setup

```
ReplicatedStorage/Packages
├─ HitboxClass (init.luau)
│  ├─ Types, Timer, HitboxClassLocal (client LocalScript template)
│  └─ Settings (Folder)
│     ├─ AliveFolder      (ObjectValue -> workspace folder holding players/NPC models)
│     ├─ ProjectileFolder (ObjectValue -> workspace folder for VFX/hitbox parts)
│     └─ VelocityPredictionConstant (NumberValue, default 6)
└─ Signal (sleitnick)
```
- **Characters must be inside the Alive folder** or they are never detected (only `Model`s with a `Humanoid` and `PrimaryPart`). Parent player characters into `workspace.Alive` on `CharacterAdded` (R6 characters keep working when reparented).
- Must be `require`d **on the server once**: at require time the server creates `ReplicatedStorage.HitboxClassRemote` (raw RemoteEvent), clones `HitboxClassLocal` into `StarterPlayerScripts`, and into a `ScreenGui` in every current player's `PlayerGui`. This happens even if you never use client mode.
- Runtime setters: `HitboxClass.SetAliveFolder(folder)`, `SetProjectileFolder(folder)`, `SetVelocityPredictionConstant(n)`.

```luau
local HitboxClass = require(ReplicatedStorage.Packages.HitboxClass)
local HitboxTypes = require(ReplicatedStorage.Packages.HitboxClass.Types)
```

## 2. HitboxParams

```luau
export type HitboxParams = {
	SizeOrPart: Vector3 | number | BasePart,          -- REQUIRED
	SpatialOption: ("InBox" | "InRadius" | "InPart")?,
	InitialPosition: CFrame?,                          -- default CFrame.new(0,0,0)
	Blacklist: { Model }?,                             -- e.g. { attackerCharacter }
	DebounceTime: number?,                             -- seconds before same model can be hit again (0 = once until ClearTaggedChars)
	DotProductRequirement: DotProductRequirement?,
	UseClient: Player?,                                -- client-side mode (server only)
	ID: (string | number)?,
	VelocityPrediction: boolean?,                      -- default true on server hitboxes
	Debug: boolean?,                                   -- draws red part
	Debris: number?,                                   -- auto destroy N s after Start
	LookingFor: ("Humanoid" | "Object")?,              -- default "Humanoid"
}
export type DotProductRequirement = {
	DotProduct: number,                                -- threshold; 0 = within 90deg
	PartForVector: BasePart,
	VectorType: ("LookVector" | "UpVector" | "RightVector")?,
	Negative: boolean?,
}
```

Size → query mapping:
| SizeOrPart | no SpatialOption | InBox | InRadius | InPart |
|---|---|---|---|---|
| number | **Magnitude** (distance to PrimaryPart, cheapest) | cube `GetPartBoundsInBox` | sphere `GetPartBoundsInRadius` | generated sphere `GetPartsInPart` |
| Vector3 | `GetPartBoundsInBox` | box | ✗ | generated box part |
| BasePart | always `GetPartsInPart` with that part | ✗ | ✗ | ✓ |

## 3. API

Module functions: `HitboxClass.new(params) -> (Hitbox, connected: boolean)` (**yields up to 1.5 s when `UseClient` is set**), `ClearClientHitboxes(player)`, `ClearHitboxesWithID(id)`, `GetHitboxCache()`, `SetAliveFolder`, `SetProjectileFolder`, `SetVelocityPredictionConstant`.

| Method | Notes |
|---|---|
| `:Start()` | begins stepping every Heartbeat; signals only fire after Start (or on Check) |
| `:Stop()` | disconnects stepping, removes generated part |
| `:Check()` | single query; returns hits on server-sided hitboxes (nil for UseClient) |
| `:SetPosition(cf)` | ignored while welded |
| `:SetSize(Vector3 \| number)` | live resize (v1.2.0) |
| `:WeldTo(part, offset?)` | follow a part each step (enables velocity prediction) |
| `:Unweld()`, `:ChangeWeldOffset(cf)` | |
| `:ClearTaggedChars()` | allow already-hit models to be hit again -> call **per swing** when reusing one hitbox |
| `:SetVelocityPrediction(bool)`, `:SetDebug(bool)` | |
| `:Destroy()` | stop, clear tables, disconnect signals |

Signals (sleitnick Signal): `HitSomeone: Signal<{Model}>` (LookingFor Humanoid), `HitObject: Signal<{BasePart}>` (LookingFor Object). Fired with **arrays of new hits** in that step.

Velocity prediction (server, welded): offset = `cf:VectorToObjectSpace(part.AssemblyLinearVelocity) / constant` - leads the hitbox in the movement direction.

`Timer.new(timeout, callback) -> IntervalTimer` (`On`, `Off`, `Destroy`, `Elapsed` signal) - Heartbeat accumulator; reliable only for timeouts ≥ 0.1 s.

## 4. Typical use

```luau
local Hitbox = HitboxClass.new({
	SizeOrPart = Vector3.new(5, 5, 6),
	SpatialOption = "InBox",
	Blacklist = { character },
	DebounceTime = 0,
	DotProductRequirement = { DotProduct = 0.2, PartForVector = root },
	Debug = DEBUG_HITBOXES,
} :: HitboxTypes.HitboxParams)

Hitbox:WeldTo(root, CFrame.new(0, 0, -3.5))
Hitbox.HitSomeone:Connect(function(models) for _, m in models do OnHit(m) end end)

-- each swing (Active window):
Hitbox:ClearTaggedChars() ; Hitbox:Start()
task.delay(activeDuration, function() Hitbox:Stop() end)
```

## 5. UseClient mode internals (and why this project doesn't rely on it)

Flow: server `new({UseClient = player})` -> `FireClient(player, "New", params + _Tick)` -> client LocalScript builds the same hitbox -> client fires back `_Tick` (ack, ≤1.5 s wait) -> server mirrors commands (`"Start"`, `"Stop"`, `"Weld"`, `"SzCh"`, `"ClrTag"`, `"Des"`...) -> client steps and `FireServer(_Tick, {Model})` on hits -> server filters and fires `HitSomeone`.

Server-side filtering of client hits only checks: sender == `self.Client`, tick matches, entries are `Model`s **inside the Alive folder** with a `Humanoid`, not blacklisted.
It does **not** check distance, timing, facing, rate or that the attacker is attacking. An exploiter can report any Alive model at any time while a hitbox exists.

Other costs: one raw RemoteEvent with uncompressed tables, a 1.5 s yield to create each client hitbox, a round-trip of command messages per swing.

**Project decision (client-side detection + multi-client validation):** create HitboxClass hitboxes **directly on the attacker's client** (plain `HitboxClass.new` on the client, no `UseClient`), reuse one per weapon runtime, and report hits through our Packet `C_HitClaim` with the swing's ActionId. The server validates with the rules in `game.combat.hit-validation-multiclient`. HitboxClass is used purely as the client-side query engine.

## 6. Limitations to remember

- Returns models, not which limb was hit (use `LookingFor = "Object"` for parts, but then it isn't Alive-filtered - filter yourself). This project derives the targeted limb from the attack direction instead.
- Magnitude mode uses `PrimaryPart` distance only (size ignores limbs).
- Requires characters reparented to the Alive folder - account for that in any code that assumes `workspace[player.Name]`.
