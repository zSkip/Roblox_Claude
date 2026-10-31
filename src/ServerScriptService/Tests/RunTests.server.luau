--!strict
-- Runs every *.spec ModuleScript under this folder when you press Play in Studio.
-- Does nothing in live servers.

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local TestKit = require(game:GetService("ReplicatedStorage"):WaitForChild("TestKit"))

TestKit.Report(TestKit.RunIn(script.Parent))
