--TODO this module is unimplemented and buggy. Use as reference material only.
local module = {}
local Framework = script.Parent

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ResyncInputs = Framework.ResyncInputs
local InputSync = Framework.InputSync
local InputSyncReliable = Framework.InputSyncReliable
local AssignPlayerId = Framework.AssignPlayerId

local Resync = Framework.Resync

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
local maxFrameAdvantage = 3
local maxRollbackFrames = 6
local clientFrameBufferSize
local maxRiftCorrection = 4

-- State variables (will be reset on init)
local localFrame:number
local remoteFrame:number
local syncFrame
local remoteFrameAdvantage
local restoreFrame
local active
local worldState
local clientSimStatus

local inputBuffer
local worldStateBuffer
local verifyBuffer

local inputMergeQueue
local predictFromFrame:number
local riftCorrection
local frameAccumulator
local simLocked

local worldStateSynced = false
local pendingLivePackets = {} 
local isResyncing = false

--TODO checkpointing with deltacompress and checkpointing

function findLastCheckpoint(startFrame)
	local checkFrame = startFrame
	while worldStateBuffer:getFrame(checkFrame) == false do
		checkFrame -= 1
	end
	return checkFrame
end


function getWorldState(frame, deepCopy)
	local checkpointFrame = findLastCheckpoint(frame)
	if checkpointFrame ~= frame then
		local newState = resimulateFrames(checkpointFrame, frame)
		--Save checkpoint of frame if we need to reindex
		setWorldState(frame, newState, true)
		return newState
	end
	return worldStateBuffer:getFrame(frame, deepCopy)
end


--Always deepcopy
function setWorldState(frame, worldState, deepCopy)
	if deepCopy then
		worldStateBuffer:setFrame(frame, worldState, deepCopy)
	else
		--Don't set it! Checkpoint! TODO
		worldStateBuffer:setFrame(frame, false, false)
	end
	
end



-- Connection tracking
local connections = {}

local function renderWithFunction(renderFuncName, displayFrame)
	local currentWorldState = getWorldState(displayFrame, false)
	local renderFunc = Runner[renderFuncName]
	if renderFunc then
		renderFunc(displayFrame, currentWorldState, 
			inputBuffer, clientSimStatus)
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

function createLocalPlayerInputs(localId, worldState)
	local emptyInput = FrameTemplater.newPlayerInput(localId)
	local inputs = Runner.getLocalPlayerInputs(emptyInput, worldState)
	return inputs
end


function serializePlayerInputs(inputs)
	
end

function isAllInputs(receivedList)
	return #receivedList == Runner.Config.maxPlayers
end

--TODO handle early frames! might result in tail corruption
local function serverFramesReceived(newServerFrame, serverInputs)
	
	if newServerFrame > localFrame then
		--print("Server ahead of client")
	end
	
	--Offset to account for time diff
	remoteFrame = newServerFrame + Shared.maxServerFrameBufferSize
	remoteFrameAdvantage = (localFrame - remoteFrame)
	
	
	for i = 1, #serverInputs do
		
		local newInputs, receivedList = InputSerDes.deserializeFrameInputs(serverInputs[i])
		local isReliable = isAllInputs(receivedList)
		if not isReliable then
			
		end	
		--Does not use remoteFrame for correct time
		local serverFrame = newServerFrame - (i - 1)
		
		table.insert(inputMergeQueue, {frame = serverFrame, inputs = newInputs, receivedList = receivedList})
	end
end
function inputsEqual(i1, i2, excludeIds)
	if Runner.inputsEqual then
		return Runner.inputsEqual(i1, i2, excludeIds)
	end

	if i1 == i2 then return true end
	if (i1 == nil) ~= (i2 == nil) then return false end

	i1 = i1 or {}
	i2 = i2 or {}
	excludeIds = excludeIds or {}

	for userId, input1 in pairs(i1) do
		if excludeIds[userId] then continue end

		local input2 = i2[userId]
		if not input2 then return false end

		for inputName, inputValue in pairs(input1) do
			if input2[inputName] ~= inputValue then
				return false
			end
		end
	end

	for userId, _ in pairs(i2) do
		if excludeIds[userId] then continue end
		if i1[userId] == nil then return false end
	end

	return true
end


