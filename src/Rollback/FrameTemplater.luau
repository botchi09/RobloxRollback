local FrameTemplater = {}
local Framework = script.Parent
local Util = require(Framework.Util)

local config = nil
local inputTemplate = nil
local worldStateTemplate = nil
local playerInputTemplate = nil

function FrameTemplater.newPlayerInput(playerId)
	--TODO imp sticky inputs!
	if not config then
		error("FrameTemplater not initialized. Call FrameTemplater.init(config) first.")
	end
	return Util.deepCopy(playerInputTemplate)
end

function FrameTemplater.newInputFrame()
	if not config then
		error("FrameTemplater not initialized. Call FrameTemplater.init(config) first.")
	end
	return Util.deepCopy(inputTemplate)
end

function FrameTemplater.getInputFrameTemplate()
	return inputTemplate
end

function FrameTemplater.getPlayerInputTemplate()
	return playerInputTemplate
end

function FrameTemplater.newWorldStateFrame()
	if not config then
		error("FrameTemplater not initialized. Call FrameTemplater.init(config) first.")
	end
	return Util.deepCopy(worldStateTemplate)
end

function FrameTemplater.init(newConfig)
	config = newConfig
	playerInputTemplate = config.playerInputTemplate
	worldStateTemplate = config.playerWorldStateTemplate

	inputTemplate = {}
	for i = 1, config.maxPlayers do
		inputTemplate[i] = FrameTemplater.newPlayerInput(i)
	end
end

return FrameTemplater