---
name: roblox.data.datastore-messaging-memory
description: Roblox cloud data services underneath ProfileStore - DataStoreService (GetDataStore, GlobalDataStore/DataStore methods, OrderedDataStore for leaderboards, options, budgets, limits), MessagingService (PublishAsync/SubscribeAsync), MemoryStoreService (SortedMap, Queue, HashMap), game:BindToClose, Studio API access. Use for leaderboards, cross-server features, or understanding ProfileStore internals.
---

# Roblox — DataStore, MessagingService, MemoryStore

Player profiles: use **ProfileStore** (lib.profilestore.datastore). Use raw services for leaderboards, global/cross-server data.

## 1. DataStoreService (server only)

```luau
local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("Name", scope?, options?)    -- DataStore
local ordered = DataStoreService:GetOrderedDataStore("Kills")            -- OrderedDataStore
DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
```

DataStore methods (all yield, wrap in `pcall`):
| Method | Notes |
|---|---|
| `:GetAsync(key, options?)` -> value, DataStoreKeyInfo | cached ~4s |
| `:SetAsync(key, value, userIds?, options?)` -> version | overwrite |
| `:UpdateAsync(key, transform(old, keyInfo) -> (new, userIds?, metadata?))` | atomic read-modify-write; return nil to cancel |
| `:IncrementAsync(key, delta?, userIds?, options?)` | integers |
| `:RemoveAsync(key)` | |
| `:ListKeysAsync(prefix?, pageSize?, cursor?, excludeDeleted?)` | `DataStoreKeyPages` |
| `:ListVersionsAsync(key, sortDirection?, minDate?, maxDate?, pageSize?)` | |
| `:GetVersionAsync(key, version)` / `:RemoveVersionAsync(key, version)` | |

`DataStoreKeyInfo`: `CreatedTime`, `UpdatedTime`, `Version`, `:GetMetadata()`, `:GetUserIds()`.
`DataStoreSetOptions:SetMetadata(table)`.

OrderedDataStore (integers only): `:GetSortedAsync(ascending, pageSize, minValue?, maxValue?)` -> `DataStorePages` (`:GetCurrentPage()` -> `{ {key, value} }`, `:AdvanceToNextPageAsync()`, `.IsFinished`), plus Get/Set/Update/Increment/Remove.

Limits (approximate; check docs for current values): value up to 4 MB per key, key name ≤ 50 chars, store name ≤ 50 chars; per-server request budget scales with players (roughly 60 + 10×players per minute for get/set categories). Same key writes ≥ 6s apart. Values: JSON-able tables (see ProfileStore data rules), strings, numbers, booleans, buffers.

Studio: Game Settings -> Security -> "Enable Studio Access to API Services" (writes live data!). Use `ProfileStore.Mock` in Studio.

## 2. game:BindToClose

```luau
game:BindToClose(function()
	-- up to ~30s to finish saving; ProfileStore already hooks this for its profiles
	if game:GetService("RunService"):IsStudio() then task.wait(1) end
end)
```

## 3. MessagingService (cross-server pub/sub)

```luau
local MessagingService = game:GetService("MessagingService")
local conn = MessagingService:SubscribeAsync("Topic", function(message)  -- {Data = any, Sent = number}
	print(message.Data)
end)
MessagingService:PublishAsync("Topic", { Kind = "Announcement", Text = "Event!" })  -- payload ≤ 1 KB
conn:Disconnect()
```
Not guaranteed delivery; rate limits per server and per topic. ProfileStore uses it to speed session hand-off.

## 4. MemoryStoreService (fast, expiring, cross-server)

```luau
local MemoryStoreService = game:GetService("MemoryStoreService")
local map = MemoryStoreService:GetSortedMap("Matchmaking")
map:SetAsync(key, value, expirationSeconds, sortKey?) ; map:GetAsync(key) ; map:UpdateAsync(key, fn, expiration)
map:RemoveAsync(key) ; map:GetRangeAsync(Enum.SortDirection.Ascending, count, exclusiveLowerBound?, exclusiveUpperBound?)

local queue = MemoryStoreService:GetQueue("Ranked", invisibilityTimeout?)
queue:AddAsync(value, expiration, priority?) ; local items, id = queue:ReadAsync(count, allOrNothing?, waitTimeout?) ; queue:RemoveAsync(id)

local hash = MemoryStoreService:GetHashMap("Parties")   -- Set/Get/Update/Remove/ListItemsAsync
```
Max expiration 45 days; data is not durable - use for matchmaking, live leaderboards, party state.

## 5. Combat-game uses

| Need | Service |
|---|---|
| Player progress, weapons owned, keybinds | ProfileStore |
| All-time kills leaderboard | OrderedDataStore (write on session end / periodically) |
| Live server-wide event | MessagingService |
| Ranked queue / duel matchmaking | MemoryStore Queue/SortedMap + TeleportService |
| Gifting weapons to offline friends | `ProfileStore:MessageAsync` |
