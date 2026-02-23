local module = {}


local function deepClone(original)
	local clone = table.clone(original) 

	for key, value in original do
		if type(value) == "table" then
			clone[key] = deepClone(value)
		end
	end

	return clone
end

module.deepCopy = deepClone


function module.msToTicks(ms, tickRate)
	return math.ceil(ms / 1000 / tickRate)
end

function module.getBufferOverheadMs()
	local bufferOverheadMs = (1/60) * 2 * 1000 --Usually 1 or 2 frames
	return bufferOverheadMs
end

return module
