--!strict
-- Built-in NetChannel (core.contracts.interfaces §2): one RemoteEvent, per-frame batching, type checks.
-- Infrastructure module: branching on IsServer is allowed here (never in game code).
--
--   local Ch = Net.Define("Name", { "U8", "Instance" })   -- identical call on both sides (shared module)
--   Client: Ch:Fire(...)            Server: Ch:OnServer(function(Player, ...) end)
--   Server: Ch:Fire(...) (all), Ch:FireClient(Player, ...), Ch:FireExcept(Player, ...)
--   Client: Ch:OnClient(function(...) end)
-- Incoming values that don't match the declared types drop the whole message.
-- Indexer standard (V2): each channel travels as a numeric id hashed from its name, so both sides agree on
-- ids no matter which order modules define channels in; a hash collision errors at Define time.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Signal = require(script.Parent.Signal)

local IS_SERVER = RunService:IsServer()

local Remote : RemoteEvent
if IS_SERVER then
	Remote = Instance.new("RemoteEvent")
	Remote.Name = "NetRemote"
	Remote.Parent = script
else
	Remote = script:WaitForChild("NetRemote") :: RemoteEvent
end

local function IsInt(V : any, Min : number, Max : number) : boolean
	return type(V) == "number" and V % 1 == 0 and V >= Min and V <= Max
end

local Checks : { [string]: (any) -> boolean } = {
	U8 = function(V) return IsInt(V, 0, 255) end,
	U16 = function(V) return IsInt(V, 0, 65535) end,
	U32 = function(V) return IsInt(V, 0, 4294967295) end,
	S8 = function(V) return IsInt(V, -128, 127) end,
	S16 = function(V) return IsInt(V, -32768, 32767) end,
	S32 = function(V) return IsInt(V, -2147483648, 2147483647) end,
	F32 = function(V) return type(V) == "number" and V == V and math.abs(V) < 3.4e38 end,
	F64 = function(V) return type(V) == "number" and V == V and V ~= math.huge and V ~= -math.huge end,
	Bool = function(V) return type(V) == "boolean" end,
	String = function(V) return type(V) == "string" and #V <= 1024 end,
	Instance = function(V) return V == nil or typeof(V) == "Instance" end, -- nil = not replicated / streamed out
	Vector3 = function(V) return typeof(V) == "Vector3" and V == V end,
	CFrame = function(V) return typeof(V) == "CFrame" end,
	Any = function(_) return true end,
}

local Net = {}
local Channels : { [string]: any } = {}
local ById : { [number]: any } = {}

-- djb2 kept below 2^24 so the arithmetic stays exact in doubles
local function Hash(Name : string) : number
	local H = 5381
	for I = 1, #Name do
		H = (H * 33 + string.byte(Name, I)) % 16777213
	end
	return H
end

local Outgoing : { any } = {}
local PerPlayer : { [Player]: { any } } = {}

local Channel = {}
Channel.__index = Channel

function Net.Define(Name : string, Types : { string })
	assert(Channels[Name] == nil, `channel {Name} defined twice`)
	for _, T in Types do
		assert(Checks[T], `unknown type token {T}`)
	end
	local Id = Hash(Name)
	assert(ById[Id] == nil, `channel {Name} collides with {ById[Id] and ById[Id].Name}; rename one`)
	local Ch = setmetatable({ Name = Name, Id = Id, Types = Types, _signal = Signal.new() }, Channel)
	Channels[Name] = Ch
	ById[Id] = Ch
	return Ch
end

-- remotes truncate arrays at the first nil, so arguments travel as a string-keyed map
local function Pack(Ch : any, ... : any)
	local N = select("#", ...)
	local Args : { [string]: any } = { n = N }
	for I = 1, N do
		Args[tostring(I)] = (select(I, ...))
	end
	return { c = Ch.Id, a = Args }
end

function Channel.Fire(self : any, ... : any)
	table.insert(Outgoing, Pack(self, ...))
end

function Channel.FireClient(self : any, Player : Player, ... : any)
	assert(IS_SERVER, "FireClient is server only")
	local Q = PerPlayer[Player]
	if not Q then
		Q = {}
		PerPlayer[Player] = Q
	end
	table.insert(Q, Pack(self, ...))
end

function Channel.FireExcept(self : any, Except : Player, ... : any)
	for _, P in Players:GetPlayers() do
		if P ~= Except then
			self:FireClient(P, ...)
		end
	end
end

function Channel.OnServer(self : any, Fn : (Player, ...any) -> ())
	return self._signal:Connect(Fn)
end

function Channel.OnClient(self : any, Fn : (...any) -> ())
	return self._signal:Connect(Fn)
end

local function Unpack(Ch : any, Args : any) : (boolean, { any }?)
	if type(Args) ~= "table" or type(Args.n) ~= "number" or Args.n > #Ch.Types then
		return false, nil
	end
	local Out = table.create(#Ch.Types)
	for I, T in Ch.Types do
		local V = Args[tostring(I)]
		if not Checks[T](V) then
			return false, nil
		end
		Out[I] = V
	end
	return true, Out
end

-- Studio-only debug mirror of dropped client traffic (Net_<Reason> attributes on the Player)
local IS_STUDIO = RunService:IsStudio()
local function Dropped(Player : Player?, Reason : string)
	if IS_STUDIO and Player then
		local Key = `Net_{Reason}`
		Player:SetAttribute(Key, ((Player:GetAttribute(Key) :: number?) or 0) + 1)
	end
end

-- flood guard on client → server traffic: a plain array of at most 64 messages. Counts by walking the
-- table, because # ignores string keys and a forged batch could hide any number of messages behind them.
local function ValidClientBatch(Batch : any) : boolean
	if type(Batch) ~= "table" then
		return false
	end
	local Count = 0
	for Key in Batch do
		Count += 1
		if Count > 64 or type(Key) ~= "number" then
			return false
		end
	end
	return true
end

local function Deliver(Batch : any, Player : Player?)
	if type(Batch) ~= "table" or (Player ~= nil and not ValidClientBatch(Batch)) then
		Dropped(Player, "BadBatch")
		return
	end
	for _, Msg in Batch do
		local Ch = type(Msg) == "table" and type(Msg.c) == "number" and ById[Msg.c]
		if Ch then
			local Ok, A = Unpack(Ch, Msg.a)
			if Ok and A then
				local N = #Ch.Types
				if Player then
					Ch._signal:Fire(Player, table.unpack(A, 1, N))
				else
					Ch._signal:Fire(table.unpack(A, 1, N))
				end
			else
				Dropped(Player, "BadArgs")
			end
		else
			Dropped(Player, "UnknownChannel")
		end
	end
end

if IS_SERVER then
	Remote.OnServerEvent:Connect(function(Player, Batch)
		Deliver(Batch, Player)
	end)
	Players.PlayerRemoving:Connect(function(P)
		PerPlayer[P] = nil
	end)
	RunService.Heartbeat:Connect(function()
		if #Outgoing > 0 then
			Remote:FireAllClients(Outgoing)
			Outgoing = {}
		end
		for P, Q in PerPlayer do
			if P.Parent then
				Remote:FireClient(P, Q)
			end
		end
		table.clear(PerPlayer)
	end)
else
	Remote.OnClientEvent:Connect(function(Batch)
		Deliver(Batch, nil)
	end)
	RunService.Heartbeat:Connect(function()
		if #Outgoing > 0 then
			Remote:FireServer(Outgoing)
			Outgoing = {}
		end
	end)
end

return Net
