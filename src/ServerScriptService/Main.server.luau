--!strict
-- Server entry (single-script architecture): the only server Script. Every service in
-- ServerScriptService.Services runs through Core/Loader (Init in priority order, then Start).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Core.Loader)

Loader.Run({ script.Parent.Services })
