---
name: roblox.datatypes.cframe-vector-math
description: Roblox math datatypes - Vector3, Vector2, CFrame (constructors, properties, methods, object/world space conversion), Color3, UDim/UDim2, NumberRange, NumberSequence/ColorSequence, TweenInfo, Random, DateTime, Enum objects (EnumItem Name/Value/EnumType, GetEnumItems, FromName/FromValue), plus combat geometry (direction classification, facing, relative offsets, angle between). Use for any spatial math or enum handling.
---

# Roblox — Datatypes & Math

## 1. Vector3

Constructors: `Vector3.new(x, y, z)`, `Vector3.zero`, `Vector3.one`, `Vector3.xAxis`, `Vector3.yAxis`, `Vector3.zAxis`, `Vector3.FromNormalId(Enum.NormalId.Front)`, `Vector3.FromAxis(Enum.Axis.Y)`.
Properties: `X, Y, Z, Magnitude, Unit` (Unit of zero vector = NaN!).
Methods: `:Dot(v)`, `:Cross(v)`, `:Lerp(v, alpha)`, `:FuzzyEq(v, eps?)`, `:Abs()`, `:Ceil()`, `:Floor()`, `:Sign()`, `:Max(...)`, `:Min(...)`, `:Angle(v, axis?)` (radians, signed with axis).
Operators: `+ - * /` with Vector3 or number, unary `-`, `//`, `==`.

Flatten: `v * Vector3.new(1, 0, 1)`. Safe unit:
```luau
local function SafeUnit(v: Vector3): Vector3 return if v.Magnitude > 1e-6 then v.Unit else Vector3.zero end
```

## 2. Vector2

`Vector2.new(x, y)`, `.zero`, `.one`, `.xAxis`, `.yAxis`; `X, Y, Magnitude, Unit`; `:Dot`, `:Cross` (scalar), `:Lerp`, `:Angle(v, isSigned?)`, `:Abs/Ceil/Floor/Sign/Max/Min`, `:FuzzyEq`.

## 3. CFrame (position + rotation)

Constructors:
| Constructor | Notes |
|---|---|
| `CFrame.new(x, y, z)` / `CFrame.new(pos: Vector3)` | |
| `CFrame.new(pos, lookAt)` | legacy; prefer `lookAt` |
| `CFrame.lookAt(pos, target, up?)` | face a point |
| `CFrame.lookAlong(pos, direction, up?)` | face a direction |
| `CFrame.fromEulerAnglesXYZ(rx, ry, rz)` / `CFrame.Angles(rx, ry, rz)` | radians |
| `CFrame.fromEulerAnglesYXZ(...)` / `CFrame.fromOrientation(...)` | |
| `CFrame.fromAxisAngle(axis, angle)` | |
| `CFrame.fromMatrix(pos, vX, vY, vZ?)` | |
| `CFrame.identity` | |

Properties: `Position`, `Rotation` (CFrame without translation), `X, Y, Z`, `LookVector` (-Z, forward), `RightVector` (+X), `UpVector` (+Y), `XVector, YVector, ZVector`.

Methods:
| Method | Use |
|---|---|
| `a * b` | apply b in a's space (offset): `root.CFrame * CFrame.new(0, 0, -3)` = 3 studs in front |
| `cf * v3` | point to world |
| `cf:Inverse()` | |
| `cf:Lerp(goal, alpha)` | |
| `cf:ToWorldSpace(cf2)` / `:ToObjectSpace(cf2)` | relative CFrames |
| `cf:PointToWorldSpace(v)` / `:PointToObjectSpace(v)` | points |
| `cf:VectorToWorldSpace(v)` / `:VectorToObjectSpace(v)` | directions (no translation) |
| `cf:ToEulerAnglesXYZ()` / `:ToEulerAnglesYXZ()` / `:ToOrientation()` / `:ToAxisAngle()` | |
| `cf:GetComponents()` | 12 numbers |
| `cf:Orthonormalize()` | fix drift |
| `cf:FuzzyEq(cf2, eps?)` | |

## 4. Combat geometry

