--!strict
-- Cleanup helper (core.contracts.interfaces §5). Give it connections, instances, threads, functions
-- or objects with :Destroy() / :Disconnect(); Clean() releases everything in reverse order.

local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _t = {} :: { any } }, Maid)
end

function Maid.Give<T>(self : any, X : T) : T
	table.insert(self._t, X)
	return X
end

function Maid.Clean(self : any)
	local T = self._t
	self._t = {}
	for I = #T, 1, -1 do
		local X = T[I]
		local Kind = typeof(X)
		if Kind == "function" then
			X()
		elseif Kind == "RBXScriptConnection" then
			X:Disconnect()
		elseif Kind == "Instance" then
			X:Destroy()
		elseif Kind == "thread" then
			pcall(task.cancel, X)
		elseif type(X) == "table" then
			if type(X.Destroy) == "function" then
				X:Destroy()
			elseif type(X.Disconnect) == "function" then
				X:Disconnect()
			end
		end
	end
end

Maid.Destroy = Maid.Clean

return Maid
