---
name: roblox.character.humanoid-players
description: Roblox characters - Players service, Player object, character lifecycle (CharacterAdded/Removing/AppearanceLoaded, LoadCharacter, respawn), Humanoid properties/methods/events, Enum.HumanoidStateType and state control, damage/ForceField, movement control for stuns (WalkSpeed, AutoRotate, jump), R6 vs R15 parts, HumanoidRootPart, and a robust per-character setup/teardown pattern. Use when touching characters or player lifecycle.
---

# Roblox — Players, Characters, Humanoid

## 1. Players service

| Member | Notes |
|---|---|
| `Players.LocalPlayer` | client only (nil on server) |
| `PlayerAdded(player)`, `PlayerRemoving(player)` | also loop `GetPlayers()` for already-joined players |
| `:GetPlayers()` | |
| `:GetPlayerFromCharacter(model)` | nil for NPCs - use to tell players from dummies |
| `:GetPlayerByUserId(id)` | |
| `.CharacterAutoLoads` | false = you call `LoadCharacter` |
| `.RespawnTime` | |
| `.MaxPlayers` | |
| `:GetHumanoidDescriptionFromUserIdAsync(id)` | |

## 2. Player

Properties: `UserId`, `Name`, `DisplayName`, `Character: Model?`, `Team`, `TeamColor`, `Neutral`, `RespawnLocation`, `AccountAge`, `MembershipType`, `CameraMode`, `CameraMaxZoomDistance`, `CameraMinZoomDistance`, `DevEnableMouseLock` (shift-lock allowed), `DevComputerMovementMode`, `AutoJumpEnabled`, `ReplicationFocus`.
Methods: `:Kick(msg?)`, `:LoadCharacter()` (server), `:GetNetworkPing()`, `:GetMouse()` (legacy), `:IsInGroup(id)`, `:GetRankInGroup(id)`, `:GetAttribute()/SetAttribute()`.
Events: `CharacterAdded(char)`, `CharacterRemoving(char)`, `CharacterAppearanceLoaded(char)`, `Chatted` (legacy chat), `Idled`.

## 3. Character lifecycle pattern

```luau
local function OnCharacter(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local maid = Maid.new()
	-- setup combat runtime here
	maid:Give(humanoid.Died:Connect(function() --[[ cleanup state, drop combo ]] end))
	maid:Give(character.Destroying:Connect(function() maid:Clean() end))
end

local function OnPlayer(player: Player)
	if player.Character then task.spawn(OnCharacter, player, player.Character) end
	player.CharacterAdded:Connect(function(c) OnCharacter(player, c) end)
end
for _, p in Players:GetPlayers() do task.spawn(OnPlayer, p) end
Players.PlayerAdded:Connect(OnPlayer)
```
Client version: `local player = Players.LocalPlayer ; local character = player.Character or player.CharacterAdded:Wait()` and re-run setup on every `CharacterAdded` (old Animator/tracks are invalid after respawn). Don't `CharacterAdded:Wait()` unconditionally - it hangs if the character already exists.

`Workspace.PlayerCharacterDestroyBehavior` / `Players.CharacterAutoLoads` affect cleanup; characters may be destroyed or just reparented on respawn.

## 4. Humanoid

