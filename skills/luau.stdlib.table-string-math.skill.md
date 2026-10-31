---
name: luau.stdlib.table-string-math
description: Luau standard library reference - global functions, table, string (incl. patterns), math, bit32, utf8, os, buffer, vector, coroutine, debug. Signatures plus game-dev notes (timing, lerp/clamp, packing data in buffers, frozen config tables). Use when you need a builtin function.
---

# Luau — Standard Library

## 1. Globals

| Function | Notes |
|---|---|
| `print(...)`, `warn(...)` (Roblox) | output |
| `error(msg, level?)`, `assert(v, msg?)` | |
| `pcall(f, ...)`, `xpcall(f, handler, ...)` | protected call |
| `type(v)`, `typeof(v)` (Roblox-aware) | |
| `tostring(v)`, `tonumber(s, base?)` | `tonumber("0x1F")`, `tonumber("101", 2)` |
| `select(i, ...)`, `select("#", ...)` | |
| `pairs(t)`, `ipairs(t)`, `next(t, k?)` | |
| `rawget(t,k)`, `rawset(t,k,v)`, `rawequal(a,b)`, `rawlen(t)` | bypass metamethods |
| `setmetatable(t, mt)`, `getmetatable(t)` | `__metatable` field locks |
| `unpack` = `table.unpack` | |
| `require(module)` | Roblox ModuleScript (cached per VM, returns same value) |
| `gcinfo()` | KB in use |
| `newproxy(addMt?)` | userdata with metatable |

Roblox globals: `game`, `workspace`, `script`, `plugin`, `shared`, `task`, `Enum`, `time()`, `elapsedTime()`, `tick()` (deprecated-ish, use `os.clock`/`workspace:GetServerTimeNow()`), `wait()`/`spawn()`/`delay()` (legacy - use `task.*`), `settings()`, `UserSettings()`.

## 2. table

| Function | Notes |
|---|---|
| `table.insert(t, v)` / `(t, pos, v)` | |
| `table.remove(t, pos?)` -> v | shifts; O(n) |
| `table.concat(t, sep?, i?, j?)` | strings/numbers only |
| `table.sort(t, comp?)` | unstable; `comp(a,b)` must be strict `<` |
| `table.pack(...)` -> `{n=…}` / `table.unpack(t, i?, j?)` | |
| `table.create(n, value?)` | preallocate array |
| `table.find(t, v, init?)` -> index? | linear search in array |
| `table.clear(t)` | empties, keeps capacity |
| `table.clone(t)` | shallow copy; the copy gets the same metatable; errors if the metatable is locked with `__metatable`; result is never frozen |
| `table.freeze(t)` / `table.isfrozen(t)` | shallow read-only; writes error |
| `table.move(a1, f, e, t, a2?)` | copy range |
| `table.maxn(t)` | largest numeric key |

Remove while iterating -> iterate backwards:
```luau
for i = #list, 1, -1 do if Expired(list[i]) then table.remove(list, i) end end
```
Swap-remove (O(1), order not preserved): `list[i] = list[#list]; list[#list] = nil`.

Deep copy:
```luau
local function DeepCopy<T>(t: T): T
	if type(t) ~= "table" then return t end
	local c = {}
	for k, v in t :: any do c[DeepCopy(k)] = DeepCopy(v) end
	return setmetatable(c, getmetatable(t :: any)) :: any
end
```

## 3. string

| Function | Notes |
|---|---|
| `string.len(s)` / `#s` | bytes |
| `string.sub(s, i, j?)` | |
| `string.upper/lower(s)` | |
| `string.rep(s, n, sep?)` | |
| `string.reverse(s)` | |
| `string.byte(s, i?, j?)`, `string.char(...)` | |
| `string.format(fmt, ...)` | `%d %i %f %.2f %s %q %x %5.1f %*` (`%*` = tostring any) |
| `string.find(s, pattern, init?, plain?)` -> start, end, captures | |
| `string.match(s, pattern, init?)` | captures |
| `string.gmatch(s, pattern)` | iterator |
| `string.gsub(s, pattern, repl, n?)` | repl string/table/function |
| `string.split(s, sep?)` -> `{string}` | default sep "," |
| `string.pack(fmt, ...)`, `string.unpack(fmt, s, pos?)`, `string.packsize(fmt)` | binary |

Patterns: `.` any, `%a` letters, `%d` digits, `%l` lower, `%u` upper, `%s` space, `%w` alnum, `%p` punct, `%x` hex, `%c` control; uppercase = complement. `[set]`, `[^set]`, quantifiers `* + - ?`, anchors `^ $`, captures `()`, `%b()` balanced, `%f[set]` frontier, `%1` backref. Escape magic with `%`.

```luau
local id = ("rbxassetid://123456"):match("%d+")      -- "123456"
local parts = string.split("W,A,S,D", ",")
```

## 4. math

