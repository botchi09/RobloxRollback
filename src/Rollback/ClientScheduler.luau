local module = {}
local Framework = script.Parent
local types = require("./Types")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Network = require(Framework.Network)

local InputSync = Network.getUnreliableRemote("InputSync")
local InputSyncReliable = Network.getReliableRemote("InputSyncReliable")
local AssignPlayerId = Network.getReliableRemote("AssignPlayerId")

local Resync = Network.getReliableRemote("Resync") --Initial resync request
local ResyncInputs = Network.getReliableRemote("ResyncInputs") --Follow up packets

local Runner
local Shared = require(Framework.Shared)
local RingBuffer = require(Framework.RingBuffer)
local Util = require(Framework.Util)
local FrameTemplater = require(Framework.FrameTemplater)
local InputSerDes = require(Framework.InputSerDes)

local PlayerRegistry = require(Framework.PlayerRegistry)
local SimStatus = require(Framework.SimStatus)

local LocalPlayer = Players.LocalPlayer

local port = 1 --TODO! Needs to be an arg in start! Fire resync!

-- Constants
local maxCatchupFrames = 10
local perPlayerPredictions = true --TODO fix true value

-- State variables (will be reset on init)
local targetAdvantage: number
local maxRollbackFrames: number
local clientFrameBufferSize: number
local maxFrameAdvantage: number

local localFrame: number
local remoteFrame: number
local localStaticFrame: number

local syncFrame
local remoteFrameAdvantage
local restoreFrame
local active
local worldState
local clientSimStatus

local inputBuffer
local worldStateBuffer
local receivedBuffer

local inputMergeQueue
local predictFromFrame: number
local riftCorrection
local frameAccumulator
local simLocked

local worldStateSynced = false
local pendingLivePackets = {}
local isResyncing = false

--TODO checkpointing
local checkpointFrame = 0
function getWorldState(frame: number, deepCopy: boolean?): any
	return worldStateBuffer:getFrame(frame, deepCopy)
end

--Always deepcopy
function setWorldState(frame: number, worldState: any)
	worldStateBuffer:setFrame(frame, worldState, true)
end

function checkpointWorldState(frame: number, worldState: any)
	checkpointFrame = frame
	--worldStateBuffer:setFrame(frame, worldState, true)
end

-- Connection tracking
local connections = {}

local function renderWithFunction(renderFuncName, displayFrame)
	local currentWorldState = getWorldState(displayFrame, false)
	local renderFunc = Runner[renderFuncName]
	if renderFunc then
		renderFunc(displayFrame, currentWorldState, inputBuffer, clientSimStatus)
	end
end

local function getDisplayFrame()
	local inputDelayFrames = Runner.Config.inputDelayFrames or 3

	return localFrame - inputDelayFrames
end

local function renderPostFrame()
	renderWithFunction("frameRender", getDisplayFrame())
end

local function renderPostSim()
	renderWithFunction("postSimRender", getDisplayFrame())
end

local function renderAlwaysSim()
	renderWithFunction("simRender", getDisplayFrame())
end

function createLocalPlayerInputs(localId: number, worldState: any?): types.map<string, any>?
	local emptyInput = FrameTemplater.newPlayerInput(localId)
	local inputs = Runner.getLocalPlayerInputs(emptyInput, worldState)
	return inputs
end

function reliableFrameReceived(frame: number)
	local oldRemoteFrame = remoteFrame
	--Frame is verified, and becomes the new remote authority
	remoteFrame = math.max(frame, remoteFrame)

	local localAdvantage = remoteFrame - localFrame
	local frameDifference = remoteFrame - oldRemoteFrame
	if frameDifference == 0 then --No compensation for out of order frames
		return
	end

	local ping = frameDifference * Runner.Config.tickRate

	--print("Ping", frameDifference, math.floor(ping*1000), frame)
	--targetAdvantage = math.max(0, frameDifference) --TODO this just does not  work
	local overheadMs = Util.getBufferOverheadMs()
	local overheadFrames = Util.msToTicks(overheadMs, Runner.Config.tickRate)
	targetAdvantage = (Network.getPingFrames() * 2) + overheadFrames
