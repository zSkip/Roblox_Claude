--!strict
-- Shared frame clock (replication-and-validation §4): server time on every peer, 60 frames a second to
-- match the animations. Combat timing that crosses machines (status effects today) uses this, never
-- os.clock(). Per-player RTT measurement comes later with the Replicator.
--
--   Clock.Now() -> seconds of server time      Clock.Frame(t?) -> floor(t × Fps)      Clock.FrameTime(f)

local Clock = {}

Clock.Fps = 60

function Clock.Now() : number
	return workspace:GetServerTimeNow()
end

function Clock.Frame(T : number?) : number
	return math.floor((T or Clock.Now()) * Clock.Fps)
end

function Clock.FrameTime(Frame : number) : number
	return Frame / Clock.Fps
end

return table.freeze(Clock)
