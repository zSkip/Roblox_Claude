--!strict
-- Client entry (single-script architecture): the only LocalScript. Waits for the initial replication,
-- then runs every controller in Controllers through Core/Loader (Init in priority order, then Start).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Loader = require(ReplicatedStorage:WaitForChild("Core"):WaitForChild("Loader"))

Loader.Run({ script.Parent:WaitForChild("Controllers") })