Properties:
| Prop | Notes |
|---|---|
| `Health`, `MaxHealth` | server-authoritative; client changes don't replicate |
| `WalkSpeed` (16) | stun = lower; set by server or by owning client (owner's physics) |
| `JumpPower` (50) / `JumpHeight` (7.2) / `UseJumpPower` | |
| `AutoRotate` | false to lock facing during attacks |
| `MoveDirection: Vector3` (ro) | world-space input direction (camera relative), magnitude 0..1 |
| `RootPart: BasePart?` (ro) | HumanoidRootPart |
| `RigType: Enum.HumanoidRigType` | `R6` / `R15` |
| `HipHeight`, `PlatformStand`, `Sit`, `Jump`, `FloorMaterial`, `SeatPart` | |
| `BreakJointsOnDeath`, `RequiresNeck`, `EvaluateStateMachine` | |
| `DisplayDistanceType`, `HealthDisplayType`, `NameDisplayDistance` | |
| `WalkToPoint`, `WalkToPart`, `AutoJumpEnabled` | |

Methods: `:TakeDamage(n)` (blocked by ForceField), `:Move(dir, relativeToCamera?)`, `:MoveTo(pos, part?)`, `:ChangeState(Enum.HumanoidStateType)`, `:GetState()`, `:SetStateEnabled(state, bool)`, `:GetStateEnabled(state)`, `:EquipTool(tool)`, `:UnequipTools()`, `:ApplyDescription(desc)`, `:GetAppliedDescription()`, `:GetLimb(part)`, `:GetMoveVelocity()`, `:BuildRigFromAttachments()`.
Events: `Died`, `HealthChanged(health)`, `StateChanged(old, new)`, `Running(speed)`, `Jumping(active)`, `FreeFalling`, `FallingDown`, `GettingUp`, `Ragdoll`, `Climbing`, `Swimming`, `Seated`, `PlatformStanding`, `MoveToFinished(reached)`, `Touched(part, limb)`.

## 5. Enum.HumanoidStateType

`FallingDown, Running, RunningNoPhysics, Climbing, StrafingNoPhysics, Ragdoll, GettingUp, Jumping, Landed, Flying, Freefall, Seated, PlatformStanding, Dead, Swimming, Physics, None`.
- State changes must happen on the **network owner** of the character (the player's client) to take effect reliably. Server `ChangeState` on a player character is often overridden.
- Ragdoll/knockdown: `humanoid:ChangeState(Enum.HumanoidStateType.Physics)` or `Ragdoll` on the client + disable `GettingUp` temporarily with `SetStateEnabled`.
- Prevent jumping while stunned: `humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)` (client) or `JumpPower = 0`/`JumpHeight = 0`.

## 6. Damage

```luau
-- server only
local function ApplyDamage(humanoid: Humanoid, amount: number)
	if humanoid.Health <= 0 then return end
	humanoid.Health = math.max(0, humanoid.Health - amount)   -- ignores ForceField
	-- or humanoid:TakeDamage(amount)                         -- respects ForceField
end
```
Track "last attacker" for kill credit: `humanoid:SetAttribute("LastAttacker", player.UserId)`.

## 7. Movement control during combat

| Effect | How |
|---|---|
| Slow while attacking/blocking | `WalkSpeed` multiplier via a stacking modifier table, recompute `WalkSpeed = base * product(mods)` |
| Root/face lock during swing | `AutoRotate = false`, set root CFrame to face target/camera |
| Stun | WalkSpeed 0, JumpPower 0, cancel actions, play stun anim |
| Knockback | physics impulse (see roblox.physics.movers-knockback) |

Modifier stack avoids "who restores WalkSpeed" bugs:
```luau
local Mods: {[string]: number} = {}
local function Recompute(h: Humanoid)
	local m = 1 ; for _, v in Mods do m *= v end
	h.WalkSpeed = 16 * m
end
Mods.Blocking = 0.5 ; Recompute(h) ; Mods.Blocking = nil ; Recompute(h)
```
Because the owning client simulates its character, setting WalkSpeed **on the client** is instant; server-set WalkSpeed replicates with latency but is authoritative against exploiters only if you also validate positions.

## 8. Rig parts

R15: `Head, UpperTorso, LowerTorso, LeftUpperArm, LeftLowerArm, LeftHand, RightUpperArm, RightLowerArm, RightHand, LeftUpperLeg, LeftLowerLeg, LeftFoot, RightUpperLeg, RightLowerLeg, RightFoot, HumanoidRootPart`.
R6: `Head, Torso, Left Arm, Right Arm, Left Leg, Right Leg, HumanoidRootPart`.
Use `HumanoidRootPart` for position/facing (`root.CFrame.LookVector`). `character:GetPivot()` / `:PivotTo(cf)` move whole model.

## 9. NPC dummies for testing

Insert a rig (Avatar tab -> Rig Builder), keep it in workspace with a server Script; identical Humanoid API. `Players:GetPlayerFromCharacter(dummy) == nil` - your combat code should accept any `Model` with a Humanoid as a combatant.
