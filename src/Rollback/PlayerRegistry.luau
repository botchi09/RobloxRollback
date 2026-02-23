local PlayerRegistry = {}

local Players = game:GetService("Players")
local Framework = script.Parent
local types = require("./Types")
local Util = require(Framework.Util)

type BotEntity = { playerId: number? }
type RegistryEntry = {
	entity: Player | BotEntity,
	isBot: boolean,
	isActive: boolean,
	lastInput: types.map<string, any>?,
	lastConfirmedFrame: number?,
}
type RegistryMap = types.map<number, RegistryEntry>

local maxPlayers: number = nil
local activePlayers = 0
local idMap: RegistryMap = {} -- [playerId] = {entity = player/bot, isBot = boolean, isActive = boolean}

local function findEmptySpot(): number?
	for k = 1, maxPlayers do
		if not idMap[k] then
			return k
		end
	end
	return nil
end

local function assignId(entity: Player | BotEntity, isBot: boolean, forceKey: number?): number?
	--Check player not already assigned
	for k = 1, maxPlayers do
		if idMap[k] and idMap[k].entity == entity then
			return k
		end
	end

	local key = forceKey or findEmptySpot()
	if not key then
		return nil
	end

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

function PlayerRegistry.assignPlayerId(player: Player, forceId: number?): number?
	return assignId(player, false, forceId)
end

function PlayerRegistry.assignBotId(bot: BotEntity, forceId: number?): number?
	return assignId(bot, true, forceId)
end

function PlayerRegistry.removePlayerId(player: Player)
	local playerId = player:GetAttribute("PlayerId")
	if playerId and idMap[playerId] then
		idMap[playerId] = nil
		player:SetAttribute("PlayerId", nil)
		activePlayers -= 1
	end
end

function PlayerRegistry.removeBotId(bot: BotEntity)
	local playerId = bot.playerId
	if playerId and idMap[playerId] then
		idMap[playerId] = nil
		bot.playerId = nil
		activePlayers -= 1
	end
end

function PlayerRegistry.getActivePlayers(): number
	return activePlayers
end

function PlayerRegistry.getPlayerId(entity: Player | BotEntity): number?
	if typeof(entity) == "Instance" then
		return entity:GetAttribute("PlayerId")
	else
		return entity.playerId --Bots
	end
end

function PlayerRegistry.getEntity(playerId: number): Player | BotEntity?
	local entry = idMap[playerId]
	if not entry then
		--Fallback for not loaded TODO this is hacky sync
		for k, plr in Players:GetPlayers() do
			if plr:GetAttribute("PlayerId") == playerId then
				return plr
			end
		end
	end
	return entry and entry.entity
end

function PlayerRegistry.isBot(playerId: number): boolean
	local entry = idMap[playerId]
	return entry and entry.isBot or false
end

-- New functions for active state management
function PlayerRegistry.setActive(playerId: number, active: boolean)
	local entry = idMap[playerId]
	if entry then
		entry.isActive = active
	end
end

function PlayerRegistry.isActive(playerId: number): boolean
	local entry = idMap[playerId]
	return entry and entry.isActive or false
end

function PlayerRegistry.getAllActivePlayerIds(): types.list<number>
	local activeIds: types.list<number> = {}
	for playerId, entry in idMap do
		if entry.isActive then
			table.insert(activeIds, playerId)
		end
	end
	return activeIds
end

function PlayerRegistry.getIdMap(): RegistryMap
	return idMap
end

function PlayerRegistry.setIdMap(newIdMap: RegistryMap)
	idMap = newIdMap
end

function PlayerRegistry.init(config: types.map<string, any>)
	maxPlayers = config.maxPlayers
end

function PlayerRegistry.getFromId(playerId: number): RegistryEntry?
	return idMap[playerId]
end

return PlayerRegistry
