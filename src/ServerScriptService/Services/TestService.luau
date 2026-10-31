--!strict
-- Runs every *.spec ModuleScript under ServerScriptService.Tests after the game has started.
-- Studio only; does nothing in live servers.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TestService = { Priority = 1000 }

function TestService.Start(_self : any)
	if not RunService:IsStudio() then
		return
	end
	local TestKit = require(ReplicatedStorage.Core.TestKit)
	TestKit.Report(TestKit.RunIn(ServerScriptService.Tests))
end

return TestService
