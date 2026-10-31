---
name: lib.packet.networking
description: Suphi Kaner's "Packet" networking library (v1.7.x) - typed, buffer-compressed, frame-batched RemoteEvent wrapper. Constructor, every data type with byte cost and range, struct/array syntax, Fire/FireClient/Response/Invoke, internal batching, rate limits, config files (Enums/Static/Characters). Use when defining or debugging replication packets.
---

# Packet — Networking Library (Suphi Kaner / 5uphi)

> **Optional adapter.** Nothing in this skill set requires Packet. Game code uses the `NetChannel` contract (core.contracts.interfaces), which has a built-in RemoteEvent implementation. This file documents Packet so it can be plugged in as a faster, smaller transport (see the Packet adapter in core.contracts.interfaces §2). The size/encoding facts here also help if you add `buffer` packing to the built-in channel yourself.

Source of truth for this file: the library source (v1.7.x, `init.luau`, `Signal.luau`, `Task.luau`, `Types/*.luau`).
DevForum thread: `https://devforum.roblox.com/t/packet-networking-library/3573907`.

## 1. Install / layout

```
ReplicatedStorage
└─ Packet            (ModuleScript, init.luau)
   ├─ Signal          (ModuleScript) - Packet's own deferred signal
   ├─ Task            (ModuleScript) - thread-reuse spawn/defer/delay
   ├─ Types           (ModuleScript) - serializers
   │  ├─ Enums        (ModuleScript) - list of Enum *types* EnumItem can send (max 255)
   │  ├─ Static1/2/3  (ModuleScript) - lists of static values (max 255 each)
   │  └─ Characters   (ModuleScript) - character alphabet for Packet.Characters
   └─ RemoteEvent     (created at runtime by the server, child of the module)
```

- Lives in **ReplicatedStorage**; the *same module* is required on both server and client.
- Internally it branches on `RunService:IsServer()` - **your code does not need to**; define packets once in a shared module and require that module from both sides.
- The server creates the single `RemoteEvent` and writes each packet's id as an **attribute** on it (`remoteEvent:SetAttribute(name, id)`); the client reads ids from those attributes (`AttributeChanged` handles late definitions). Packet ids are written as `U8` -> **max 256 packet definitions**.

## 2. Constructor

```luau
local Packet = require(game.ReplicatedStorage.Packet)

-- Packet(name: string, ...types) -> Packet<A...>
local Hit = Packet("Hit", Packet.Instance, Packet.NumberU16, Packet.Vector3F24)
```

- Called as a function (the module returns `setmetatable(Types.Types, {__call = Constructor})`).
- Calling `Packet("Hit", ...)` again with the same name returns the **same cached packet** (types are ignored on repeat calls).
- The module table itself exposes the type tokens: `Packet.NumberU8`, `Packet.String`, ...
- Varargs order = argument order of `Fire`.

### Typed signature (from source)

```luau
export type Packet<A... = (), B... = ()> = {
	Type: "Packet",
	Id: number,
	Name: string,
	Reads: {() -> any},
	Writes: {(any) -> ()},
	ResponseTimeout: number,          -- default 10 (seconds) once :Response() is called
	ResponseTimeoutValue: any,        -- value returned to the yielded caller on timeout (default nil)
	ResponseReads: {() -> any},
	ResponseWrites: {(any) -> ()},
	OnServerEvent: Signal<(Player, A...)>,   -- exists only on server
	OnClientEvent: Signal<A...>,             -- exists only on client
	OnServerInvoke: nil | (player: Player, A...) -> B...,
	OnClientInvoke: nil | (A...) -> B...,
	Response: (self, B...) -> Packet<A..., B...>,
	Fire: (self, A...) -> B...,
	FireClient: (self, player: Player, A...) -> B...,
	Serialize: (self, A...) -> (buffer, {Instance}?),
	Deserialize: (self, serializeBuffer: buffer, instances: {Instance}?) -> A...,
}
```

## 3. Methods

