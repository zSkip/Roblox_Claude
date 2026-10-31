--!strict
-- Built-in SignalLike (core.contracts.interfaces §1): immediate, FIFO, safe to disconnect during Fire,
-- handlers may yield. Swap for a GoodSignal adapter in Core/Deps if you want (note: GoodSignal is LIFO).

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

export type Connection = { Connected : boolean, Disconnect : (self : any) -> () }

function Connection.Disconnect(self : any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local List = self._signal._list
	local Index = table.find(List, self)
	if Index then
		table.remove(List, Index)
	end
end

function Signal.new()
	return setmetatable({ _list = {} :: { any } }, Signal)
end

function Signal.Connect(self : any, Fn : (...any) -> ()) : Connection
	local C = setmetatable({ Connected = true, _fn = Fn, _signal = self }, Connection)
	table.insert(self._list, C)
	return C :: any
end

function Signal.Once(self : any, Fn : (...any) -> ()) : Connection
	local C : Connection
	C = self:Connect(function(...)
		C:Disconnect()
		Fn(...)
	end)
	return C
end

function Signal.Wait(self : any) : ...any
	local Thread = coroutine.running()
	self:Once(function(...)
		task.spawn(Thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire(self : any, ... : any)
	local Snapshot = table.clone(self._list)
	for _, C in Snapshot do
		if C.Connected then
			task.spawn(C._fn, ...)
		end
	end
end

function Signal.DisconnectAll(self : any)
	for _, C in self._list do
		C.Connected = false
	end
	table.clear(self._list)
end

return Signal
