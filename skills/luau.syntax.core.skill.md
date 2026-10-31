---
name: luau.syntax.core
description: Core Luau syntax and semantics (luau.org) - values/types at runtime, variables/scope, operators incl. compound assignment and floor division, if-then-else expressions, string interpolation, generalized iteration, continue, varargs, functions/closures/upvalues, error handling (pcall/xpcall/error), and Luau-vs-Lua 5.1 differences. Use when writing or reviewing any Luau code.
---

# Luau — Core Syntax & Semantics

Luau = Lua 5.1 derivative with gradual typing, performance work and syntax extensions. Docs: `https://luau.org`.

## 1. Runtime value types (`type(v)`)

`nil`, `boolean`, `number` (double), `string` (immutable byte string), `table`, `function`, `thread` (coroutine), `userdata` (engine objects), `buffer` (fixed-size mutable bytes), `vector` (native 3-wide float; Roblox `Vector3` is a vector at runtime).
On Roblox use **`typeof(v)`** to get engine names: `"Instance"`, `"Vector3"`, `"CFrame"`, `"EnumItem"`, `"RBXScriptSignal"`...

Truthiness: only `nil` and `false` are falsy (`0` and `""` are truthy).

## 2. Variables & scope

```luau
local x = 1                -- always prefer local (faster, scoped)
local a, b, c = 1, 2       -- c = nil
local function f() end     -- local function can recurse
x = 2                      -- reassign
Global = 3                 -- global (avoid; strict mode warns)
do local scoped = true end -- block scope
```
`local` limit: 200 per function. Shadowing allowed (linter warns).

Attributes on locals: `local x <const> = 5` is **not** Luau (Lua 5.4) - Luau has no `<const>`/`<close>`; use `table.freeze` for constant tables.

## 3. Operators

| Category | Operators |
|---|---|
| Arithmetic | `+ - * / // % ^` and unary `-` (`//` = floor division) |
| Compound | `+= -= *= /= //= %= ^= ..=` (evaluate lhs once; statements, not expressions) |
| Comparison | `== ~= < > <= >=` |
| Logical | `and or not` (short-circuit, return operands) |
| Concatenation | `..` |
| Length | `#t` (array border), `#s` (bytes) |

Precedence (high->low): `^` > `not # -` (unary) > `* / // %` > `+ -` > `..` > comparisons > `and` > `or`. `^` and `..` are right-associative.

Ternary-like:
```luau
local v = if cond then a elseif cond2 then b else c   -- if-expression (always needs else)
local w = cond and a or b                             -- breaks if a is false/nil
```

## 4. Strings

```luau
local s = "double" .. 'single' .. [[long
bracket]] .. [==[ nested ]] ok ]==]
local name, hp = "Goop", 90
print(`{name} has {hp}/{100} hp`)           -- interpolation; any expression in {}
print(`escape braces: \{literal\}`)
local esc = "\n \t \\ \" \x41 \u{1F600} \z
             continues"                       -- \z skips following whitespace
```
Methods via `:`: `s:upper()`, `s:sub(1, 3)`, `("x"):rep(3)`. Strings are 1-indexed; negative indices count from end.

## 5. Control flow

```luau
if a then ... elseif b then ... else ... end

while cond do ... end
repeat ... until cond              -- body locals visible in `until`

for i = 1, 10 do end               -- numeric (start, stop, step)
for i = 10, 1, -1 do end

for k, v in t do end               -- generalized iteration (Luau): arrays in order then hash part
for i, v in ipairs(t) do end       -- array part, stops at first nil
for k, v in pairs(t) do end        -- all keys, unordered
for k, v in next, t do end

for _, v in t do
	if not v then continue end     -- `continue` (Luau) - soft keyword
	if v == "stop" then break end
end
```
- Generalized iteration also respects `__iter` metamethod.
- Don't add new keys to a table while iterating it with `pairs`/generalized iteration (assigning existing keys or nil is fine).
- `goto` does not exist.

## 6. Functions

```luau
local function add(a: number, b: number): number return a + b end
local mul = function(a, b) return a * b end

local function multi() return 1, 2, 3 end
local x, y = multi()            -- 1, 2
local t = { multi() }           -- {1,2,3} - only expands as LAST element
local t2 = { multi(), 10 }      -- {1, 10}
print((multi()))                -- parentheses truncate to 1 value

local function va(...)
	local n = select("#", ...)  -- count incl. nils
	local first = select(1, ...)
	local packed = table.pack(...)  -- {n = count, ...}
	return ...
end

-- method sugar
local obj = { v = 1 }
function obj:Get() return self.v end   -- == function obj.Get(self)
obj:Get()                              -- == obj.Get(obj)
```
Closures capture **upvalues** by reference:
```luau
local function Counter()
	local n = 0
	return function() n += 1 return n end
end
```

## 7. Tables

```luau
local arr = { "a", "b", "c" }             -- 1-indexed array
local dict = { Damage = 10, ["Type"] = "Physical", [Enum.KeyCode.W] = "Front" }
local mixed = { 1, 2, Key = true }        -- avoid for saved data
dict.Damage = nil                         -- delete
local len = #arr
arr[#arr + 1] = "d"                       -- append (or table.insert)
```
Keys can be any value except `nil`/NaN. Tables are references (`local b = a` aliases). Copy: `table.clone(t)` (shallow).

## 8. Errors

```luau
error("message")              -- level 1: prefixes position
error("message", 2)           -- blame caller
error({ code = 5 })           -- any value
assert(cond, "msg")           -- returns its args if truthy

local ok, result = pcall(fn, arg1, arg2)
local ok2, res2 = xpcall(fn, function(err) return debug.traceback(err, 2) end, arg1)
```
- Yielding inside `pcall`/`xpcall` is supported in Luau (no "attempt to yield across C-call boundary" for pcall).
- `error` in a `task.spawn`ed thread prints but doesn't propagate.

## 9. Comments & directives

```luau
-- line comment
--[[ block ]]   --[==[ block with = ]==]
--!strict        -- type-check mode: --!nocheck | --!nonstrict | --!strict (first lines of file)
--!native        -- compile whole script with native codegen (Roblox server/Studio)
--!optimize 2    -- optimization level 0..2
--!nolint        -- or --!nolint LintName
```

## 10. Differences from Lua 5.1 worth remembering

- Added: `continue`, compound assignment, `//`, if-expressions, string interpolation, generalized iteration, type annotations, `buffer`, `vector`, integer-safe `math` helpers, `table.create/find/clear/clone/freeze/isfrozen/move`, `string.split`, `bit32`, `utf8`, `coroutine.close`, `coroutine.isyieldable`.
- Removed/sandboxed: `loadstring` (disabled by default on Roblox), `setfenv`/`getfenv` (deopts code - don't use), `io`, `os` mostly removed except `os.time`, `os.clock`, `os.date`, `os.difftime`, `package`/`require` replaced by Roblox `require(ModuleScript)` or path strings in new require-by-string.
- `__gc` metamethod not supported; `__mode` (weak tables) supported; `__len` respected on tables.
- Integer division and `%` follow floor semantics; `5 // 2 == 2`, `-5 // 2 == -3`.

## 11. Style conventions used in this project

```luau
local Module = {} ;                     -- semicolons optional; project style uses them
local Players = game:GetService("Players") ;  -- services as PascalCase locals
local MAX_COMBO = 4 ;                   -- constants UPPER_SNAKE
local function ResolveHit(Attacker, Defender) end  -- PascalCase functions in this codebase
```
