local FrameTemplater = {}
local Framework = script.Parent
local types = require("./Types")
local Util = require(Framework.Util)

local config = nil
local inputTemplate = nil
local worldStateTemplate = nil
local playerInputTemplate = nil

function FrameTemplater.newPlayerInput(playerId:number?): types.map<string, any>
	--TODO imp sticky inputs!
	if not config then
		error("FrameTemplater not initialized. Call FrameTemplater.init(config) first.")
	end
	return Util.deepCopy(playerInputTemplate)
end

function FrameTemplater.newInputFrame(): types.map<number, types.map<string, any>>
	if not config then
		error("FrameTemplater not initialized. Call FrameTemplater.init(config) first.")
	end
	return Util.deepCopy(inputTemplate)
end

function FrameTemplater.getInputFrameTemplate(): types.map<number, types.map<string, any>>
	return inputTemplate
end

function FrameTemplater.getPlayerInputTemplate(): types.map<string, any>
	return playerInputTemplate
end

function FrameTemplater.newWorldStateFrame(): types.map<string, any>
	if not config then
		error("FrameTemplater not initialized. Call FrameTemplater.init(config) first.")
	end
	return Util.deepCopy(worldStateTemplate)
end

function FrameTemplater.init(newConfig: types.map<string, any>)
	config = newConfig
	playerInputTemplate = config.playerInputTemplate
	worldStateTemplate = config.playerWorldStateTemplate

	inputTemplate = {}
	for i = 1, config.maxPlayers do
		inputTemplate[i] = FrameTemplater.newPlayerInput(i)
	end
end

return FrameTemplater