local function mergeServerInputs(testMispredict)
	local mispredictFrame = nil
	while #inputMergeQueue > 0 do
		
		local data = table.remove(inputMergeQueue)

		local mergeFrame = data.frame
		local mergeInputs = data.inputs
		local isReliable = isAllInputs(data.receivedList)

		local frameInputs = inputBuffer:getFrame(mergeFrame, true)
		if not frameInputs then
			frameInputs = {}
		end
		local localId = PlayerRegistry.getPlayerId(LocalPlayer)
		local frameTemplate = FrameTemplater.getInputFrameTemplate()
		
		--Force fill missing inputs (may happen accessing uninitialized frame?)
		for k, v in ipairs(frameTemplate) do
			if not frameInputs[k] then
				--warn("Incomplete frame for", k, v)
				--print("Ref frame", frameInputs[k])
				frameInputs[k] = v
			end
		end
		
		
		local excludeIds = {}
				
		if not isReliable then
			excludeIds[localId] = true
			for i=1, Runner.Config.maxPlayers do
				--if not frameInputs[i] or not frameInputs[i].Connected then
				if not table.find(data.receivedList, i) then
					excludeIds[i] = true
				end
			end
		end
		
		if testMispredict then
			local newInputs = mergeInputs
			--print("BOTINPUT", frameInputs[2].Connected, mergeInputs[2].Connected)
			if not inputsEqual(frameInputs, newInputs, excludeIds) then
				mispredictFrame = math.min(mispredictFrame or mergeFrame, mergeFrame)
				--Can fire if too old too
				--print("MISPREDICT", mispredictFrame, frameInputs, newInputs)
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

function processPendingPackets(forceAll:boolean?)
	
		
	local processLimit = 1 --We receive them in subpackets of about 4
	local currentProcessed = 0
	while #pendingLivePackets > 0 and (currentProcessed < processLimit or forceAll) do
		currentProcessed += 1
		--If we don't remove in sequence we might skip local frame ahead too far
		local packet = table.remove(pendingLivePackets)
		serverFramesReceived(packet.frame, packet.inputs)
	end
end

local resyncQueue = {}
local lastResyncPacketIndex = 0

function resizeBuffersToNormal()
	worldStateBuffer:resize(clientFrameBufferSize)
	print("New world state buffer size", worldStateBuffer)
end

local function processResyncQueue()
	if #resyncQueue == 0 or not worldStateSynced then return end
	
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

	serverFramesReceived(startFrame, newFrames)
	
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
		setWorldState(actualFrame, worldState, false)			

		-- Update the local clock
		localFrame = actualFrame
	end
	
	mergeServerInputs(false) --Merge and clear input queue after

	--Just for nonessential visuals while resyncing
	renderPostFrame()

	if isFinished then
		
		print("Resync done! Current Frame:", localFrame)
		--Checkpoint current frame
		setWorldState(localFrame, worldState, true)	
		
		local firstPacket = pendingLivePackets[1]
		
		if firstPacket then
			local targetFrame = firstPacket.frame-1
			localFrame = targetFrame --Force us to sync from here
			syncFrame = targetFrame
			worldState = getWorldState(syncFrame, true)
			print("Pending packets", #pendingLivePackets,
				"from frame", targetFrame)
			
			resizeBuffersToNormal()
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

function timeSynced()
	--Compare last known frame advantages
	local localFrameAdvantage = localFrame - remoteFrame
	local frame_advantage_difference = localFrameAdvantage - remoteFrameAdvantage

	--TODO why does turning off second statement fix time sync?
	return localFrameAdvantage < maxRollbackFrames and frame_advantage_difference <= maxFrameAdvantage
end

local function fireResync(frame:number?)
	print("Resync started...")
	active = false
	isResyncing = true
	RunService.Heartbeat:Wait() --Force yield until no active thread
	pendingLivePackets = {}
	resyncQueue = {}
	
	local fullBufferSize = Runner.Config.fullGameBufferSize
	worldStateSynced = false
	inputBuffer = RingBuffer.new(fullBufferSize)
	--Prevent nil indices
	inputBuffer:fillFrames(FrameTemplater.newInputFrame(), clientFrameBufferSize)
	worldStateBuffer = RingBuffer.new(fullBufferSize)
	verifyBuffer = RingBuffer.new(fullBufferSize)
	Resync:FireServer(frame, port)
end

function resimulateFrames(startFrame, stopFrame)
	local rollbackState = getWorldState(startFrame, true)
	for frame = startFrame + 1, stopFrame do
		local frameInputs = inputBuffer:getFrame(frame, false)
		rollbackState = Runner.simulate(frame, rollbackState, inputBuffer, SimStatus.Resimulating)
		renderAlwaysSim()
		setWorldState(frame, rollbackState, false) --Don't save state in resim, rely on checkpoint
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
	if verifyBuffer then
		local verifyFrame = localFrame - clientFrameBufferSize
		local debugForceResync = false --localFrame % 300 == 0 --TODO very buggy. Re-adds clients.
		if localFrame > clientFrameBufferSize and not verifyBuffer:getFrame(verifyFrame) or debugForceResync then
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
	local isLocalAhead = not isRemoteAhead
	
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
		local pastInputs = inputBuffer:getFrame(predictFromFrame)

		for otherPlayerId = 1, Runner.Config.maxPlayers do
			local playerInputs = pastInputs and pastInputs[otherPlayerId]
			if otherPlayerId ~= localId then
				currentInputFrame[otherPlayerId] = playerInputs
			end
			
		end
	
		--print(localFrame, currentInputFrame[1].Move)
	else
		--print("Remote ahead", remoteFrame, localFrame, riftCorrection)
		
		currentInputFrame = inputBuffer:getFrame(localFrame, false) or FrameTemplater.newInputFrame()
		
		localInputs = FrameTemplater.newPlayerInput()
		localInputs.Connected = true
		
		clientSimStatus = SimStatus.Syncing
	end		
	currentInputFrame[localId].Connected = true --Force inject even if no input sent
	inputBuffer:setFrame(localFrame, currentInputFrame)	
	
	InputSync:FireServer(localFrame, InputSerDes.serializePlayerInputs(localInputs)) --Only send if we are processing inputs

	worldState = Runner.simulate(localFrame, worldState, inputBuffer, clientSimStatus)

	setWorldState(localFrame, worldState, true)
	

	renderPostSim()
	renderAlwaysSim()
	debug.profileend()
