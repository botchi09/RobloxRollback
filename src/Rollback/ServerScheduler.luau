local module = {}

local Framework = script.Parent
local types = require("./Types")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Network = require("./Network")

local InputSync = Network.getUnreliableRemote("InputSync")
local InputSyncReliable = Network.getReliableRemote("InputSyncReliable")
local Resync = Network.getReliableRemote("Resync")
local ResyncInputs = Network.getReliableRemote("ResyncInputs")

local AssignPlayerId = Network.getReliableRemote("AssignPlayerId")

local Runner
local Shared = require(Framework.Shared)
local RingBuffer = require(Framework.RingBuffer)
local Util = require(Framework.Util)
local FrameTemplater = require(Framework.FrameTemplater)
local PlayerRegistry = require(Framework.PlayerRegistry)
local SimStatus = require(Framework.SimStatus)
local InputSerDes = require(Framework.InputSerDes)

--Static config
local storeResyncStateEvery = 60 * 10
local allowUnreliableQueue = true
local allowUnpredictedInputs = true

local minSendDelay
local maxSendDelay
local fullGameBufferSize

-- State variables (will be reset on init)
local serverFrame = 0
local inputBuffer
local worldStateBuffer
local worldState
local inputMergeQueue
local resyncQueue
local lastSaveFrame

-- Bot management
local bots = {} -- [botId] = bot object
local botInputGenerators = {} -- [botId] = function(worldState, playerId) -> inputs

-- Connection tracking
local connections = {}

local pendingIdSyncs = {}
function addPendingIdSync(addId: number)
	table.insert(pendingIdSyncs, addId)
end

local unreliableSendQueue = {}

-- Merge inputs from queue into inputBuffer
local function applyReceivedInputs()
	while #inputMergeQueue > 0 do
		local data = table.remove(inputMergeQueue)
		local mergeFrame = data.frame
		local mergeInputs = data.inputs
		local mergeOwner = data.owner

		local frameInputs = inputBuffer:getFrame(mergeFrame)
		if not frameInputs then
			frameInputs = {}
		end

		frameInputs[mergeOwner] = mergeInputs
		inputBuffer:setFrame(mergeFrame, frameInputs)
		if allowUnreliableQueue then
			table.insert(unreliableSendQueue, mergeFrame) --Push into the instant queue!
		end
	end
end
local function fillEmptyInputs(frame: number)
	local frameInputs = inputBuffer:getFrame(frame)
	if not frameInputs then
		frameInputs = {}
	end

	for playerId = 1, Runner.Config.maxPlayers do
		local playerData = PlayerRegistry.getFromId(playerId)

		local framePlayerInput = frameInputs[playerId]
		local wasCreated = false
		local playerSentInput = false
		if not framePlayerInput or playerSentInput then
			framePlayerInput = FrameTemplater.newPlayerInput(playerId)
			wasCreated = true
		end

		--Ensure all fields are filled in to prevent inconsistency. Inconsistency = serdes problems
		local template = FrameTemplater.newPlayerInput(playerId)
		for key, defaultValue in template do
			if framePlayerInput[key] == nil then
				--Try to use sticky input if available
				framePlayerInput[key] = defaultValue
			end
		end

		--Now, backfill from past inputs
		if allowUnpredictedInputs then
			if wasCreated and playerData then
				local lastInput = playerData.lastInput

				if lastInput then
					for key, value in framePlayerInput do
						local stickyInputs = Runner.Config.stickyInputs
						if stickyInputs and stickyInputs[key] then
							framePlayerInput[key] = lastInput[key]
						else
							framePlayerInput[key] = template[key]
						end
					end
				end
			end
		end
		frameInputs[playerId] = framePlayerInput
	end

	inputBuffer:setFrame(frame, frameInputs)
end

local function pushResync(player: Player, syncFromFrame: number?)
	local playerId = PlayerRegistry.getPlayerId(player)
	PlayerRegistry.setActive(playerId, false) --Don't send updates while we resync
	table.insert(resyncQueue, {
		player = player,
		scheduledFrame = serverFrame + maxSendDelay + 1,
		startFrame = (syncFromFrame or 1) - 1, --We increment later, so minus 1
	})
end

