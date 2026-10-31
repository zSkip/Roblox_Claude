---
name: luau.testing.unit-tests
description: Unit testing for Luau/Roblox - what unit tests are and why pure modules (resolver, stat math, combo logic) should be tested, a zero-dependency in-Studio test runner, TestEZ and Jest Lua syntax, running pure tests outside Studio with Lune, and example test matrices for the combat resolver and status effects. Use when adding tests or making modules testable.
---

# Unit Tests in Luau

## 1. What & why

A **unit test** calls one function with known inputs and asserts the output. It runs in milliseconds and needs no players or server.
For this project the high-value targets are the **pure** modules in `ReplicatedStorage/Combat`:
- `Resolver.Resolve(...)` → every attack × defense × direction combination (Hit, Blocked, Parried, Dodged, PerfectDodge, GuardBreak).
- Stat math: armor formula, tenacity, slow rule, modifier stacking.
- Combo logic: index wraps 1→4, resets after `ResetTime`, finisher flags knockback.
- Direction mapping: input → limb, mirrored parry key rule.

Tests let you change balance or refactor and know instantly if parry/dodge logic broke. Design consequence: keep the logic **free of Instances and clocks** (pass `now`, CFrames and states in as arguments).

## 2. Zero-dependency runner (Studio)

```luau
-- ServerScriptService/Tests/RunTests (Script, disable before publishing or gate with RunService:IsStudio())
local Results = { Passed = 0, Failed = 0 }

local function Test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then Results.Passed += 1 else Results.Failed += 1 ; warn(`FAIL {name}: {err}`) end
end

local function Eq(actual, expected, msg: string?)
	if actual ~= expected then error(`{msg or ""} expected {tostring(expected)}, got {tostring(actual)}`, 2) end
end

for _, module in script.Parent:GetChildren() do
	if module:IsA("ModuleScript") and module.Name:match("%.spec$") then
		require(module)(Test, Eq)
	end
end
print(`Tests: {Results.Passed} passed, {Results.Failed} failed`)
```

```luau
-- Tests/Resolver.spec (ModuleScript)
local Resolver = require(game.ReplicatedStorage.Combat.Resolver)
return function(Test, Eq)
	local front = CFrame.new(0, 0, 0)
	local facing = CFrame.lookAt(Vector3.new(0, 0, -5), Vector3.zero)

	Test("idle defender gets hit", function()
		Eq(Resolver.Resolve({ Kind = "M1" }, nil, front, facing, { State = "Idle" }, 0), "Hit")
	end)
	Test("knockback attack is blocked, not guard broken", function()
		local out = Resolver.Resolve({ Kind = "M1", Knockback = {} }, "Back", front, facing, { State = "Blocking", Posture = 100 }, 0)
		Eq(out, "Blocked")
	end)
	Test("wrong-direction parry is punished", function()
		Eq(Resolver.Resolve({ Kind = "Directional" }, "Right", front, facing, { State = "Parrying", ParryDir = "Right", ParryStart = 0 }, 0.05), "Hit")
	end)
end
```

## 3. TestEZ (Roblox's classic BDD framework)

```luau
return function()
	describe("Resolver", function()
		it("hits idle defenders", function()
			expect(Resolver.Resolve(...)).to.equal("Hit")
		end)
	end)
end
```
`expect(x).to.equal(y)`, `.to.be.ok()`, `.never.to.equal()`, `.to.throw()`, `beforeEach`, `afterAll`. Run with `TestEZ.TestBootstrap:run({ folder })`.

## 4. Jest Lua (Roblox's current framework)

```luau
local JestGlobals = require(Packages.Dev.JestGlobals)
local describe, it, expect = JestGlobals.describe, JestGlobals.it, JestGlobals.expect
describe("Combo", function()
	it("wraps after four", function()
		expect(NextIndex(4)).toBe(1)
	end)
end)
```
Installed through Wally/rotriever; run in Studio or with `run-in-roblox`.

## 5. Outside Studio (Lune)

Pure modules that use only Luau and simple datatypes can be tested with **Lune** (a standalone Luau runtime): `lune run tests/resolver.luau`. Roblox datatypes (CFrame, Vector3) need Lune's `@lune/roblox` library. Handy for CI on GitHub Actions.

## 6. Matrix testing

```luau
local Cases = {
	-- attack,        dir,     defenderState,                        expected
	{ "M1",          nil,     { State = "Idle" },                      "Hit" },
	{ "M1",          nil,     { State = "Blocking", Posture = 50 },    "Blocked" },
	{ "Directional", "Left",  { State = "Parrying", ParryDir = "Right" }, "Parried" },  -- mirrored rule
	{ "Directional", "Left",  { State = "Dodging", DodgeDir = "Left" },   "PerfectDodge" },
}
for i, c in Cases do
	Test(`case {i}`, function() Eq(Resolve(c[1], c[2], c[3]), c[4]) end)
end
```
Add a row whenever a bug is found so it can't come back.
