local Util = {}

local copy = table.clone

-- for reducer to simply set the state's key directly
function Util.simpleReducer(key)
	return function(_, action)
		return action[key]
	end
end


function Util.listReducer(keyId, valueId)
	return function(
		state,
		action
	)
		
		state = copy(state)
		
		state[action[keyId]] = action[valueId]
		
		return state
		
	end
end

-- for action to simply set the state's key directly
function Util.simpleAction(key, additionalData)
	additionalData = additionalData or {}
	return function(value)
		local action = {[key] = value}
		for k,v in additionalData do
			action[k]=v
		end
		return action
	end
end

function Util.actionWithoutArguments()
	return function()
		return {}
	end
end

function Util.multiAction(keys:{string}, additionalData:{[any]:any})

	additionalData = additionalData or {}

	return function(...)
		local values = {...}
		local action = {}

		-- assign each key to corresponding value
		for i, key in ipairs(keys) do
			action[key] = values[i]
		end

		-- merge additionalData
		for k, v in additionalData do
			action[k] = v
		end

		return action
	end

end



return Util