local function processResyncs()
	local targetSyncFrame = serverFrame - maxSendDelay

	for i = #resyncQueue, 1, -1 do
		local req = resyncQueue[i]

		local currentProgress = req.lastSentFrame or req.startFrame

		local framesRemaining = targetSyncFrame - currentProgress
		local batchSize: number = Shared.maxServerFrameBufferSize --TODO configify?

		local sendCount = math.clamp(framesRemaining, 0, batchSize)

		if sendCount > 0 then
			local batchTargetFrame = currentProgress + sendCount
			local isLast = batchTargetFrame >= targetSyncFrame

			if req.lastSentFrame == nil then
				print("Begin resync: Sending State Snapshot at", req.startFrame)
				local stateAtFrame = worldStateBuffer:getFrame(req.startFrame)
				Resync:FireClient(req.player, req.startFrame, stateAtFrame)
				req.packetIndex = 0
			end

			local multiFrameInputs = {}

			for k = 0, sendCount - 1 do
				local sendFrame = batchTargetFrame - k

				local sendFrameInputs = inputBuffer:getFrame(sendFrame)
				if not sendFrameInputs then
					sendFrameInputs = FrameTemplater.newInputFrame()
				end

				local restructured = InputSerDes.serializeFrameInputs(sendFrameInputs)
				table.insert(multiFrameInputs, restructured)
			end

			print("Resync Batch:", batchTargetFrame, "->", batchTargetFrame - (sendCount - 1), "| IsLast:", isLast)

			req.packetIndex += 1
			local lastVal = req.packetIndex
			if isLast then
				lastVal = true
			end
			ResyncInputs:FireClient(req.player, batchTargetFrame, multiFrameInputs, lastVal)

			req.lastSentFrame = batchTargetFrame

			if isLast then
				table.remove(resyncQueue, i)
				local playerId = PlayerRegistry.getPlayerId(req.player)
				PlayerRegistry.setActive(playerId, true)
				print("Resync finished for", req.player)
			end
		end
	end
end

function resetPlayerId(playerId: number)
	--World state reset
	if Runner.resetPlayerId then
		Runner.resetPlayerId(playerId)
		return
	end
end

local queuedDisconnects = {}

function module.removePlayerId(playerId: number)
	table.insert(queuedDisconnects, playerId)
end

function module.removePlayer(player: Player)
	print("Removed player", player)
	local playerId = PlayerRegistry.getPlayerId(player)
	PlayerRegistry.removePlayerId(player)
	--Force playerId to have connected input set to false
	if playerId then
		module.removePlayerId(playerId)
	end
end

-- Bot management functions
function module.addBot(bot: any, inputGenerator: types.func?): number?
	local botId = PlayerRegistry.assignBotId(bot)
	if not botId then
		warn("Failed to add bot - no available slots")
		return nil
	end
	addPendingIdSync(botId)
	bots[botId] = bot
	botInputGenerators[botId] = inputGenerator

	print("Added bot with ID", botId)
	return botId
end

function module.removeBot(bot: { playerId: number? })
	local botId = bot.playerId
	if not botId then
		return
	end

	print("Removed bot", botId)
	PlayerRegistry.removeBotId(bot)
	bots[botId] = nil
	botInputGenerators[botId] = nil

	-- Queue disconnect
	table.insert(queuedDisconnects, botId)
end

-- Generate inputs for all bots
local function generateBotInputs(frame: number)
	for botId, bot in bots do
		local generator = botInputGenerators[botId]
		if generator then
			local botInputs = generator(frame, worldState, inputBuffer, botId)
			if botInputs then
				botInputs.Connected = true
				--Fill in the empty bot inputs for consistency
				for k, v in FrameTemplater.getPlayerInputTemplate() do
					if botInputs[k] == nil then
						botInputs[k] = v
					end
				end

				table.insert(inputMergeQueue, {
					owner = botId,
					frame = frame,
					inputs = botInputs,
				})
			end
		end
	end
end

function module.init(newRunner: types.map<string, any>)
	Runner = newRunner
	if not Runner then
		error("Runner not passed to ServerScheduler")
	end
	if Runner.InputSerDes then
		InputSerDes = Runner.InputSerDes
	end
	Shared.init(Runner)

	--config constants
	maxSendDelay = Shared.maxServerFrameBufferSize
	fullGameBufferSize = Runner.Config.fullGameBufferSize
	minSendDelay = Shared.minServerFrameBufferSize
end

