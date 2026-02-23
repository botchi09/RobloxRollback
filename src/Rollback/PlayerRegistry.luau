local PlayerRegistry = {}

local Players = game:GetService("Players")
local Framework = script.Parent
local Util = require(Framework.Util)

local maxPlayers: number = nil
local activePlayers = 0
local idMap = {} -- [playerId] = {entity = player/bot, isBot = boolean, isActive = boolean}

local function findEmptySpot()
	for k = 1, maxPlayers do
		if not idMap[k] then
			return k
		end
	end
end

local function assignId(entity:Player, isBot:boolean, forceKey:number)
	--Check player not already assigned
	for k = 1, maxPlayers do
		if idMap[k] and idMap[k].entity == entity then
			return k
		end
	end
	
	local key = forceKey or findEmptySpot()
	if not key then return nil end

	-- Store in registry with metadata
	idMap[key] = {
		entity = entity,
		isBot = isBot,
		isActive = true, -- New players/bots start active
		lastInput = {},
	}

	-- Set attribute/property on the entity
	if not isBot then
		entity:SetAttribute("PlayerId", key)
	else
		entity.playerId = key
	end

	activePlayers += 1
	return key
end

function PlayerRegistry.assignPlayerId(player:Player, forceId:number)
	return assignId(player, false, forceId)
end

function PlayerRegistry.assignBotId(bot, forceId:boolean)
	return assignId(bot, true, forceId)
end

function PlayerRegistry.removePlayerId(player)
	local playerId = player:GetAttribute("PlayerId")
	if playerId and idMap[playerId] then
		idMap[playerId] = nil
		player:SetAttribute("PlayerId", nil)
		activePlayers -= 1
	end
end

function PlayerRegistry.removeBotId(bot)
	local playerId = bot.playerId
	if playerId and idMap[playerId] then
		idMap[playerId] = nil
		bot.playerId = nil
		activePlayers -= 1
	end
end

function PlayerRegistry.getActivePlayers()
	return activePlayers
end

function PlayerRegistry.getPlayerId(entity)
	if typeof(entity) == "Instance" then
		return entity:GetAttribute("PlayerId") 
	else
		return entity.playerId --Bots
	end
end

function PlayerRegistry.getEntity(playerId)
	local entry = idMap[playerId]
	if not entry then
		--Fallback for not loaded TODO this is hacky sync
		for k, plr in ipairs(Players:GetPlayers()) do
			if plr:GetAttribute("PlayerId") == playerId then
				return plr
			end
		end
	end
	return entry and entry.entity
end

function PlayerRegistry.isBot(playerId)
	local entry = idMap[playerId]
	return entry and entry.isBot or false
end

-- New functions for active state management
function PlayerRegistry.setActive(playerId, active)
	local entry = idMap[playerId]
	if entry then
		entry.isActive = active
	end
end

function PlayerRegistry.isActive(playerId)
	local entry = idMap[playerId]
	return entry and entry.isActive or false
end

function PlayerRegistry.getAllActivePlayerIds()
	local activeIds = {}
	for playerId, entry in pairs(idMap) do
		if entry.isActive then
			table.insert(activeIds, playerId)
		end
	end
	return activeIds
end

function PlayerRegistry.getIdMap()
	return idMap
end

function PlayerRegistry.setIdMap(newIdMap)
	idMap = newIdMap
end

function PlayerRegistry.init(config)
	maxPlayers = config.maxPlayers
end

function PlayerRegistry.getFromId(playerId)
	return idMap[playerId]
end

return PlayerRegistry