```luau
-- Angle between facing and target (degrees)
local function AngleTo(root: BasePart, target: Vector3): number
	local to = (target - root.Position) * Vector3.new(1, 0, 1)
	if to.Magnitude < 1e-6 then return 0 end
	return math.deg(math.acos(math.clamp(root.CFrame.LookVector:Dot(to.Unit), -1, 1)))
end

-- Classify a world direction relative to a CFrame into 4 sides
local function Classify(cf: CFrame, worldDir: Vector3): "Front" | "Back" | "Left" | "Right"
	local l = cf:VectorToObjectSpace(worldDir)
	if math.abs(l.X) > math.abs(l.Z) then return if l.X > 0 then "Right" else "Left" end
	return if l.Z < 0 then "Front" else "Back"
end

-- Local direction vectors
local DirVector = table.freeze({
	Front = Vector3.new(0, 0, -1), Back = Vector3.new(0, 0, 1),
	Left = Vector3.new(-1, 0, 0), Right = Vector3.new(1, 0, 0),
})

-- Face target instantly (yaw only)
local function FaceYaw(root: BasePart, target: Vector3)
	local p = root.Position
	root.CFrame = CFrame.lookAt(p, Vector3.new(target.X, p.Y, target.Z))
end
```

Mirror rule for directional attacks: an attacker swinging **from their Right** hits the defender's **Left** side when facing each other. Define it once in the resolver:
```luau
local Mirror = { Left = "Right", Right = "Left", Front = "Front", Back = "Back" }
```

## 5. Other datatypes

| Type | Constructor / members |
|---|---|
| `Color3` | `Color3.new(r,g,b)` 0..1, `Color3.fromRGB(0..255)`, `fromHSV`, `fromHex("#ff0000")`, `:Lerp`, `:ToHSV()`, `:ToHex()` |
| `BrickColor` | `BrickColor.new("Bright red")`, `.Color` |
| `UDim` / `UDim2` | `UDim2.new(sx, ox, sy, oy)`, `UDim2.fromScale`, `UDim2.fromOffset`, `:Lerp` |
| `NumberRange` | `NumberRange.new(min, max?)` `.Min .Max` |
| `NumberSequence` | `NumberSequence.new(n)` / `(n0, n1)` / `({NumberSequenceKeypoint.new(t, v, env?)})` |
| `ColorSequence` | `ColorSequence.new(c)` / `({ColorSequenceKeypoint.new(t, c)})` |
| `TweenInfo` | `TweenInfo.new(time, easingStyle?, easingDirection?, repeatCount?, reverses?, delayTime?)` |
| `Ray` | `Ray.new(origin, dir)` legacy; `:ClosestPoint(p)`, `:Distance(p)` |
| `Region3` | legacy |
| `Random` | `Random.new(seed?)`, `:NextNumber(min?, max?)`, `:NextInteger(min, max)`, `:NextUnitVector()`, `:Shuffle(t)`, `:Clone()` |
| `DateTime` | `DateTime.now()`, `.fromUnixTimestamp(s)`, `.fromUnixTimestampMillis(ms)`, `.fromUniversalTime(y,m,d,...)`, `.UnixTimestamp`, `.UnixTimestampMillis`, `:ToIsoDate()`, `:FormatUniversalTime(fmt, locale)` |
| `Content` | newer typed asset reference (`Content.fromUri("rbxassetid://...")`) - verify per property |
| `Font` | `Font.new(family, weight?, style?)`, `Font.fromEnum(Enum.Font.X)` |

## 6. Enums

```luau
local item: EnumItem = Enum.KeyCode.F
item.Name        -- "F"
item.Value       -- number
item.EnumType    -- Enum.KeyCode  (the Enum object)
item:IsA("KeyCode")  -- true (EnumItem:IsA checks enum type name)

Enum.KeyCode:GetEnumItems()           -- {EnumItem}
Enum.KeyCode:FromName("F")            -- EnumItem? (newer API; or Enum.KeyCode["F"] which errors if missing)
Enum.KeyCode:FromValue(70)            -- EnumItem?

typeof(Enum.KeyCode.F) == "EnumItem" ; typeof(Enum.KeyCode) == "Enum"
```
Type annotations: `local k: Enum.KeyCode` (an item of KeyCode), `local e: Enum` (an enum object), union `Enum.KeyCode | Enum.UserInputType`.

Custom enums (Luau has none built-in):
```luau
local Direction = table.freeze({ Neutral = 0, Front = 1, Back = 2, Left = 3, Right = 4 })
local DirectionName = table.freeze({ [0] = "Neutral", "Front", "Back", "Left", "Right" })
export type Direction = "Neutral" | "Front" | "Back" | "Left" | "Right"
```
Numeric values -> cheap Packet `NumberU8`; names for readability and saving.