end

function isAllInputs(receivedList: types.list<number>?): boolean
	return receivedList and #receivedList == Runner.Config.maxPlayers
end

function addVerifiedInputs(frame: number, receivedList: types.list<number>): boolean?
	local existing = receivedBuffer:getFrame(frame)
	if not existing then
		existing = {}
	end

	local wasVerified = isAllInputs(existing)
	if wasVerified then
		return true
	end --Already checked

	local lookup = {}
	for _, playerId in existing do
		lookup[playerId] = true
	end

	for _, playerId in receivedList do
		if not lookup[playerId] then
			table.insert(existing, playerId)
			lookup[playerId] = true
		end

		local newestFrame = math.max(latestReceivedPacket[playerId] or 0, frame)

		latestReceivedPacket[playerId] = newestFrame
	end

	receivedBuffer:setFrame(frame, existing)
	if not wasVerified and isAllInputs(existing) then
		reliableFrameReceived(frame)

		return true
	end

	return false
end

local function serverFramesReceived(newServerFrame: number, serverInputs: types.list<any>, isSync: boolean)
	if newServerFrame > localFrame then
		--print("Server ahead of client")
	end

	for i = #serverInputs, 1, -1 do
		local newInputs, receivedList = InputSerDes.deserializeFrameInputs(serverInputs[i])
		--Does not use remoteFrame for correct time
		local serverFrame = newServerFrame - (i - 1)

		local verified = addVerifiedInputs(serverFrame, receivedList)
		table.insert(inputMergeQueue, { frame = serverFrame, inputs = newInputs })
	end
end

function isInputVerified(frame: number, playerId: number): boolean
	local existing = receivedBuffer:getFrame(frame)

	if not existing then
		return false
	end

	for _, id in existing do
		if id == playerId then
			return true
		end
	end

	return false
end

function getUnverifiedPlayers(frame: number): types.set<number>
	local verifiedList = receivedBuffer:getFrame(frame) or {}
	local unverified = {}

	local isVerified = {}
	for _, id in verifiedList do
		isVerified[id] = true
	end

	for i = 1, Runner.Config.maxPlayers do
		if not isVerified[i] then
			unverified[i] = true
		end
	end

	return unverified
end

function inputsEqual(i1: any, i2: any, excludeIds: types.set<number>?): boolean
	if Runner.inputsEqual then
		return Runner.inputsEqual(i1, i2, excludeIds)
	end

	if i1 == i2 then
		return true
	end
	if (i1 == nil) ~= (i2 == nil) then
		return false
	end

	i1 = i1 or {}
	i2 = i2 or {}
	excludeIds = excludeIds or {}

	for userId, input1 in i1 do
		if excludeIds[userId] then
			continue
		end

		local input2 = i2[userId]
		if not input2 then
			return false
		end

		for inputName, inputValue in input1 do
			if input2[inputName] ~= inputValue then
				return false
			end
		end
	end

	for userId, _ in i2 do
		if excludeIds[userId] then
			continue
		end
		if i1[userId] == nil then
			return false
		end
	end

	return true
end

