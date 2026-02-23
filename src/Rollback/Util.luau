local module = {}

local types = require("./Types")

local function deepClone<K, V>(original: types.map<K, V>): types.map<K, V>
	local clone = table.clone(original)

	for key, value in original do
		if type(value) == "table" then
			clone[key] = deepClone(value)
		end
	end

	return clone
end

module.deepCopy = deepClone

function module.msToTicks(ms: number, tickRate: number): number
	return math.ceil(ms / 1000 / tickRate)
end

function module.getBufferOverheadMs(): number
	local bufferOverheadMs = (1 / 60) * 2 * 1000 --Usually 1 or 2 frames
	return bufferOverheadMs
end

return module
