---
name: roblox.spatial.raycast-overlap-hitbox
description: Roblox spatial queries for hit detection - WorldRoot Raycast/Blockcast/Spherecast/Shapecast, GetPartBoundsInBox/InRadius/GetPartsInPart, RaycastParams/OverlapParams/RaycastResult, Enum.RaycastFilterType, CanQuery/CanTouch, collision groups, Touched pitfalls, and hitbox recipes (box in front of root, swept casts, per-swing dedupe, directional side of hit, server validation with ping leniency). Use when building hitboxes or line-of-sight checks.
---

# Roblox — Spatial Queries & Hitboxes

All methods are on `WorldRoot` (`workspace`, or a `WorldModel`).

## 1. Ray / shape casts (first hit along a direction)

| Method | Returns |
|---|---|
| `workspace:Raycast(origin: Vector3, direction: Vector3, params: RaycastParams?)` | `RaycastResult?` - direction length = max distance |
| `workspace:Blockcast(cframe: CFrame, size: Vector3, direction: Vector3, params?)` | swept box |
| `workspace:Spherecast(position: Vector3, radius: number, direction: Vector3, params?)` | swept sphere |
| `workspace:Shapecast(part: BasePart, direction: Vector3, params?)` | swept arbitrary part |

Shape casts ignore parts they **start** overlapping - combine with an overlap query for point-blank hits.

`RaycastResult`: `Instance: BasePart`, `Position: Vector3`, `Normal: Vector3`, `Material: Enum.Material`, `Distance: number`.

## 2. Overlap queries (everything inside a volume)

| Method | Notes |
|---|---|
| `workspace:GetPartBoundsInBox(cframe, size, overlapParams?) -> {BasePart}` | uses parts' AABBs (bounding boxes) - fast, slightly generous |
| `workspace:GetPartBoundsInRadius(position, radius, overlapParams?)` | AABB vs sphere |
| `workspace:GetPartsInPart(part, overlapParams?)` | exact geometry vs a real part; slower than the bounds queries |
| `workspace:ArePartsTouchingOthers(parts, overlapIgnored?)` | |

Only parts with `CanQuery = true` are returned. `CanQuery` can only be turned off when `CanCollide` is false. For hurtboxes use `CanCollide = false, CanQuery = true, CanTouch = false`.

## 3. Params

```luau
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude        -- or Include
params.FilterDescendantsInstances = { attackerCharacter }
params.IgnoreWater = true
params.CollisionGroup = "Hitbox"                          -- respects collision group rules
params.RespectCanCollide = false
params:AddToFilter(instOrList)

local op = OverlapParams.new()
op.FilterType = Enum.RaycastFilterType.Include
op.FilterDescendantsInstances = CharactersFolder:GetChildren()  -- only characters
op.MaxParts = 0                                           -- 0 = unlimited
op.CollisionGroup = "Default"
op.RespectCanCollide = false
op.BruteForceAllSlow = false
op:AddToFilter(x)
```
`Enum.RaycastFilterType`: `Exclude`, `Include` (`Blacklist`/`Whitelist` are deprecated names).
Setting `FilterDescendantsInstances` copies the list - reassign when the set changes; reuse the params object across queries.

## 4. Collision groups (PhysicsService)

```luau
local PhysicsService = game:GetService("PhysicsService")
PhysicsService:RegisterCollisionGroup("Characters")
PhysicsService:RegisterCollisionGroup("Hitbox")
PhysicsService:CollisionGroupSetCollidable("Hitbox", "Default", false)
part.CollisionGroup = "Characters"
```
Also: `UnregisterCollisionGroup`, `RenameCollisionGroup`, `IsCollisionGroupRegistered`, `CollisionGroupsAreCollidable`, `GetRegisteredCollisionGroups`, `GetMaxCollisionGroups`.

## 5. Touched - why not for melee

