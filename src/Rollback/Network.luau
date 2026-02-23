local module = {}
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Util = require("./Util")
local Config
local tickRate

local remoteFolder = script --No need for external access

function module.init(newConfig)
	Config = newConfig
	tickRate = Config.tickRate
end

function module.getPing()
	local player = Players.LocalPlayer

	if RunService:IsStudio() and Config.debugLatencyS then
		return Config.debugLatencyS + Config.minPingMs/1000
	end
	return player:GetNetworkPing()
end

function module.getPingFrames()
	local msPing = module.getPing() * 1000
	local pingFrames = Util.msToTicks(msPing, tickRate)
	return pingFrames
end

local function getRemote(name, reliable)
	local class = "RemoteEvent"
	if not reliable then
		class = "UnreliableRemoteEvent"
	end
	if RunService:IsServer() then
		local remote = Instance.new(class)
		remote.Name = name
		remote.Parent = remoteFolder
		return remote
	else
		return remoteFolder:WaitForChild(name)
	end
end

function module.getReliableRemote(name)
	return getRemote(name, true)
end

function module.getUnreliableRemote(name)
	return getRemote(name, false)
end

return module