| Method | Side | Behaviour |
|---|---|---|
| `packet:Fire(...)` | client | Queue to server. |
| `packet:Fire(...)` | server | Queue to **all** clients (written to the shared broadcast cursor). |
| `packet:FireClient(player, ...)` | server | Queue to one client (per-player cursor). Silently returns if `player.Parent == nil`. |
| `packet:Response(...types)` | both | Declares return types -> packet becomes request/response. Returns the packet (chainable). Sets `ResponseTimeout = 10` if unset. |
| `packet:Fire(...)` (response packet) | client | **Yields**, returns the server's `OnServerInvoke` results. Erroring on the server with `"You must use FireClient(player)"`. |
| `packet:FireClient(player, ...)` (response packet) | server | **Yields**, returns client's `OnClientInvoke` results. |
| `packet:Serialize(...)` | both | Returns `buffer, {Instance}?` - use for DataStore/MemoryStore compaction or custom transport. |
| `packet:Deserialize(buf, instances?)` | both | Inverse of Serialize. |
| `packet.OnServerEvent:Connect(fn(player, ...))` | server | Listen. |
| `packet.OnClientEvent:Connect(fn(...))` | client | Listen. |
| `packet.OnServerInvoke = fn(player, ...) -> ...` | server | Assign (not Connect). |
| `packet.OnClientInvoke = fn(...) -> ...` | client | Assign. |

There is **no** built-in `FireAllClients`, `FireExcept`, or `FireClients(list)` - server `:Fire` already broadcasts; for "all except" loop `Players:GetPlayers()` and `FireClient`.

Response constraints: max **128 outstanding yielded threads** per direction (per player on the server) -> `error("Cannot have more than 128 yielded threads")`. On timeout the caller resumes with `ResponseTimeoutValue`. You can set `packet.ResponseTimeout = 3` / `packet.ResponseTimeoutValue = false` after `:Response()`.

```luau
-- shared
local GetStamina = Packet("GetStamina"):Response(Packet.NumberU8)
-- server
GetStamina.OnServerInvoke = function(player) return Stamina[player] or 0 end
-- client
local stamina = GetStamina:Fire()   -- yields, max 10s
```

## 4. Packet's Signal (not GoodSignal)

```luau
Signal<A...>: Connect(fn) -> Connection, Once(fn) -> Connection, Wait() -> A..., Fire(...)
Connection: Disconnect()
```
- Doubly linked list, **FIFO** (connection order preserved).
- `Fire` uses `Task:Defer` -> **every handler runs deferred** (end of current resumption cycle), never inline. Do not expect state to have changed synchronously after an incoming packet is processed.

## 5. Data types (exact list from v1.7.x `Types/init.luau`)

Ranges (from source header):
```
S8  -128 .. 127              U8  0 .. 255
S16 -32768 .. 32767          U16 0 .. 65535
S24 -8388608 .. 8388607      U24 0 .. 16777215
S32 -2147483648 .. 2147483647 U32 0 .. 4294967295
F16 exact ints to ±2048,      max ±65520
F24 exact ints to ±262144,    max ±4294959104
F32 exact ints to ±16777216
F64 exact ints to ±9007199254740992
```

