local module = {}
local types = require("./Types")
local Util = require("./Util")

function module.new(maxSize: number, existingFrames: types.list<any>?): any
	local self: types.map<string, any> = {}
	self.maxSize = maxSize
	self.frames = existingFrames or {} :: types.list<any> --TODO trim if too many frames
	self.head = maxSize

	self.getIndex = function(self, index: number)
		self.head = math.max(index)

		return ((index - 1) % self.maxSize) + 1
	end

	self.getFrame = function(self, index: number, copyFrame: boolean?): any
		local i = self:getIndex(index)

		local frameState = self.frames[i]
		if not frameState then
			return nil
		end
		if copyFrame then
			return Util.deepCopy(frameState)
		end
		return frameState
	end

	self.setFrame = function(self, index: number, value: any, copyFrame: boolean?)
		--TODO why does this cause bugs? We shouldn't be accessing anything past the tail.
		--[[local gap = index - (self.head + 1)
		local tail = self.head + 1 - self.maxSize
		for i=1, gap do
			self:setFrame(tail + i, {})
		end
		]]
		self.head = math.max(self.head, index)

		local i = self:getIndex(index)
		local storeValue
		if copyFrame then
			storeValue = Util.deepCopy(value)
		else
			storeValue = value
		end
		self.frames[i] = storeValue
	end

	self.resize = function(self, newMaxSize: number)
		if newMaxSize == self.maxSize then
			return
		end

		--Expand forward
		if newMaxSize > self.maxSize then
			local newFrames = {}
			local tail = math.max(1, self.head + 1 - self.maxSize)

			for frameIndex = tail, self.head do
				local oldSlot = self:getIndex(frameIndex)
				local newSlot = ((frameIndex - 1) % newMaxSize) + 1
				newFrames[newSlot] = self.frames[oldSlot]
			end

			self.frames = newFrames
		else
			--Shrink backward
			local newFrames = {}
			local newTail = self.head + 1 - newMaxSize

			for frameIndex = newTail, self.head do
				local oldSlot = self:getIndex(frameIndex)
				local newSlot = ((frameIndex - 1) % newMaxSize) + 1
				newFrames[newSlot] = self.frames[oldSlot]
			end

			self.frames = newFrames
		end

		self.maxSize = newMaxSize
	end

	function self.serialize(self): types.map<string, any>
		return { frames = self.frames, maxSize = self.maxSize }
	end

	function self.fillFrames(self, templateTable: any, fillCount: number?)
		fillCount = fillCount or self.maxSize
		for i = 1, fillCount do
			self.frames[i] = Util.deepCopy(templateTable)
		end
	end

	return self
end

return module