local function sendFrameToPlayers(frame: number, isReliable: boolean)
	local frameInputs = InputSerDes.serializeFrameInputs(inputBuffer:getFrame(frame))

	local multiFrameInputs
	local packetsToSend = Runner.Config.reliableBufferSize
	if frame % packetsToSend == 0 then
		--Build multi frame from past inputs
		multiFrameInputs = { frameInputs }
		-- Add buffer frames
		for i = 1, packetsToSend - 1 do
			local extraSendFrame = frame - i
			local sendFrameInputs = inputBuffer:getFrame(extraSendFrame)
			local restructured = InputSerDes.serializeFrameInputs(sendFrameInputs)
			table.insert(multiFrameInputs, restructured)
		end
		--Send pending ID syncs
		if #pendingIdSyncs > 0 then
			AssignPlayerId:FireAllClients(PlayerRegistry.getIdMap())
			pendingIdSyncs = {} --TODO maybe do something with this?
		end
	end

	for _, player in Players:GetPlayers() do
		local playerId = PlayerRegistry.getPlayerId(player)
		if not playerId or not PlayerRegistry.isActive(playerId) then
			continue
		end
		if isReliable then
			if multiFrameInputs then
				InputSyncReliable:FireClient(player, frame, multiFrameInputs)
			end
		else
			InputSync:FireClient(player, frame, frameInputs)
		end
	end
end

local function setServerAuthInput(frame: number)
	local frameInputs = inputBuffer:getFrame(frame)

	if not frameInputs then
		frameInputs = FrameTemplater.newInputFrame()
	end

	for playerId = 1, Runner.Config.maxPlayers do
		if PlayerRegistry.getEntity(playerId) then
			local playerInput = frameInputs[playerId]

			if not playerInput then
				playerInput = FrameTemplater.newPlayerInput(playerId)
				frameInputs[playerId] = playerInput
			end

			playerInput.Connected = true
			local getFunc = Runner.getServerInputs
			local entity = PlayerRegistry.getEntity(playerId)
			--Bots are table represented and get server inputs differently
			if getFunc and entity and not PlayerRegistry.isBot(playerId) then
				local authInputs = getFunc(entity)
				for key, value in authInputs do
					playerInput[key] = value
				end
			end
		end
	end

	inputBuffer:setFrame(frame, frameInputs)
end

function setupFrame(frame: number)
	-- Inject Connected = true for all active players on this frame
	setServerAuthInput(frame)

	--Ensure frame inputs are filled and missing no frames
	fillEmptyInputs(frame)
end

function processUnreliableQueue(newestAllowedFrame: number, oldestAllowedFrame: number): types.list<number>
	local sentFrames = {}
	local sentFramesNumeric = {}

	for i = #unreliableSendQueue, 1, -1 do
		local frame = unreliableSendQueue[i]
		local frameExpired = frame < oldestAllowedFrame
		local frameTooEarly = frame > newestAllowedFrame

		--Only send if frame is within valid window and not already sent
		if not frameTooEarly and not frameExpired then
			if not sentFrames[frame] then
				sendFrameToPlayers(frame, false)
				sentFrames[frame] = true
				table.insert(sentFramesNumeric, frame)
			end
			table.remove(unreliableSendQueue, i)
		elseif frameTooEarly then
			--Too new, ignore for later
		elseif frameExpired then
			--Too old, remove, let reliable do it

			table.remove(unreliableSendQueue, i)
		end
	end
	return sentFramesNumeric
end