| Token | Lua value | Bytes | Notes |
|---|---|---|---|
| `Packet.Any` | any | 1 + payload | 1-byte type tag + value; supports nil, number, string, buffer, Instance, boolean, NumberRange, BrickColor, Color3, UDim, UDim2, Rect, Vector2, Vector3, CFrame, Region3, NumberSequence, ColorSequence, EnumItem, table (recursive key/value, 0-terminated). Convenient but largest/slowest. |
| `Packet.Nil` | nil | 0 | placeholder |
| `Packet.NumberS8/S16/S24/S32` | integer | 1/2/3/4 | signed ints |
| `Packet.NumberU8/U16/U24/U32` | integer | 1/2/3/4 | unsigned ints - values are truncated, not clamped; out of range wraps |
| `Packet.NumberF16/F24/F32/F64` | number | 2/3/4/8 | floats; F16/F24 are custom half/24-bit floats |
| `Packet.NumberU4` | `{number, number}` | 1 | two 4-bit ints (0..15) in one byte |
| `Packet.BooleanNumber` | `{Boolean: boolean, Number: number}` | 1 | 1 bit + 7-bit uint (0..127) |
| `Packet.Boolean1` | `{boolean x8}` | 1 | 8 bit-packed booleans (array of 8) |
| `Packet.Boolean8` | boolean | 1 | one bool per byte |
| `Packet.String` | string | 1 + len | **max 255 bytes** (U8 length) |
| `Packet.StringLong` | string | 2 + len | max 65535 bytes |
| `Packet.Characters` | string | 1 + ceil(len*bits/8) | only chars in `Types/Characters` (default 64 chars = 6 bits/char: space . 0-9 A-Z a-z); max 255 chars |
| `Packet.Buffer` | buffer | 1 + len | max 255 bytes |
| `Packet.BufferLong` | buffer | 2 + len | max 65535 |
| `Packet.Instance` | Instance | 0 in buffer | sent in the RemoteEvent's instance array (Roblox reference). Arrives `nil` if not replicated to receiver. |
| `Packet.EnumItem` | EnumItem | 3 | U8 enum-type index + U16 value. **Only enum types listed in `Types/Enums.luau`** (default: AccessoryType, Axis, BodyPart, BodyPartR15, EasingDirection, EasingStyle, KeyCode, Material, NormalId). `UserInputType` is NOT in the default list - add it or send your own U8 ids. |
| `Packet.Static1/2/3` | any | 1 | index into `Types/Static1..3` lists (max 255 each). Unknown value writes 0 -> reads `nil` (lists are 1-based). Great for fixed string ids ("Physical", "Magical"). |
| `Packet.NumberRange` | NumberRange | 8 | 2x F32 |
| `Packet.BrickColor` | BrickColor | 2 | U16 number |
| `Packet.Color3` | Color3 | 3 | RGB U8 each |
| `Packet.UDim` | UDim | 4 | Scale as S16/1000 (±32.767), Offset S16 |
| `Packet.UDim2` | UDim2 | 8 | 2x UDim |
| `Packet.Rect` | Rect | 16 | 4x F32 |
| `Packet.Vector2S16` / `Vector2F24` / `Vector2F32` | Vector2 | 4 / 6 / 8 | |
| `Packet.Vector3S16` / `Vector3F24` / `Vector3F32` | Vector3 | 6 / 9 / 12 | S16 = integer studs only |
| `Packet.CFrameF24U8` | CFrame | 12 | pos F24, rotation XYZ euler U8 (~1.4 deg steps) |
| `Packet.CFrameF32U8` | CFrame | 15 | pos F32, rot U8 |
| `Packet.CFrameF32U16` | CFrame | 18 | pos F32, rot U16 (~0.0055 deg) |
| `Packet.Region3` | Region3 | 24 | min/max as F32 |
| `Packet.NumberSequence` | NumberSequence | 1 + 3n | time/value/envelope quantised to U8/255 (values must be 0..1) |
| `Packet.ColorSequence` | ColorSequence | 1 + 4n | |

Choosing for combat:
- Enumerated actions/directions/outcomes -> `NumberU8` (or `NumberU4` to pack two 0..15 values in one byte).
- Damage -> `NumberU16` (integer) or `NumberF16` (fractional, small).
- Server time stamps -> `NumberF64` (`workspace:GetServerTimeNow()` needs > F32 precision).
- Positions for hit FX -> `Vector3F24`.
- Character / target -> `Packet.Instance` (the Model or HumanoidRootPart).
- Flag sets -> `Boolean1`.

## 6. Tables / arrays / structs

```luau
-- Array: a table with exactly ONE element = element type. U16 length prefix (max 65535).
Packet("Targets", {Packet.Instance})

-- Struct: table with string keys. Keys are SORTED alphabetically and written in that order;
-- key names are NOT sent (0 bytes overhead). Every key must be present when firing
-- (missing values hit the writer with nil -> error).
Packet("HitInfo", {
	Target = Packet.Instance,
	Damage = Packet.NumberU16,
	Direction = Packet.NumberU8,
	Position = Packet.Vector3F24,
})

-- Nested
Packet("Batch", {{ Id = Packet.NumberU8, Pos = Packet.Vector3F24 }})  -- array of structs
```

