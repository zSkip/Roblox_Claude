---
name: game.combat.animation-movement-lock
description: Locking character movement/rotation/jumping during specific parts of an animation's timeline (R6, client-owned physics) - lock windows in the weapon schema or via KeyframeMarkers, PlayerModule Controls Disable vs WalkSpeed modifiers, AutoRotate and AlignOrientation for rotation lock (shift-lock safe), jump disabling, scaling with attack speed, cancel safety, and server-side displacement validation. Use when an action must root the player for part of its animation.
---

# Animation-Timeline Movement Locks

## V2: what the project ships (tiered lock)

The project uses **tiers sampled every frame**, not on/off windows. `Shared/Combat/LockProfile` is pure:
`Sample(State, Elapsed, Timeline, Config.Lock) -> { Tier, Move, Turn, Jump }`

| Tier | When | Move | Turn |
|---|---|---|---|
| Free 0 | Idle | 1 | AutoRotate |
| Steer 1 | attack windup; block / parry | windup: `(1 - t)^WindupMoveExponent`, eases to 0 on the last windup frame; block: 1 × the block walk cap | windup: 1 → `WindupTurnEnd`; block: 1 |
| Rooted 2 | hit frames, recovery, dodges | 0, then ramps 0 → 1 over the part of recovery after `RecoveryReleaseAt` | `ActiveTurn` / `RecoveryTurn` (dodge: 0, hold facing) |
| Locked 3 | Stunned, GuardBroken, Dead | 0 | 0 |
| Forced 4 | reserved: knockback / airborne | physics drives | 0 |

- The windup length comes from the attack's `Timeline` (Combat/Timeline: animation frames scaled by attack speed). Faster attacks lock sooner but keep the same curve shape.
- **Client (MovementController, RenderStep):** `Humanoid.WalkSpeed = WalkCap × Move`. `WalkCap` is an attribute the server sets per state. Outside Free, `AutoRotate = false` and a `CombatTurn` AlignOrientation steers toward the camera's yaw with `MaxAngularVelocity = Lock.TurnRate × Turn`. At Turn 0 it holds the current facing.
- **Server (HitService.Claim):** `LockProfile.MaxTravel(Timeline, Elapsed, WalkCap, Config.Lock) + Lock.SlideSlack` is the farthest the attacker may have moved since the attack started. A claim from an attacker past that limit is rejected with a warning (anti-slide).
- NPCs are rooted server-side while attacking (`WalkSpeed = 0`).
- Tuning is all in `CombatConfig.Lock`.

The sections below are the original design notes (windows, Controls:Disable) and are still valid alternatives.

Goal: while an action's animation is between time A and B, the player can't walk, turn or jump (or only some of those), so the animation reads naturally and can't be "slid" or "spun".

## 1. Define windows (schema)

```luau
-- inside an AttackSpec / action spec (seconds at AttackSpeed = 1)
Locks = {
	{ From = 0.00 ; To = 0.30 ; Move = true ; Rotate = false ; Jump = true } ;   -- startup: rooted, may still aim
	{ From = 0.30 ; To = 0.42 ; Move = true ; Rotate = true  ; Jump = true } ;   -- active: fully locked
	{ From = 0.42 ; To = 0.60 ; Move = true ; Rotate = false ; Jump = false } ;  -- recovery: rooted
} ;
```
Alternative once real animations exist: `KeyframeMarker`s named `LockMove`, `UnlockMove`, `LockRotate`, `UnlockRotate` read with `track:GetMarkerReachedSignal(name)`. Schema windows are recommended because they work with placeholder animations, on the server for validation, and with `Length == 0`.

Scale by attack speed: `actualTime = From / AttackSpeed`.

## 2. Lock as a status effect (one code path)

Apply a self-inflicted, non-cleansable `ActionLock` effect whose `Blocks = { Move = true, Rotate = true, ... }` (see game.status-effects.lol-stats-cc). Then a single `Status:Can("Move")` drives movement, and stuns and animation locks combine for free.

```luau
local function ScheduleLocks(runtime, spec, speed: number)
	local id = runtime.ActionId
	for i, w in spec.Locks or {} do
		task.delay(w.From / speed, function()
			if runtime.ActionId ~= id then return end                    -- action was interrupted
			runtime.Status:Apply(LockEffect(`Lock{i}`, w, (w.To - w.From) / speed), runtime, os.clock())
		end)
	end
end
-- On cancel / stun / parry: remove all "Lock*" effects immediately.
```

## 3. Enforcing on the owner client (R6, client owns physics)

| Lock | Mechanism | Notes |
|---|---|---|
| Move | `Controls:Disable()` from the PlayerModule **or** WalkSpeed modifier = 0 | Controls:Disable stops input → `MoveDirection` = 0 but keeps UserInputService events firing (your direction buffer still works) |
| Rotate | `Humanoid.AutoRotate = false` + `AlignOrientation` on the root holding the locked yaw | needed because shift-lock / the camera module rotates the root every frame |
| Jump | `Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)` or `JumpHeight = 0` | restore after |

```luau
local Players = game:GetService("Players")
local Controls = require(Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")):GetControls()

local function ApplyLockState(hum: Humanoid, root: BasePart, can: (string) -> boolean, align: AlignOrientation)
	if can("Move") then Controls:Enable() else Controls:Disable() end
	hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, can("Jump"))
	local rotLocked = not can("Rotate")
	hum.AutoRotate = not rotLocked
	if rotLocked and not align.Enabled then
		local _, yaw, _ = root.CFrame:ToOrientation()
		align.CFrame = CFrame.fromOrientation(0, yaw, 0)
	end
	align.Enabled = rotLocked
end
-- setup once per character:
-- local att = root:FindFirstChild("RootAttachment"); local align = Instance.new("AlignOrientation")
-- align.Mode = Enum.OrientationAlignmentMode.OneAttachment; align.Attachment0 = att
-- align.RigidityEnabled = true; align.Enabled = false; align.Parent = root
```
Run `ApplyLockState` whenever the status controller fires `Applied`/`Removed` (reaction-based), not every frame.

Momentum: when Move locks while running, kill horizontal velocity for a crisp stop: `root.AssemblyLinearVelocity *= Vector3.new(0, 1, 0)`, or keep a short slide for feel.

Lunges inside a locked window: the lock disables *player* input; the action applies its own `LinearVelocity` (roblox.physics.movers-knockback).

## 4. Safety

- Always release locks on: action end, interruption (ActionId changed), death, respawn, `WindowFocusReleased`. Use a Maid per action.
- Never let a lock outlive its window: each lock effect has its own duration, so a missed callback can't leave a player stuck.
- Gamepad/mobile: Controls:Disable covers thumbstick and touch movement too.

## 5. Server validation (anti-slide)

Exploiters own their physics and can ignore locks. Server checks during locked windows:
```luau
-- on window start: record root position (server view, rewound by ping if desired)
-- on window end:
local moved = (endPos - startPos) * Vector3.new(1, 0, 1)
local allowed = (spec.LungeDistance or 0) + 2 + targetSpeed * 0.1     -- leniency
if moved.Magnitude > allowed then
	Flag(player, "LockSlide", moved.Magnitude)        -- reduce trust; invalidate this action's hit claims
end
```
Pair this with the hit validation trust score (game.combat.hit-validation-multiclient).
