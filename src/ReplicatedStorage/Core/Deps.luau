--!strict
-- The ONLY place that decides which implementation backs each contract.
-- Swap a line for an adapter (GoodSignal, Packet, HitboxClass...) without touching game code.
-- Loaded lazily, so requiring Deps for Signal (e.g. in unit tests) doesn't create network remotes.

local Modules = {
	Signal = script.Parent.Signal,
	Net = script.Parent.Net,
	Hitbox = script.Parent.Hitbox,
	Maid = script.Parent.Maid,
}

return setmetatable({}, {
	__index = function(Self, Key)
		local Module = Modules[Key]
		assert(Module, `Deps has no contract named {tostring(Key)}`)
		local Value = (require :: any)(Module)
		rawset(Self, Key, Value)
		return Value
	end,
}) :: any