`math.abs, ceil, floor, sqrt, exp, log(x, base?), log10, pow, fmod, modf, frexp, ldexp, sin, cos, tan, asin, acos, atan, atan2(y, x), sinh, cosh, tanh, deg, rad, min(...), max(...), huge, pi, random(m?, n?), randomseed(x), noise(x, y?, z?) (Perlin, -1..1), clamp(x, min, max), sign(x) (-1/0/1), round(x) (half away from zero), lerp(a, b, t), map(x, inMin, inMax, outMin, outMax), isnan(x), isinf(x), isfinite(x)`.

- `math.lerp`, `math.map`, `math.isnan/isinf/isfinite` are newer additions; fallback: `a + (b - a) * t`.
- Prefer Roblox `Random.new(seed)` (`:NextNumber(min,max)`, `:NextInteger(min,max)`, `:NextUnitVector()`, `:Shuffle(t)`, `:Clone()`) for deterministic streams.

Game helpers:
```luau
local function Approach(cur: number, target: number, step: number)
	if cur < target then return math.min(cur + step, target) else return math.max(cur - step, target) end
end
local function ExpDecay(a, b, decay, dt) return b + (a - b) * math.exp(-decay * dt) end -- framerate independent smoothing
```

## 5. bit32 (32-bit unsigned ops)

`band, bor, bxor, bnot, lshift, rshift, arshift, lrotate, rrotate, extract(n, field, width?), replace(n, v, field, width?), btest(...), countlz, countrz, byteswap`.
```luau
local FLAG_STUNNED, FLAG_BLOCKING = 1, 2
local flags = bit32.bor(0, FLAG_BLOCKING)
if bit32.btest(flags, FLAG_STUNNED) then end
```

## 6. utf8

`utf8.char(...)`, `utf8.charpattern`, `utf8.codes(s)`, `utf8.codepoint(s, i?, j?)`, `utf8.len(s, i?, j?)`, `utf8.offset(s, n, i?)`, `utf8.graphemes(s)` (Roblox), `utf8.nfcnormalize/nfdnormalize` (Roblox).

## 7. os

| Function | Use |
|---|---|
| `os.clock()` | high-res CPU-ish monotonic seconds - **use for local cooldowns / input windows** |
| `os.time(t?)` | unix seconds (integer) - coarse; not for sub-second windows |
| `os.date(fmt?, t?)` | `"*t"` / `"!*t"` tables |
| `os.difftime(a, b)` | |

Roblox time sources: `workspace:GetServerTimeNow()` (synced server clock, use for cross-machine timestamps), `time()` (game run time), `DateTime.now()`.

## 8. buffer (fixed-size binary)

```luau
local b = buffer.create(16)          -- zero-filled
buffer.len(b)
buffer.writeu8(b, 0, 255)  buffer.readu8(b, 0)
-- i8 u8 i16 u16 i32 u32 f32 f64 (little-endian)
buffer.writestring(b, off, s, count?)  buffer.readstring(b, off, count)
buffer.copy(target, targetOff, source, sourceOff?, count?)
buffer.fill(b, off, value, count?)
buffer.fromstring(s)  buffer.tostring(b)
buffer.readbits(b, bitOffset, bitCount)  buffer.writebits(b, bitOffset, bitCount, value)  -- up to 32 bits
```
Out-of-range access errors. Buffers are sent over remotes efficiently and are DataStore-safe (good for compact network/save encodings).

## 9. vector (Luau native)

`vector.create(x, y, z)`, `vector.magnitude(v)`, `vector.normalize(v)`, `vector.cross(a,b)`, `vector.dot(a,b)`, `vector.angle(a,b,axis?)`, `vector.floor/ceil/abs/sign/clamp/max/min`, `vector.zero`, `vector.one`. On Roblox, `Vector3` values are vectors, so these work on Vector3 and are fast in `--!native`.

## 10. coroutine

`coroutine.create(f)`, `resume(co, ...)` -> ok, ..., `yield(...)`, `status(co)` ("running"/"suspended"/"normal"/"dead"), `wrap(f)`, `running()`, `isyieldable()`, `close(co)` -> ok, err.
On Roblox, resume threads with `task.spawn(co, ...)` / `task.defer(co, ...)` so errors report properly.

## 11. debug

`debug.traceback(msg?, level?)`, `debug.info(fnOrLevel, "slnaf")` (source, line, name, arity, function), `debug.profilebegin(label)` / `debug.profileend()` (MicroProfiler), `debug.setmemorycategory(name)` / `resetmemorycategory()`, `debug.dumpcodesize()`.

```luau
debug.profilebegin("Combat.Hitbox")
-- hot code
debug.profileend()
```

## 12. Config tables

```luau
local Timings = table.freeze({
	DirectionalWindow = 0.25,
	ParryWindow = 0.18,
	ComboReset = 1.1,
})
```
Freeze is shallow - freeze nested tables individually.