function serverUpdate()
	serverFrame += 1
	if serverFrame > fullGameBufferSize then
		warn("Exceeded the full game buffer size. Don't let this happen.")
	end

	local oldestAllowedFrame = serverFrame - maxSendDelay
	local newestAllowedFrame = serverFrame - minSendDelay

	-- Handle disconnects
	while #queuedDisconnects > 0 do
		print("Disconnects", queuedDisconnects)
		local playerId = table.remove(queuedDisconnects)
		local maxArrival = inputBuffer:getFrame(oldestAllowedFrame)
		if maxArrival and playerId and maxArrival[playerId] then --TODO playerId can be nil?
			maxArrival[playerId].Connected = false
		end
		print("Disconnect", playerId)
		resetPlayerId(playerId)
	end

	-- Generate bot inputs for the current frame
	generateBotInputs(serverFrame)

	-- Merge queued inputs into buffer
	applyReceivedInputs()

	--Guarantees sync, overrides player inputs
	setupFrame(oldestAllowedFrame)
	sendFrameToPlayers(oldestAllowedFrame, true)

	--TODO reenable + debug
	if allowUnreliableQueue then
		local sentFrames = processUnreliableQueue(newestAllowedFrame, oldestAllowedFrame)
		if #sentFrames > 0 then
			--print("SENT", sentFrames)
		end
	end
	--Debug print frames
	local inputs = inputBuffer:getFrame(oldestAllowedFrame)
	--print(syncFrame, inputs[1].Move)

	worldState = Runner.simulate(oldestAllowedFrame, worldState, inputBuffer, SimStatus.Simulating)
	worldStateBuffer:setFrame(oldestAllowedFrame, worldState, true)
	lastSaveFrame = oldestAllowedFrame
	processResyncs()
end

function clientFrameReceived(player: Player, clientFrame: number, clientInputSerialized: buffer)
	if not clientFrame or not clientInputSerialized then
		return
	end
	local clientInputs = InputSerDes.deserializePlayerInputs(clientInputSerialized)

	--Disconnects are handled in a special way (even delayed, remove them from the active players)
	if clientInputs.Connected == false then
		--TODO callback
		warn("No disconnect callback for server")
		return --Will be momentarily wrong, but the recieving player has DCed so desyncs don't matter
	end

	--Reject! Invalid frame that will pollute state
	if clientFrame > fullGameBufferSize then
		return
	end

	local maxSendFrame = serverFrame - maxSendDelay --Compensated for the buffer (send > receive)

	local playerId = PlayerRegistry.getPlayerId(player)
	if not playerId then
		return
	end
	local playerData = PlayerRegistry.getFromId(playerId)

	--TODO we are having some kind of desync here...
	--Too old, reject from unreliable queue but insert their desired inputs for no predict execution
	if clientFrame <= maxSendFrame then
		playerData.lastInput = clientInputs
		print("Old input, rejected", clientFrame, maxSendFrame, maxSendDelay)
		return
	end

	--TODO deprecated?? maybe used for checking if we have a frame
	playerData.lastConfirmedFrame = math.max(clientFrame, playerData.lastConfirmedFrame or 0)

	table.insert(inputMergeQueue, {
		owner = playerId,
		frame = clientFrame,
		inputs = clientInputs,
	})
end

function module:start(port: number)
	inputBuffer = RingBuffer.new(fullGameBufferSize)
	worldStateBuffer = RingBuffer.new(fullGameBufferSize)
	worldState = FrameTemplater.newWorldStateFrame()

	--Always have a valid saved frame
	worldStateBuffer:setFrame(1, worldState, true)
	lastSaveFrame = 1

	inputMergeQueue = {}
	resyncQueue = {}
	serverFrame = maxSendDelay
	bots = {}
	botInputGenerators = {}

	-- Connect events
	table.insert(connections, InputSync.OnServerEvent:Connect(clientFrameReceived))
	table.insert(connections, InputSyncReliable.OnServerEvent:Connect(clientFrameReceived))

	--Usually called on player join
	table.insert(
		connections,
		Resync.OnServerEvent:Connect(function(player, syncFromFrame: number?, port: number)
			local playerId = PlayerRegistry.assignPlayerId(player)
			print("Assigned player ID", playerId, PlayerRegistry.getIdMap())
			--All players must know of new ID map on join
			addPendingIdSync(playerId)
			syncFromFrame = syncFromFrame or lastSaveFrame
			pushResync(player, syncFromFrame)
		end)
	)

	local tickRate = Runner.Config.tickRate
	local frameAccumulator = 0

	table.insert(
		connections,
		RunService.PostSimulation:Connect(function(deltaTime)
			frameAccumulator += deltaTime
			while frameAccumulator > tickRate do
				frameAccumulator -= tickRate
				serverUpdate()
			end
		end)
	)
end

function module:stop()
	-- Disconnect all events
	for _, conn in connections do
		conn:Disconnect()
	end
	connections = {}

	-- Clear state
	inputBuffer = nil
	worldStateBuffer = nil
	worldState = nil
	inputMergeQueue = nil
	resyncQueue = nil
	serverFrame = nil
	bots = {}
	botInputGenerators = {}
end

return module
