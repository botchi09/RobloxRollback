local module = {}
local Framework = script.Parent
local FrameTemplater = require(Framework.FrameTemplater)

--Basic filler SerDes with no compression

--PlayerInputs = one player (in a frame)
--FrameInputs = one frame

function module.serializePlayerInputs(inputs)
	return inputs
end

function module.serializeFrameInputs(inputs)
	local newInputs = {}
	if inputs then
		for playerId, inputs in pairs(inputs) do
			table.insert(newInputs, {owner = playerId, inputs = inputs})
		end
	end
	return newInputs
end

function module.deserializePlayerInputs(inputs)
	return inputs
end

function module.deserializeFrameInputs(inputs)
	local newInputs = FrameTemplater.newInputFrame()
	for k, inputFrame in ipairs(inputs) do
		local owner = inputFrame.owner
		local inputs = inputFrame.inputs
		newInputs[owner] = inputs
	end
	return newInputs
end

return module
