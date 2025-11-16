local RunService = game:GetService("RunService")

local Stream = {}
Stream.__index = Stream

local Signal = require('./Signal')
local Trove = require('./Trove')
local Promise = require('./Promise')

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

function Stream.heartbeat()
	return Stream.fromSignal(RunService.Heartbeat)
end

Stream.defer = Stream.of

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

function Stream.delay(sec:number)
	local delayedStream = Stream.new()
	
	delayedStream._trove:AddPromise(
		Promise.delay(sec):andThenCall(delayedStream.emit, delayedStream)
	)
	
	return delayedStream
end

function Stream.throttle(self: Stream, waitTime: number): Stream
	local throttledStream = self:extend()
	local lastEmitTime = 0

	throttledStream:add(
		self:subscribe(function(...)
			local now = os.clock() -- Use high-precision time
			if now - lastEmitTime >= waitTime then
				lastEmitTime = now
				throttledStream:emit(...)
			end
		end)
	)

	return throttledStream
end
function Stream.fromSignal(Signal: RBXScriptSignal): Stream
	
	local self = Stream.new()
	
	self:add(
		Signal:Connect(function(...)
			self:emit(...)
		end)
	)
	
	return self
	
end
function Stream.debounce(self: Stream, waitTime: number): Stream
	local debouncedStream = self:extend()

	local currentToken = nil -- This will track the latest scheduled task

	debouncedStream:add(
		self:subscribe(function(...)
			local args = {...} -- Capture the arguments

			-- Create a new, unique token for this specific call.
			-- A new table is a perfect unique reference.
			local myToken = {} 
			currentToken = myToken -- Mark this as the latest pending task

			task.delay(waitTime, function()
				-- When the delay finishes, only emit if this task
				-- is still the 'currentToken'. If another event
				-- came in, 'currentToken' will have been replaced,
				-- and this check will fail.
				if currentToken == myToken then
					currentToken = nil -- Clear the token
					debouncedStream:emit(table.unpack(args))
				end
			end)
		end)
	)

	return debouncedStream
end

function Stream.listen(self: Stream, listenerFn: (trove:Trove.Trove, ...any) -> () )
	local outerTrove = self:add(Trove.new()) 
	local innerTrove
	outerTrove:Add(
		self:subscribe(function(...)
			
			if innerTrove then
				outerTrove:Remove(innerTrove)
			end
			
			innerTrove = outerTrove:Extend()
			
			listenerFn(innerTrove, ...)
		end)
	)
	
	return outerTrove
end

function Stream.switchMap(self: Stream, projectFn: (any) -> Stream): Stream
	-- 1. Create the new stream that will be returned.
	--    We use :extend() so it's tied to the source stream's lifetime.
	local outputStream = self:extend()

	-- 2. Keep a reference to the *currently active* inner stream.
	local currentInnerStream: Stream? = nil

	-- 3. Subscribe to the source stream (self)
	outputStream:add(
		self:subscribe(function(...)

			-- 4. "Switch": Destroy the *previous* inner stream.
			--    Your Trove-based :Destroy() will handle cleaning up
			--    its internal signal and all its subscriptions.
			if currentInnerStream then
				currentInnerStream:Destroy()
				currentInnerStream = nil
			end

			-- 5. Call the project function to get the *new* inner stream.
			local newInnerStream = projectFn(...)

			if newInnerStream and newInnerStream.subscribe then
				-- 6. Store this as the new "current" stream.
				currentInnerStream = newInnerStream

				-- 7. Add the new stream to the output's trove.
				--    This is crucial: if outputStream:Destroy() is called,
				--    this currentInnerStream will also be destroyed.
				outputStream:add(newInnerStream)

				-- 8. Subscribe to the new inner stream and forward its values.
				--    We don't need to add this subscription to a trove,
				--    because when newInnerStream is destroyed (either by
				--    the next switch or by outputStream's destruction),
				--    its internal _signal is destroyed, automatically
				--    disconnecting this.
				newInnerStream:subscribe(function(...)
					outputStream:emit(...)
				end)
			end
		end)
	)

	-- 9. Return the stream that emits values from the "switched" inner streams.
	return outputStream
end
function Stream.add<T>(self: Stream, obj:T, cleanupMethod):T
	return self._trove:Add(obj,cleanupMethod)
end

function Stream.extend(self: Stream)
	local stream = Stream.new()
	self._trove:Add(stream)
	return stream
end

function Stream.toSignal(self: Stream)
	return self._signal
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

Stream.Destroy = Stream.destroy

export type Stream = typeof(Stream.new())



return Stream