local function mergeServerInputs(testMispredict: boolean?): number?
	local mispredictFrame = nil
	while #inputMergeQueue > 0 do
		local data = table.remove(inputMergeQueue)

		local mergeFrame = data.frame
		local mergeInputs = data.inputs
		local receivedInputs = receivedBuffer:getFrame(mergeFrame)
		local isReliable = isAllInputs(receivedInputs)

		local frameInputs = inputBuffer:getFrame(mergeFrame, true)

		if not frameInputs then
			frameInputs = {}
		end

		local frameInputsReliable = isAllInputs(frameInputs)
		if frameInputsReliable and not isReliable then
			continue --Never merge unreliable packets over reliable ones
		end
		local localId = PlayerRegistry.getPlayerId(LocalPlayer)
		local frameTemplate = FrameTemplater.getInputFrameTemplate()

		--Force fill missing inputs (may happen accessing uninitialized frame?)
		for k, v in frameTemplate do
			if not frameInputs[k] then
				--warn("Incomplete frame for", k, v)
				--print("Ref frame", frameInputs[k])
				frameInputs[k] = v
			end
		end

		local excludeIds = {}

		if not isReliable then
			excludeIds[localId] = true
			for i = 1, Runner.Config.maxPlayers do
				--if not frameInputs[i] or not frameInputs[i].Connected then
				if not table.find(receivedInputs, i) then
					excludeIds[i] = true
				end
			end
		end

		if testMispredict then
			--print("BOTINPUT", frameInputs[2].Connected, mergeInputs[2].Connected)
			if not inputsEqual(frameInputs, mergeInputs, excludeIds) then
				mispredictFrame = math.min(mispredictFrame or mergeFrame, mergeFrame)
				--Can fire if too old too
				--print("MISPREDICT", mispredictFrame,mergeInputs[1].Class,frameInputs, mergeInputs)
			end
		end

		inputBuffer:setFrame(mergeFrame, mergeInputs)

		--Unreliable frames do not have prediction authority
		if isReliable then --TODO but... we need it for smoothness
			predictFromFrame = math.max(predictFromFrame, mergeFrame)
		end
	end

	return mispredictFrame
end

function processPendingPackets(forceAll: boolean?)
	local processLimit = 1 --We receive them in subpackets of about 4
	local currentProcessed = 0
	while #pendingLivePackets > 0 and (currentProcessed < processLimit or forceAll) do
		currentProcessed += 1
		--If we don't remove in sequence we might skip local frame ahead too far
		local packet = table.remove(pendingLivePackets)
		serverFramesReceived(packet.frame, packet.inputs, packet.sync)
	end
end

local resyncQueue = {}
local lastResyncPacketIndex = 0

function resizeBuffersToNormal()
	worldStateBuffer:resize(clientFrameBufferSize)
	print("New world state buffer size", worldStateBuffer)
end

