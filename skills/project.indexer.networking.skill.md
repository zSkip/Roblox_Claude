---
name: project.indexer.networking
description: The user's own Indexer networking module (IndexerV2) - identifier-routed RemoteEvent wrapper. API (Indexer.New, Object:Connect, Object:Recursive, Indexer.Fire), types, runtime connection setup, known bugs and risks, and how to run Indexer's identifier API on top of Packet for compression and validation. Use when touching project networking code that uses Indexer.
---

# Indexer (project networking module)

> **Optional adapter.** Game code uses the `NetChannel` contract (core.contracts.interfaces §2). Your Indexer can implement that contract (adapter note in core.contracts.interfaces §2), or keep handling non-combat traffic.

Purpose: route messages by **string identifier** over one or more RemoteEvents. An identifier defined on both sides forms a channel; `:Connect` registers handlers, `:Recursive` sends on the object's own identifier, `Indexer.Fire` sends on any identifier.

## 1. API

```luau
local Indexer = require(game.ReplicatedStorage.IndexerV2)

local Weapons = Indexer.New({ Remote = path.Weapons, Identifier = "Goop" })   -- identifier lowercased; asserts unique
Weapons:Connect(function(Player, Data) end)            -- server handler: (sender, PassedData)
Weapons:Connect(function(Data) end, 1)                 -- client handler: (PassedData); optional position in FunctionArray

-- server -> listed clients
Weapons:Recursive({ ClientsTo = { player }, PassedData = { Damage = 10 } })
-- client -> server
Weapons:Recursive({ PassedData = { Action = "M1" } })

-- any identifier / remote
Indexer.Fire({ Remote = path.Weapons, Identifier = "Goop", ClientsTo = { player }, PassedData = {} })   -- server
Indexer.Fire({ Remote = path.Weapons, Identifier = "Goop", PassedData = {} })                         -- client
```

Wire format: `Remote:FireServer/FireClient({ Identifier = string, PassedData = table })`.

## 2. Types (from source)

```luau
export type IndexerConstructor = { Remote: RemoteEvent ; Identifier: string }
export type Indexer = { Remote: RemoteEvent ; Identifier: string ; FunctionArray: {} }
export type RecursiveType = { ClientsTo: { Player } ; PassedData: { any } }
export type FireType = { Remote: RemoteEvent ; Identifier: string ; ClientsTo: { Player } ; PassedData: { any } }
export type BackForth = { Identifier: string ; PassedData: { any } }
```
Module tables: `Indexer.Repository` (`[identifier] = object`), `Indexer.Connections` (`[RemoteEvent] = { ConnectedIdentifiers, Connection }`).

## 3. Runtime setup

At require time `RunTimeEvents` spawns, waits **one frame**, then connects `OnServerEvent`/`OnClientEvent` once per distinct Remote found in `Repository`. Each incoming message: asserts shape, looks up `Repository[PassedData.Identifier]`, calls every function in `FunctionArray` in order.

## 4. Known bugs / risks (fix before relying on it)

| Issue | Effect | Fix |
|---|---|---|
| Remotes are only connected for objects that exist **one frame after the module is first required** | An `Indexer.New` on a *new Remote* created later (lazy-required weapon module, respawn) never receives anything | Connect the remote inside `Indexer.New` when `Connections[Remote]` is missing |
| `assert` inside the server `OnServerEvent` handler | Any client can send malformed data and spam errors in server output | Validate and `return` silently on the server; keep asserts for local API misuse |
| Handlers called directly in a loop | One erroring handler stops the rest for that message | `task.spawn(fn, ...)` or `pcall` per handler |
| `table.insert(FunctionArray, Order, fn)` | errors if `Order > #FunctionArray + 1` | clamp `Order` |
| No rate limit / no type schema | exploit surface, uncompressed tables | per-identifier validator + rate limit, or run on Packet (below) |
| `Indexer.Fire` mutates the caller's `PassedParam.Identifier` | surprising side effect | copy to a local |
| `RunServ:IsServer()` branches in `Recursive`/`Fire` | fine for a library, but you said shared code shouldn't branch - keep the branch inside Indexer only | — |
| No broadcast | every server send needs a player list | add `ClientsTo = "All"` or a `:Broadcast()` |
| One Repository keyed by identifier only | the same identifier can't exist on two remotes | key by `remote.Name .. ":" .. identifier` if needed |
| `PassedData` must be a table | single values must be wrapped | fine, or allow any |

## 5. Indexer API on Packet (recommended v1 transport)

Keep your identifier-object ergonomics but get Packet's buffers, batching and type safety:

```luau
-- IndexerV3 (sketch): each identifier = one Packet definition with a type schema
local Packet = require(game.ReplicatedStorage.Packages.Packet)
local Indexer = { Repository = {} }
local Class = {} ; Class.__index = Class

function Indexer.New(Params: { Identifier: string, Types: { any } })   -- Types = Packet type tokens
	local Id = string.lower(Params.Identifier)
	assert(Indexer.Repository[Id] == nil, "Identifier In Use")
	local self = setmetatable({
		Identifier = Id ;
		Packet = Packet(Id, table.unpack(Params.Types)) ;
	}, Class)
	Indexer.Repository[Id] = self
	return self
end

function Class:Connect(Fn)                -- Packet signals exist per side; connect whichever is present
	local P = self.Packet
	return (P.OnServerEvent or P.OnClientEvent):Connect(Fn)
end

function Class:Recursive(Params: { ClientsTo: { Player }?, PassedData: { any } })
	local P = self.Packet
	if Params.ClientsTo then
		for _, Plr in Params.ClientsTo do P:FireClient(Plr, table.unpack(Params.PassedData)) end
	else
		P:Fire(table.unpack(Params.PassedData))        -- client: to server ; server: to all clients
	end
end

return Indexer
```
Differences: data becomes **positional typed arguments** instead of a free table; handlers receive the values directly (`fn(player, action, dir)`), and Packet's signal runs handlers deferred. The `OnServerEvent or OnClientEvent` line is still side-aware but contains no explicit `IsServer` call in game code.

## 6. When to use which

| Message | Use |
|---|---|
| Combat intents, hit claims, results, stamina | Packet definitions in `Combat/Net` (or IndexerV3 over Packet) |
| Low-frequency tools/admin/debug messages with free-form tables | Indexer (current) is fine after fixing §4 |
