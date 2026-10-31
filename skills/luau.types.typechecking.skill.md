---
name: luau.types.typechecking
description: Luau type system - modes (strict/nonstrict/nocheck), annotations, primitive/table/function types, unions, intersections, optionals, singleton (literal) types, generics and generic packs, typeof, export type, casts (::), refinements, type functions (keyof, index, rawget, user-defined), read/write properties, and typing OOP classes with metatables. Use when writing typed modules, schemas and class interfaces.
---

# Luau — Type System

Gradual, structural types. Types are erased at runtime (no runtime cost / no runtime checks).

## 1. Modes (first line of file)

| Directive | Meaning |
|---|---|
| `--!nocheck` | no type errors |
| `--!nonstrict` | default; unknown = `any` |
| `--!strict` | full inference; recommended for shared modules |

## 2. Annotation syntax

```luau
local n: number = 1
local s: string? = nil                    -- optional = string | nil
local f: (number, string) -> boolean
local g: (...number) -> ...string         -- variadic
local h: () -> ()                         -- no args / no return
local function Add(a: number, b: number): number return a + b end
local function Many(): (number, string) return 1, "a" end
```

Builtin type names: `any`, `unknown` (must refine before use), `never`, `nil`, `boolean`, `number`, `string`, `thread`, `buffer`, `vector`, `{}` (table), `(...any) -> ...any`, plus all Roblox classes/datatypes (`Instance`, `Model`, `Humanoid`, `Vector3`, `CFrame`, `Enum.KeyCode` (EnumItem of that enum), `Enum` (enum object), `EnumItem`, `RBXScriptSignal`, `RBXScriptConnection`).

## 3. Table types

```luau
type Array = { number }                   -- array
type Map = { [string]: number }           -- indexer
type Damage = {
	Amount: number,
	Type: "Physical" | "Magical" | "True",  -- singleton string union (enum-like)
	Crit: boolean?,                         -- optional field
}
type Mixed = { [string]: any, Name: string }  -- props + indexer
type Fn = { Callback: (self: Fn, number) -> () }
```
Separators `,` or `;` both work.

Read/write-only properties (new solver):
```luau
type ReadOnlyStats = { read Damage: number, read Range: number }
type WriteOnly = { write Out: number }
```

## 4. Unions, intersections, singletons

```luau
type Input = Enum.KeyCode | Enum.UserInputType          -- union
type Direction = "Front" | "Back" | "Left" | "Right"    -- singletons
type Flag = true                                         -- boolean singleton
type Named = { Name: string } & { Id: number }           -- intersection (both)
type Callback = ((number) -> ()) & ((string) -> ())      -- overloaded function
```

## 5. Refinements (narrowing)

```luau
local function Use(v: number | string | nil)
	if v == nil then return end
	if type(v) == "number" then v += 1 else v = v:upper() end
end
-- typeof() for Roblox types; :IsA() refines Instances
if typeof(x) == "Instance" and x:IsA("BasePart") then x.Anchored = true end
-- singleton refine
if dir == "Front" then ... end
-- assert refines
assert(humanoid, "no humanoid")
```
Refinements work with `type`, `typeof`, `==`/`~=` nil or literals, truthiness, `IsA`, and `and/or/not`.

## 6. Casting

```luau
local hum = char:FindFirstChild("Humanoid") :: Humanoid   -- assert type (no runtime check)
local anyv = value :: any                                 -- escape hatch
local t = {} :: { [string]: number }                      -- type an empty table
```
Cast must be to a related type (go through `any` for unrelated: `x :: any :: Foo`).

## 7. Generics

```luau
local function First<T>(list: { T }): T? return list[1] end
type Pair<A, B> = { First: A, Second: B }
type Signal<T...> = { Fire: (self: Signal<T...>, T...) -> () }     -- generic type pack
type Callback<T... = ()> = (T...) -> ()                             -- default pack
local function Map<T, U>(list: { T }, fn: (T) -> U): { U }
	local out = table.create(#list)
	for i, v in list do out[i] = fn(v) end
	return out
end
```
Generics are normally inferred from arguments; to pin them, annotate the receiving variable or cast the argument.

