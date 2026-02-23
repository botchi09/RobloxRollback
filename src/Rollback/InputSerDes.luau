local module = {}
local Framework = script.Parent
local types = require("./Types")
local FrameTemplater = require(Framework.FrameTemplater)

--Basic filler SerDes with no compression

--PlayerInputs = one player (in a frame)
--FrameInputs = one frame

function module.serializePlayerInputs(inputs: any): any
	return inputs
end

function module.serializeFrameInputs(inputs: types.map<number, any>?): types.list<{ owner: number, inputs: any }>
	local newInputs: types.list<{ owner: number, inputs: any }> = {}
	if inputs then
		for playerId, inputs in inputs do
			table.insert(newInputs, { owner = playerId, inputs = inputs })
		end
	end
	return newInputs
end

function module.deserializePlayerInputs(inputs: any): any
	return inputs
end

function module.deserializeFrameInputs(inputs: types.list<{ owner: number, inputs: any }>): types.map<number, any>
	local newInputs: types.map<number, any> = FrameTemplater.newInputFrame()
	for k, inputFrame in inputs do
		local owner = inputFrame.owner
		local playerInputs = inputFrame.inputs
		newInputs[owner] = playerInputs
	end
	return newInputs
end

return module
