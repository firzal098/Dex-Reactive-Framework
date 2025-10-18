local Stream = {}
Stream.__index = Stream

local Signal = require('./Signal')
local Trove = require('./Trove')

function Stream.new()
	
	local trove = Trove.new()
	local self = setmetatable({
		_signal = trove:Add(Signal.new());
		_trove = trove;
	},Stream)
	
	return self
end

function Stream.of(...:any)
	local immediateStream = Stream.new()
	
	immediateStream:add(
		task.defer(function(...)
			immediateStream:emit(...)
		end,...)
	)
	
	return immediateStream
end

function Stream.merge(Streams: {Stream}) 
	local mergedStream = Stream.new()
	
	for _,stream in ipairs(Streams) do
		mergedStream:add(
			stream:subscribe(function(...)
				mergedStream:emit(...)
			end)
		)
	end
	
	return mergedStream
end

function Stream.fromSignal(Signal: RBXScriptSignal)
	
	local self = Stream.new()
	
	self:add(
		Signal:Connect(function(...)
			self:emit(...)
		end)
	)
	
	return self
	
end

function Stream.add<T>(self: Stream, obj:T, cleanupMethod):T
	return self._trove:Add(obj,cleanupMethod)
end

function Stream.extend(self: Stream)
	local stream = Stream.new()
	self._trove:Add(stream)
	return stream
end


function Stream.subscribe(self: Stream, fn)
	return self._signal:Connect(fn)
end

function Stream.filter(self: Stream, predicate)
	local filteredStream = self:extend()

	filteredStream:add(
		self:subscribe(function(...) 
			if predicate(...) then
				filteredStream:emit(...)
			end	
		end)
	)

	return filteredStream
end

function Stream.map<T, U>(self: Stream, transformFn: (T) -> U): Stream
	local mappedStream = self:extend()

	mappedStream:add(
		self:subscribe(function(...)
			mappedStream:emit(transformFn(...))
		end)
	)

	return mappedStream
end

function Stream.destroy(self: Stream)
	self._trove:Destroy()
end

function Stream.emit(self:Stream, ...)
	self._signal:Fire(...)
end

export type Stream = typeof(Stream.new())

return Stream
