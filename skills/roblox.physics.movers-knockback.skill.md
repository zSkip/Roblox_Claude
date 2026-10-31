---
name: roblox.physics.movers-knockback
description: Roblox physics for combat movement - BasePart physics props (AssemblyLinearVelocity, mass, Massless, Anchored), ApplyImpulse family, network ownership rules for player characters, constraint movers (LinearVelocity, AlignPosition, AlignOrientation, VectorForce, AngularVelocity) with their enums, deprecated BodyMovers, and recipes for knockback, dashes/dodges, lunges and ragdoll. Use for knockback, dodge movement or any forced motion.
---

# Roblox — Physics, Movers, Knockback

## 1. BasePart physics members

| Member | Notes |
|---|---|
| `Anchored`, `CanCollide`, `CanTouch`, `CanQuery`, `Massless`, `CollisionGroup` | |
| `AssemblyLinearVelocity: Vector3` | velocity of whole assembly (set on root part) |
| `AssemblyAngularVelocity: Vector3` | |
| `AssemblyMass` (ro), `AssemblyRootPart` (ro), `:GetMass()` | |
| `CustomPhysicalProperties` (`PhysicalProperties.new(density, friction, elasticity, frictionWeight, elasticityWeight)`) | |
| `:ApplyImpulse(impulse: Vector3)` | mass * deltaV at center of mass |
| `:ApplyImpulseAtPosition(impulse, worldPos)` | adds spin |
| `:ApplyAngularImpulse(impulse)` | |
| `:SetNetworkOwner(player?)` / `:GetNetworkOwner()` / `:CanSetNetworkOwnership()` / `:SetNetworkOwnershipAuto()` | server only |

## 2. Network ownership (the #1 knockback pitfall)

- Each player's **client owns its character physics**. Velocities/impulses applied **on the server** to a player's HumanoidRootPart are overwritten by the owning client's simulation -> knockback "doesn't work" or stutters.
- Options:
  1. **Constraint created by server** (LinearVelocity in the root) - the instance replicates and the owning client simulates it. Works, but arrives after ~ping.
  2. **Tell the victim's client** (a `Knockback(direction, force, duration)` channel) to apply it locally - smooth for the victim, also server-validated.
  3. Temporarily `root:SetNetworkOwner(nil)` (server simulates) - laggy for the victim; reserve for grabs/cutscenes.
- NPCs (no player) are owned by the server (or auto-assigned to nearby clients! set `root:SetNetworkOwner(nil)` on NPC roots to keep them server-owned for consistent combat).
- `ApplyImpulse` only works where the part is simulated (owner).

## 3. Constraint movers (modern)

All need an `Attachment` (`Attachment0`; root parts usually have `RootAttachment` / `RootRigAttachment`).

### LinearVelocity
| Prop | Notes |
|---|---|
| `Attachment0` | |
| `VelocityConstraintMode: Enum.VelocityConstraintMode` | `Vector` (3D), `Plane` (2D), `Line` (1D) |
| `VectorVelocity: Vector3` | target velocity (Vector mode) |
| `PlaneVelocity: Vector2`, `PrimaryTangentAxis`, `SecondaryTangentAxis` | Plane mode |
| `LineVelocity: number`, `LineDirection` | Line mode |
| `RelativeTo: Enum.ActuatorRelativeTo` | `World`, `Attachment0`, `Attachment1` |
| `MaxForce: number` | use `math.huge` for exact velocity; lower = softer |
| `ForceLimitsEnabled`, `ForceLimitMode: Enum.ForceLimitMode` (`Magnitude`, `PerAxis`), `MaxAxesForce: Vector3`, `MaxPlanarAxesForce` | per-axis lets gravity still act (Y = 0) |

### AlignPosition / AlignOrientation
`Mode: Enum.PositionAlignmentMode.OneAttachment|TwoAttachment`, `Position`, `MaxForce`, `MaxVelocity`, `Responsiveness`, `RigidityEnabled`, `ApplyAtCenterOfMass`. AlignOrientation: `Mode: Enum.OrientationAlignmentMode`, `CFrame`, `MaxTorque`, `MaxAngularVelocity`, `Responsiveness`, `PrimaryAxisOnly`, `AlignType: Enum.AlignType`.
Use AlignOrientation to keep facing the target during a lunge.

### VectorForce / AngularVelocity / Torque
`VectorForce.Force`, `ApplyAtCenterOfMass`, `RelativeTo`. `AngularVelocity.AngularVelocity`, `MaxTorque`.

### Deprecated (still work, avoid in new code)
`BodyVelocity`, `BodyPosition`, `BodyGyro`, `BodyForce`, `BodyAngularVelocity`, `RocketPropulsion`.

## 4. Recipes

### Knockback (owner-side, timed)
```luau
local function Knockback(root: BasePart, direction: Vector3, speed: number, upward: number, duration: number)
	local att = root:FindFirstChild("RootAttachment") or Instance.new("Attachment", root)
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = math.huge
	lv.VectorVelocity = direction.Unit * speed + Vector3.new(0, upward, 0)
	lv.Parent = root
	game:GetService("Debris"):AddItem(lv, duration)
	return lv
end
-- direction = (victimRoot.Position - attackerRoot.Position) * Vector3.new(1,0,1)
```
Or the cheapest one-shot: `root.AssemblyLinearVelocity = dir * speed + Vector3.yAxis * up` on the owner (Humanoid friction will damp it quickly; set `humanoid:ChangeState(Enum.HumanoidStateType.Physics)` / `PlatformStand = true` for a "launched" feel, then restore).

### Dodge / dash (local player)
```luau
local function Dash(root: BasePart, humanoid: Humanoid, localDir: Vector3, speed: number, duration: number)
	local worldDir = root.CFrame:VectorToWorldSpace(localDir) * Vector3.new(1, 0, 1)
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = root:FindFirstChild("RootAttachment") :: Attachment
	lv.ForceLimitsEnabled = true
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(1e6, 0, 1e6)                -- keep gravity
	lv.VectorVelocity = worldDir.Unit * speed
	lv.Parent = root
	task.delay(duration, function() lv:Destroy() end)
end
-- localDir: Front = Vector3.new(0,0,-1), Back = (0,0,1), Left = (-1,0,0), Right = (1,0,0)
```
Raycast ahead first to avoid dashing into walls/off ledges if desired.

### Lunge with M1 (small forward step)
Short LinearVelocity (0.1s, 20-30 studs/s) in `LookVector` direction at swing start.

### Ragdoll (sketch)
On the owner: `humanoid:ChangeState(Enum.HumanoidStateType.Physics)`, `humanoid.BreakJointsOnDeath = false`, replace `Motor6D`s with `BallSocketConstraint`s between their `Attachment`s (create matching attachments), disable motors (`Enabled = false`), restore after. Many games use a vetted ragdoll module.

## 5. Tips

- Velocity units: studs/second; gravity default 196.2 studs/s² (`workspace.Gravity`).
- `Massless` welded weapon parts so they don't change character physics.
- Destroy movers deterministically (Debris or task.delay) and on state interruption.
- For the victim's client applying server-ordered knockback, include a server timestamp; skip if it arrives too late (e.g. > 0.5s) to avoid "ghost" knockbacks.