end




function module.init(newRunner)
	Runner = newRunner
	if not Runner then
		error("Runner not passed to ClientRunner")
	end
	module.stop()
	if Runner.InputSerDes then
		InputSerDes = Runner.InputSerDes
	end
	Shared.init(Runner)
	
		
	--config
	clientFrameBufferSize = (maxRollbackFrames
		+ Runner.Config.reliableBufferSize
		+ Shared.maxServerFrameBufferSize) * 2

	
	--state
	localFrame = 0
	remoteFrame = 0
	syncFrame = 0
	remoteFrameAdvantage = 0
	active = false
	--World state is resynced in
	clientSimStatus = SimStatus.Syncing
	--Resync initializes
	inputBuffer = nil
	worldStateBuffer = nil
	verifyBuffer = nil
	inputMergeQueue = {}
	predictFromFrame = 1
	riftCorrection = 1
	frameAccumulator = 0
	simLocked = false
	
	table.insert(connections, AssignPlayerId.OnClientEvent:Connect(function(playerIdMap)
		PlayerRegistry.setIdMap(playerIdMap)
	end))	
	
	--TODO if not "reliable" just use our own inputs
	table.insert(connections, InputSync.OnClientEvent:Connect(function(newServerFrame, serverInputs, isImmediate)
		table.insert(pendingLivePackets, {
			frame = newServerFrame,
			inputs = {serverInputs}, --We only get one frame
		})
	
	end))	
	
	--Ensures we will get every possible input
	table.insert(connections, InputSyncReliable.OnClientEvent:Connect(function(newServerFrame, serverInputs, isImmediate)
		table.insert(pendingLivePackets, {
			frame = newServerFrame,
			inputs = serverInputs, --Sends multiple for less overhead
			reliable = true,
		})
		
		--Mark each frame in the verify buffer as received
		for i = newServerFrame, newServerFrame - #serverInputs + 1, -1 do
			verifyBuffer:setFrame(i, true)
			

		end
		
	end))	
	table.insert(connections, ResyncInputs.OnClientEvent:Connect(function(startFrame, newFrames, packetIndex)
		
		table.insert(resyncQueue, {
			startFrame = startFrame,
			newFrames = newFrames,
			packetIndex = packetIndex,
		})
		for i = startFrame, startFrame - #newFrames + 1, -1 do
			verifyBuffer:setFrame(i, true)
			

		end
	end))

	table.insert(connections, Resync.OnClientEvent:Connect(function(newServerFrame, newWorldState)
		worldState = newWorldState
		remoteFrame = newServerFrame
		localFrame = newServerFrame
		syncFrame = newServerFrame
		print("Starting resync", remoteFrame, localFrame, worldState)
		lastResyncPacketIndex = 0
		worldStateSynced = true
	end))

	table.insert(connections, RunService.PreRender:Connect(function(deltaTime)
		if isResyncing then
			
			local success = processResyncQueue() --Process one packet
			
			return 
		else
			
		end
		
		if not active then return end
		
				

		local clientAdvantage = localFrame - remoteFrame
		local framesBehindAdvantage = clientAdvantage - maxFrameAdvantage
		
		--We must always be ahead of remote
		if remoteFrame > localFrame then
			riftCorrection = maxRiftCorrection
		else
			riftCorrection = 1
		end

		local tickRate = Runner.Config.tickRate
		frameAccumulator += deltaTime * riftCorrection

		if simLocked then return end
		simLocked = true

		local count = 0
		while frameAccumulator > tickRate do
			count += 1
			frameAccumulator -= tickRate
			processPendingPackets(true)
			clientUpdate()
		end
		simLocked = false	
	end))
	
	--TODO duplicated accumulator code
	local hbAccumulator = 0
	table.insert(connections, RunService.Heartbeat:Connect(function(deltaTime)
		hbAccumulator += deltaTime
		local tickRate = Runner.Config.tickRate

		while hbAccumulator > tickRate do
			hbAccumulator -= tickRate
			if not active then return end
			if clientSimStatus == SimStatus.Predicting or clientSimStatus == SimStatus.Simulating then
				renderPostFrame()
			end
		end
	end))

end

function module.start(joinPort:number)
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
	for _, conn in ipairs(connections) do
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