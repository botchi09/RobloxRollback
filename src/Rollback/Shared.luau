local Shared = {}
local Framework = script.Parent
local PlayerRegistry = require(Framework.PlayerRegistry)
local FrameTemplater = require(Framework.FrameTemplater)
local Util = require(Framework.Util)
local Runner

Shared.maxServerFrameBufferSize = nil

function Shared.init(newRunner)
	Runner = newRunner
	

	local bufferOverheadMs = Util.getBufferOverheadMs()
	local minIncomingLagMs = Runner.Config.minPingMs --Don't add buffer here
	local tickRate = Runner.Config.tickRate
	local minIncomingLagFrames = Util.msToTicks(minIncomingLagMs, tickRate)
	local maxIncomingLagFrames = Util.msToTicks(Runner.Config.maxPingMs+bufferOverheadMs, tickRate)
	--Send delay for collating all input from clients.
	--Reject input outside this window.
	Shared.maxServerFrameBufferSize = maxIncomingLagFrames
	Shared.minServerFrameBufferSize = minIncomingLagFrames
	
	PlayerRegistry.init(Runner.Config)
	FrameTemplater.init(Runner.Config)
	
	print("CONFIG", minIncomingLagMs, minIncomingLagFrames, "of max incoming lag")
end


return Shared