- A one-element table is always an **array**, so a struct with a single field must use a different shape (e.g. pass the field as a plain parameter).
- No optional fields; use `Packet.Any` for a field that can be nil, or a sentinel value.
- Dictionaries with dynamic keys are not supported except via `Packet.Any`.

## 7. Wire format and batching (internals)

- Each queued call writes `U8 packetId` (+ `U8 threadIndex` for response packets; `index < 128` request, `index + 128` response) then each parameter in order into a growable `buffer` (starts 128 bytes, doubles).
- **Server**: on every `RunService.Heartbeat` a deferred flush sends `remoteEvent:FireAllClients(buffer[, instances])` for broadcast data and `remoteEvent:FireClient(player, buffer[, instances])` per player. All packets in a frame -> **one** RemoteEvent call per recipient.
- **Client**: flushes at most **60 Hz** (accumulates Heartbeat delta, 1/60 s).
- Receivers loop `while not Ended() do local packet = packets[ReadU8()] ... end`, deserialising sequentially - order within a frame is preserved.
- Reliable only (uses `RemoteEvent`, not `UnreliableRemoteEvent`). For high-rate cosmetic data, consider a separate `UnreliableRemoteEvent` + `packet:Serialize()`.

## 8. Security / rate limits (server)

- Per player per server frame: accumulates `max(buffer.len(received), 800)` bytes; if it exceeds **8000** the whole incoming buffer is dropped (Studio warns `"is exceeding the data/rate limit; some events may be dropped"`). => roughly **10 client sends per frame** max regardless of size.
- Incoming parsing is wrapped in `pcall`; malformed buffers are dropped (Studio warns). A malicious client can still send *well-formed* but wrong values - **always validate** (type ranges are guaranteed by decoding, semantics are not; e.g. an `Instance` param can be any replicated instance or nil).
- Client cannot fire to other clients; server decides.

## 9. Config modules

```luau
-- Types/Enums.luau  (Add any enum [Max: 255])
return { Enum.KeyCode, Enum.UserInputType, Enum.HumanoidStateType, ... }

-- Types/Static1.luau (any values, max 255; index 0 = nil)
return { "Physical", "Magical", "True" }

-- Types/Characters.luau  ([0]-indexed alphabet; recommended sizes 2,4,8,...,256)
return {[0] = " ", ".", "0", ... }
```
Both sides must ship identical lists (they are in ReplicatedStorage, so they do).

## 10. Patterns

```luau
-- ReplicatedStorage/Shared/Combat/CombatNet.luau  (shared; no IsServer checks needed)
local Packet = require(game.ReplicatedStorage.Packages.Packet)
return {
	Input   = Packet("CombatInput", Packet.NumberU8, Packet.NumberU8, Packet.NumberF64),          -- action, direction, clientServerTime
	Action  = Packet("CombatAction", Packet.Instance, Packet.NumberU8, Packet.NumberU8, Packet.NumberU8), -- actor, action, dir, comboIndex
	Result  = Packet("CombatResult", Packet.Instance, Packet.Instance, Packet.NumberU8, Packet.NumberU16), -- attacker, defender, outcome, damage
	Stamina = Packet("CombatStamina", Packet.NumberU8),
}
```

```luau
-- server
Net.Input.OnServerEvent:Connect(function(player, action, direction, t)
	if action > MAX_ACTION or direction > 4 then return end -- validate
	-- ...
end)
-- client
Net.Input:Fire(ACTION.M1, DIR.Front, workspace:GetServerTimeNow())
```

Gotchas
- Define each packet **once** with the same type list on both sides (shared module guarantees it).
- `Fire` arguments are positional; passing extra args is ignored, missing args error in the writer.
- Integers written to `U*` with negatives / floats are truncated by `buffer.write*` - clamp first.
- Handlers are deferred; if you need same-frame ordering between two packets, put both pieces of data in one packet.
- Server `Fire` = broadcast to *everyone including the sender*; filter on the client if needed (`if actor == LocalPlayer.Character then return end`).
