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

## 2. TestKit (this repo: `src/ReplicatedStorage/TestKit.luau`)

Zero dependencies, about 150 lines. Specs are ModuleScripts named `*.spec`. `src/ServerScriptService/Tests/RunTests.server.luau` runs every spec under its folder when you press **Play in Studio** and does nothing in live servers. Results go to Output.

```luau
-- ServerScriptService/Tests/Directions.spec  (ModuleScript)
local Directions = require(game.ReplicatedStorage.Combat.Directions)

return function(Describe, It, Expect)
	Describe("Matches", function()
		It("Mirrored: parry the side the attack comes from", function()
			Expect(Directions.Matches("Mirrored", "Right", "Left", "Left")).ToBe(true)
		end)
		It("rejects a missing direction", function()
			Expect(Directions.Matches("Mirrored", "Right", "Left", nil)).Never.ToBe(true)
		end)
	end)
end
```
Matchers: `ToBe`, `ToEqual` (deep), `ToBeNear(n, eps?)`, `ToBeTruthy`, `ToBeFalsy`, `ToBeNil`, `ToThrow(pattern?)`, and `.Never.` to invert.
API: `TestKit.Run({ModuleScript})`, `TestKit.RunIn(root)`, `TestKit.Report(results)`. A spec that fails to load counts as a failure and doesn't stop the others.

Without Rojo: create the ModuleScripts by hand with the same names (`TestKit` in ReplicatedStorage, the `Tests` folder in ServerScriptService, `RunTests` as a Script).

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
-- inside a spec's returned function(Describe, It, Expect):
for i, c in Cases do
	It(`case {i}: {c[1]} vs {c[3].State}`, function() Expect(Resolve(c[1], c[2], c[3])).ToBe(c[4]) end)
end
```
Add a row whenever a bug is found so it can't come back.
