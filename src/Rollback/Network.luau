local module = {}
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local types = require("./Types")
local Util = require("./Util")
local Config
local tickRate

local remoteFolder = script --No need for external access

function module.init(newConfig: types.map<string, any>)
	Config = newConfig
	tickRate = Config.tickRate
end

function module.getPing(): number
	local player = Players.LocalPlayer

	if RunService:IsStudio() and Config.debugLatencyS then
		return Config.debugLatencyS + Config.minPingMs / 1000
	end
	return player:GetNetworkPing()
end

function module.getPingFrames(): number
	local msPing = module.getPing() * 1000
	local pingFrames = Util.msToTicks(msPing, tickRate)
	return pingFrames
end

local function getRemote(name: string, reliable: boolean): RemoteEvent | UnreliableRemoteEvent
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

function module.getReliableRemote(name: string): RemoteEvent | UnreliableRemoteEvent
	return getRemote(name, true)
end

function module.getUnreliableRemote(name: string): RemoteEvent | UnreliableRemoteEvent
	return getRemote(name, false)
end

return module