## 8. typeof / export / import

```luau
local Template = { Cash = 0, Items = {} :: { string } }
export type Template = typeof(Template)           -- derive type from a value
export type WeaponSchema = { Id: string }         -- export from a ModuleScript

-- consumer
local Weapon = require(path.Weapon)
type WeaponSchema = Weapon.WeaponSchema           -- access exported types via the required local
```
Only `export type` aliases are visible through `require`. Types can't be required alone (you must require the module value).

## 9. Type functions (built-in)

| Function | Result |
|---|---|
| `keyof<T>` | union of string-literal keys of `T` |
| `rawkeyof<T>` | same, ignoring `__index` |
| `index<T, K>` | type of property `K` on `T` (e.g. `index<Damage, "Type">`) |
| `rawget<T, K>` | property type ignoring metatables |
| `typeof(expr)` | type of expression |
| `getmetatable<T>` / `setmetatable<T, M>` | metatable types (new solver) |

```luau
type Stats = { Damage: number, Range: number }
type StatName = keyof<Stats>          -- "Damage" | "Range"
type DamageT  = index<Stats, "Damage"> -- number
```

User-defined type functions (new type solver):
```luau
type function Partial(t)
	-- runs at analysis time; `t` is a `type` object
	local out = types.newtable()
	for k, v in t:properties() do out:setproperty(k, types.optional(v.read)) end
	return out
end
type MaybeStats = Partial<Stats>
```
(Available with the new type solver; API: `types.*`, `type:properties()`, `:setproperty()`, `types.optional`, `types.unionof`, `types.singleton`...)

## 10. Typing OOP classes (metatable pattern)

```luau
--!strict
local Weapon = {}
Weapon.__index = Weapon

type WeaponData = {
	Id: string,
	Damage: number,
	States: { [string]: any },
}
export type Weapon = setmetatable<WeaponData, typeof(Weapon)>  -- new solver
-- Old-solver friendly alternative:
-- export type Weapon = typeof(setmetatable({} :: WeaponData, Weapon))

function Weapon.new(id: string, damage: number): Weapon
	local self = setmetatable({ Id = id, Damage = damage, States = {} }, Weapon)
	return self
end

function Weapon.GetDamage(self: Weapon, mult: number): number   -- explicit self type
	return self.Damage * mult
end
```

Interface-style (separate public shape):
```luau
export type StateClass = {
	Name: string,
	IsActive: boolean,
	SetActive: (self: StateClass, active: boolean) -> (),
}
```

## 11. Enum-like types pattern for combat

```luau
export type Direction = "Neutral" | "Front" | "Back" | "Left" | "Right"
export type ActionKind = "M1" | "Directional" | "Block" | "Parry" | "Dodge"
export type DamageType = "Physical" | "Magical" | "True"
export type Outcome = "Hit" | "Blocked" | "Parried" | "Dodged" | "PerfectDodge" | "Clash" | "GuardBreak"

-- runtime mirror (frozen) for iteration / network ids
local Direction = table.freeze({ Neutral = 0, Front = 1, Back = 2, Left = 3, Right = 4 })
```

## 12. Common errors & fixes

| Message | Fix |
|---|---|
| `Type 'X' could not be converted into 'Y'` | wrong shape; check optional fields |
| `Key 'Foo' not found in table` | add to type or use indexer |
| `Unknown global 'x'` | missing `local` / typo |
| `Type 'Instance' does not have key 'Humanoid'` | use `FindFirstChildOfClass("Humanoid")` or cast |
| Recursive type issues | define `type T = { Next: T? }` is fine; avoid generic recursion with different params |

Notes
- Strict mode infers table literal shapes ("sealed" tables); adding fields later errors - declare all fields in the constructor or annotate.
- `any` spreads silently; prefer `unknown` at trust boundaries (network input) and refine.