`BasePart.Touched/TouchEnded` fire on physics contact (needs `CanTouch`), are network-owner dependent, miss fast swings and fire many times. Use queries on a timeline instead.

## 6. Hitbox recipes

### Box in front of the attacker
```luau
local function QueryBox(attacker: Model, root: BasePart, size: Vector3, offset: CFrame, op: OverlapParams)
	local cf = root.CFrame * offset                      -- e.g. CFrame.new(0, 0, -size.Z/2 - 1)
	local parts = workspace:GetPartBoundsInBox(cf, size, op)
	local hits: {[Model]: Humanoid} = {}
	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and model ~= attacker and not hits[model] then
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 then hits[model] = hum end
		end
	end
	return hits
end
```

### Active window with per-swing dedupe
```luau
local function RunHitWindow(duration: number, step: () -> {[Model]: Humanoid}, onHit: (Model, Humanoid) -> ())
	local already: {[Model]: true} = {}
	local t0 = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if os.clock() - t0 > duration then conn:Disconnect() return end
		for model, hum in step() do
			if not already[model] then already[model] = true ; onHit(model, hum) end
		end
	end)
	return conn
end
```

### Swept cast between frames (fast blades)
Track blade tip `Attachment.WorldPosition` each frame; `Raycast(lastPos, newPos - lastPos)` per tip point (classic "raycast hitbox"), or `Blockcast` the blade box from last CFrame to current.

### Which side was hit (directional)
```luau
-- direction from defender to attacker, in defender's local space
local function HitSide(defenderRoot: BasePart, attackerPos: Vector3): "Front" | "Back" | "Left" | "Right"
	local rel = defenderRoot.CFrame:PointToObjectSpace(attackerPos)
	if math.abs(rel.X) > math.abs(rel.Z) then
		return if rel.X > 0 then "Right" else "Left"
	end
	return if rel.Z < 0 then "Front" else "Back"           -- -Z is forward
end
```

### Facing / cone check
```luau
local function InFront(root: BasePart, targetPos: Vector3, minDot: number) -- minDot 0.3 ~ 72deg half-angle
	local to = (targetPos - root.Position) * Vector3.new(1, 0, 1)
	if to.Magnitude < 1e-3 then return true end
	return root.CFrame.LookVector:Dot(to.Unit) >= minDot
end
```

### Line of sight
`workspace:Raycast(attackerHead.Position, targetPos - attackerHead.Position, paramsExcludingBoth)` == nil -> visible.

## 7. Server validation of client-reported hits

If the client detects hits (snappier), the server must sanity-check:
1. Attacker is in an attack state whose hit window covers `now` (± ping leniency).
2. Distance: `(attackerRoot.Position - targetRoot.Position).Magnitude <= range + leniency` where `leniency ≈ targetSpeed * ping + 2..4 studs`.
3. Facing/cone check passes.
4. Target not already hit this swing; target alive; not same team.
5. Rate: no more hits than the schema allows per swing.

If the server detects hits (authoritative): the attacker sees hits that "should" have landed miss on high ping. Common compromise: server hitbox slightly larger than the client's visual, plus client-side prediction of hit FX that the server can override.

Lag compensation (advanced): keep a ring buffer of each character's root CFrame per server frame (`[t] = cf`), and evaluate the hitbox against positions at `serverNow - attackerPing`.

## 8. Useful geometry

`BasePart.Size`, `CFrame`, `Position`, `AssemblyRootPart`, `Model:GetBoundingBox() -> (CFrame, Vector3)`, `Model:GetExtentsSize()`, `BasePart:GetClosestPointOnSurface(pos)`, `CFrame:PointToObjectSpace(v)`, `CFrame:VectorToWorldSpace(v)`.
Visual debug: spawn a transparent red `Part` (Anchored, CanCollide/CanQuery/CanTouch false) at the hitbox CFrame for 0.1s; gate behind a `DebugHitboxes` flag.