local function processResyncQueue()
	if #resyncQueue == 0 or not worldStateSynced then
		return
	end

	clientSimStatus = SimStatus.Syncing

	table.sort(resyncQueue, function(a, b)
		return a.startFrame < b.startFrame
	end)

	local nextBatch = resyncQueue[1]

	local isFinished = nextBatch.packetIndex == true
	local newPacketIndex = nextBatch.packetIndex
	if isFinished then
		newPacketIndex = lastResyncPacketIndex + 1 --Easy fix for comparison
	end

	if lastResyncPacketIndex >= newPacketIndex then
		error("Expected packet index > " .. lastResyncPacketIndex .. ", got " .. newPacketIndex)
	end

	nextBatch = table.remove(resyncQueue, 1) --Expensive but only on resync

	local startFrame = nextBatch.startFrame
	local newFrames = nextBatch.newFrames

	serverFramesReceived(startFrame, newFrames, true)

	--Manually resim here, as we might receive more than our ring buffer can hold
	for i = #newFrames, 1, -1 do
		local actualFrame = startFrame - (i - 1)

		-- Double check we aren't skipping or overwriting (sanity check)
		if actualFrame ~= localFrame + 1 then
			warn("Resync Logic Error: Frame discontinuity detected internally")
		end

		local reverseIndex = #newFrames - i + 1
		local structuredSimInputs = newFrames[reverseIndex]
		local simInputs = InputSerDes.deserializeFrameInputs(structuredSimInputs)
		--Adjust input buffer
		inputBuffer:setFrame(actualFrame, simInputs)

		worldState = Runner.simulate(actualFrame, worldState, inputBuffer, SimStatus.Syncing)

		-- Save to the correct slot in history
		setWorldState(actualFrame, worldState)

		-- Update the local clock
		localFrame = actualFrame
	end

	mergeServerInputs(false) --Merge and clear input queue after

	--Just for nonessential visuals while resyncing
	renderPostFrame()

	if isFinished then
		print("Resync done! Current Frame:", localFrame)
		local firstPacket = pendingLivePackets[1]

		if firstPacket then
			local targetFrame = firstPacket.frame - 1
			localFrame = targetFrame --Force us to sync from here
			syncFrame = targetFrame
			worldState = getWorldState(syncFrame, true)
			print("Pending packets", #pendingLivePackets, "from frame", targetFrame)

			resizeBuffersToNormal()

			--Set verify buffer
			local verified = {}
			for i = 1, Runner.Config.maxPlayers do
				table.insert(verified, i)
			end
			addVerifiedInputs(syncFrame, verified) --World state is reliable for this frame
		end
		table.sort(pendingLivePackets, function(a, b)
			return a.frame < b.frame --TODO is this needed?
		end)

		isResyncing = false
		active = true
		resyncQueue = {} -- Clear queue to be safe
	end

	return true -- signal we did work
end

local function rollbackCondition()
	return localFrame > syncFrame and remoteFrame > syncFrame
end

function timeSynced(): boolean
	--Compare last known frame advantages
	local localFrameAdvantage = localFrame - remoteFrame

	return localFrameAdvantage < maxFrameAdvantage
end

local function fireResync(frame: number?)
	print("Resync started...")
	active = false
	isResyncing = true
	RunService.Heartbeat:Wait() --Force yield until no active thread
	pendingLivePackets = {}
	resyncQueue = {}

	local fullBufferSize = Runner.Config.fullGameBufferSize
	worldStateSynced = false
	inputBuffer = RingBuffer.new(fullBufferSize)
	latestReceivedPacket = {} --Reset latest packets
	--Prevent nil indices
	inputBuffer:fillFrames(FrameTemplater.newInputFrame(), clientFrameBufferSize)
	worldStateBuffer = RingBuffer.new(fullBufferSize)
	receivedBuffer = RingBuffer.new(fullBufferSize)

	Resync:FireServer(frame, port)
end

function resimulateFrames(startFrame: number, stopFrame: number): any
	local rollbackState = getWorldState(startFrame, true)
	for frame = startFrame + 1, stopFrame do
		local frameInputs = inputBuffer:getFrame(frame, false)
		rollbackState = Runner.simulate(frame, rollbackState, inputBuffer, SimStatus.Resimulating)
		renderAlwaysSim()
		setWorldState(frame, rollbackState)
	end

	return rollbackState
end

local function clientUpdate()
	debug.profilebegin("clientupdate")

	local mispredictFrame = mergeServerInputs(true)

	local debugForceRollbackFrames = Runner.Config.debugForceRollbackFrames
	if debugForceRollbackFrames and not mispredictFrame then --Use earliest
		mispredictFrame = localFrame - debugForceRollbackFrames
	end

	if mispredictFrame then
		syncFrame = mispredictFrame - 1
	else
		syncFrame = math.min(remoteFrame, localFrame)
	end

	local doRollback = (rollbackCondition() and mispredictFrame) or debugForceRollbackFrames

	if doRollback then
		if Runner.onRollback then
			Runner.onRollback(syncFrame, worldStateBuffer, inputBuffer)
		end
		debug.profilebegin("Rollback_resim")

		--TODO this is happening even if localframe behind remoteframe?
		clientSimStatus = SimStatus.Resimulating

		local rollbackState = resimulateFrames(syncFrame, localFrame)
		worldState = rollbackState

		debug.profileend()
	end

	if not timeSynced() then
		return
	end

	localFrame += 1

	--Ensure consistency of inputs. TODO force full resync
	if receivedBuffer then
		local verifyFrame = localFrame - clientFrameBufferSize
		local debugForceResync = false --localFrame % 300 == 0 --TODO very buggy. Re-adds clients.
		local isVerified = isAllInputs(receivedBuffer:getFrame(verifyFrame))

		if localFrame > clientFrameBufferSize and not isVerified or debugForceResync then
			print("Missing frame", verifyFrame)
			fireResync(verifyFrame - 1)
			return
		end
	end

	local localId = PlayerRegistry.getPlayerId(LocalPlayer)
	local localPlayerLoaded = localId ~= nil

	local localInputs --This is sent to server

	local currentInputFrame --This is recorded
	local isRemoteAhead = remoteFrame > localFrame
	local isLocalAhead = not isRemoteAhead --Equal to or ahead of remote

	--We depend on being ahead of the server for local inputs to have authority
	if isLocalAhead then
		localInputs = createLocalPlayerInputs(localId)
		if not localInputs then
			localInputs = FrameTemplater.newPlayerInput(localId) --Not loaded, empty input
		end
		currentInputFrame = FrameTemplater.newInputFrame() --Empty predicted frame
		if localPlayerLoaded then
			currentInputFrame[localId] = localInputs
		end

		clientSimStatus = SimStatus.Predicting
		--Now we use the inputs per client!
		for otherPlayerId = 1, Runner.Config.maxPlayers do
			local pastFrame

			if perPlayerPredictions then
				pastFrame = latestReceivedPacket[otherPlayerId]
			else
				pastFrame = predictFromFrame
			end

			local pastInputs = inputBuffer:getFrame(pastFrame)
			if not pastInputs then
				continue
			end
			local playerInputs = pastInputs[otherPlayerId]
			if otherPlayerId ~= localId then
				currentInputFrame[otherPlayerId] = playerInputs
			end
		end

		--print(localFrame, currentInputFrame[1].Connected)
	else
		--We are catching up, and should not accept inputs
		currentInputFrame = inputBuffer:getFrame(localFrame, false) or FrameTemplater.newInputFrame()

		localInputs = FrameTemplater.newPlayerInput()

		clientSimStatus = SimStatus.Syncing
	end

	local inputFrameIsReliable = isAllInputs(currentInputFrame)
	--if not inputFrameIsReliable then
	currentInputFrame[localId].Connected = true --Force inject even if no input sent
	inputBuffer:setFrame(localFrame, currentInputFrame)
	--end
	--Send to server to inform future predictions with sticky attributes
	InputSync:FireServer(localFrame, InputSerDes.serializePlayerInputs(localInputs)) --Only send if we are processing inputs

	worldState = Runner.simulate(localFrame, worldState, inputBuffer, clientSimStatus)

	setWorldState(localFrame, worldState)

	local checkpointInterval = 10
	if localFrame % checkpointInterval == 0 then
		--TODO checkpoint state
	end

	renderPostSim()
	renderAlwaysSim()
	debug.profileend()
end

function staticTick() --Only called once every frame ever
	localStaticFrame += 1
end

function module.init(newRunner: types.map<string, any>)
	Runner = newRunner
	if not Runner then
		error("Runner not passed to ClientRunner")
	end
	module.stop()
	if Runner.InputSerDes then
		InputSerDes = Runner.InputSerDes
	end
	Shared.init(Runner)
	Network.init(Runner.Config)

	--config
	maxRollbackFrames = Shared.maxServerFrameBufferSize
	targetAdvantage = maxRollbackFrames --TODO can't we adjust this?
	clientFrameBufferSize = (maxRollbackFrames + Runner.Config.reliableBufferSize + Shared.maxServerFrameBufferSize) * 2
	maxFrameAdvantage = maxRollbackFrames + Shared.maxServerFrameBufferSize

	print("Initialized maximum advantage", maxFrameAdvantage)
	--state
	localFrame = 0
	remoteFrame = 0
	localStaticFrame = 0
	syncFrame = 0
	remoteFrameAdvantage = 0
	active = false
	--World state is resynced in
	clientSimStatus = SimStatus.Syncing
	--Resync initializes
	inputBuffer = nil
	worldStateBuffer = nil
	receivedBuffer = nil
	inputMergeQueue = {}
	predictFromFrame = 1
	riftCorrection = 1
	frameAccumulator = 0
	simLocked = false

	table.insert(
		connections,
		AssignPlayerId.OnClientEvent:Connect(function(playerIdMap)
			PlayerRegistry.setIdMap(playerIdMap)
		end)
	)

	--TODO if not "reliable" just use our own inputs
	table.insert(
		connections,
		InputSync.OnClientEvent:Connect(function(newServerFrame, serverInputs, isImmediate)
			table.insert(pendingLivePackets, {
				frame = newServerFrame,
				inputs = { serverInputs }, --We only get one frame
			})
		end)
	)

	--Ensures we will get every possible input
	table.insert(
		connections,
		InputSyncReliable.OnClientEvent:Connect(function(newServerFrame, serverInputs, isImmediate)
			table.insert(pendingLivePackets, {
				frame = newServerFrame,
				inputs = serverInputs, --Sends multiple for less overhead
				sync = true,
			})
		end)
	)
	table.insert(
		connections,
		ResyncInputs.OnClientEvent:Connect(function(startFrame, newFrames, packetIndex)
			table.insert(resyncQueue, {
				startFrame = startFrame,
				newFrames = newFrames,
				packetIndex = packetIndex,
			})
		end)
	)

	table.insert(
		connections,
		Resync.OnClientEvent:Connect(function(newServerFrame, newWorldState)
			worldState = newWorldState
			remoteFrame = newServerFrame
			localFrame = newServerFrame
			syncFrame = newServerFrame
			print("Starting resync", remoteFrame, localFrame, worldState)
			lastResyncPacketIndex = 0
			worldStateSynced = true
		end)
	)

	table.insert(
		connections,
		RunService.PreRender:Connect(function(deltaTime)
			if isResyncing then
				local success = processResyncQueue() --Process one packet

				return
			else
			end

			if not active then
				return
			end

			local currentAdvantage = localFrame - remoteFrame

			local drift = currentAdvantage - targetAdvantage

			local sensitivity = 0.05
			local speedAdjustment = drift * sensitivity

			riftCorrection = 1 - speedAdjustment

			if currentAdvantage >= maxCatchupFrames then
				riftCorrection = 1
			end

			local tickRate = Runner.Config.tickRate
			frameAccumulator += deltaTime * riftCorrection

			if simLocked then
				return
			end
			simLocked = true

			local count = 0
			while frameAccumulator > tickRate do
				count += 1
				frameAccumulator -= tickRate
				processPendingPackets(true)
				clientUpdate()
			end
			simLocked = false

			local frameDifference = localFrame - remoteFrame
		end)
	)

	--TODO duplicated accumulator code
	local hbAccumulator = 0
	table.insert(
		connections,
		RunService.Heartbeat:Connect(function(deltaTime)
			hbAccumulator += deltaTime
			local tickRate = Runner.Config.tickRate

			while hbAccumulator > tickRate do
				hbAccumulator -= tickRate
				if not active then
					return
				end
				staticTick()
				if clientSimStatus == SimStatus.Predicting or clientSimStatus == SimStatus.Simulating then
					renderPostFrame()
				end
			end
		end)
	)
end

function module.start(joinPort: number)
	port = joinPort
	-- Start initial resync TODO null arg for server determined
	fireResync(1)
end

function module.stop()
	-- Set inactive
	active = false
	isResyncing = false
	resyncQueue = {}
	worldStateSynced = false

	-- Disconnect all events
	for _, conn in connections do
		conn:Disconnect()
	end
	connections = {}

	-- Clear state
	localFrame = nil
	remoteFrame = nil
	syncFrame = nil
	remoteFrameAdvantage = nil
	worldState = nil
	clientSimStatus = nil
	inputBuffer = nil
	worldStateBuffer = nil
	inputMergeQueue = nil
	predictFromFrame = nil
	riftCorrection = nil
	frameAccumulator = nil
	simLocked = false
end

return module
