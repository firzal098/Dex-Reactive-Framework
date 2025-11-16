-- State.lua
--[[
	A module for creating and managing state objects. These objects hold a value and allow
	other parts of a script to listen for changes to that value. It's a core component
	for creating reactive and declarative UI and game logic.
]]

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Dependencies
local Signal = require(ReplicatedStorage.Packages.Signal) --! UPDATE THIS PATH
local Trove = require(ReplicatedStorage.Packages.Trove) --! UPDATE THIS PATH
local Animator = require(script.Parent.Animator) --! Animation scheduler
local Stream = require(script.Parent.Stream)

-- Forward declaration of the State type

export type State<T> = {
	_value: T,
	_changed: Signal,
	_trove: Trove,
	_isDeferred: boolean,

	map: <U>(self: State<T>, transformFn: (newValue: T) -> U) -> State<T>,
	tween: (self: State<T>, tweenInfo: TweenInfo?) -> State<T>,
	spring: (self: State<T>, damping: number?, frequency: number?) -> State<T>,
	default: (self: State<T>, value: any) -> State<T>,
	derive: <U>(self: State<T>, transformFn: (newValue: T) -> U) -> State<T>, 
	get: (self: State<T>) -> T,
	peek: (self: State<T>) -> T,
	set: (self: State<T>, newValue: T) -> State<T>,
	observe: (self: State<T>, callback: (newValue: T) -> (), callImmediately: boolean?) -> RBXScriptConnection,
	listen: (self: State<T>, callback: (newValue: T, trove: Trove) -> ()) -> Trove,
	linkProperty: (self: State<T>, instance: Instance, prop: string) -> RBXScriptConnection,
	linkAttribute: (self: State<T>, instance: Instance, prop: string) -> RBXScriptConnection,
	bind: (self: State<T>, other: State<T>) -> RBXScriptConnection,
	deferred: (self: State<T>) -> State<T>,
	immediate: (self: State<T>) -> State<T>,
	destroy: (self: State<T>) -> (),


	changed: Signal,
	toStream: (self: State<T>) -> Stream.Stream, 

}


export type Trove = typeof(Trove.new())
-- Module
local State = {}
State.__index = State

local function evaluate(value)
	return State.is(value) and value:get() or value
end

function State:__add(value)
	self:set(self:get() + evaluate(value));
	return self
end

-- Subtraction
function State:__sub(value)
	self:set(self:get() - evaluate(value))
	return self
end

-- Multiplication
function State:__mul(value)
	self:set(self:get() * evaluate(value))
	return self
end

-- Division
function State:__div(value)
	self:set(self:get() / evaluate(value))
	return self
end

-- Exponentiation
function State:__pow(value)
	self:set(self:get() ^ evaluate(value))
	return self
end
--[[
	SCHEDULER FOR DEFERRED UPDATES
	This centralized system batches all deferred state changes together and fires
	them once at the end of the frame on the Heartbeat signal.
]]
local deferredQueue = {} -- A dictionary of states waiting to fire.
local heartbeatConnection = nil

local function processDeferredQueue()
	-- Create a copy of the states to process, then clear the main queue.
	-- This prevents issues if a state is set again from within a listener.
	local toProcess = {}
	for state in pairs(deferredQueue) do
		table.insert(toProcess, state)
	end
	deferredQueue = {}

	-- Fire the changed signal for each state with its latest value.
	for _, state in ipairs(toProcess) do
		state._changed:Fire(state:peek())
	end

	-- If no more work is scheduled, disconnect the Heartbeat to save resources.
	if next(deferredQueue) == nil and heartbeatConnection then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end


--// Constructors & Static Methods //--

---
-- Creates a new State object.
-- @param initialValue The initial value to store in the state object.
-- @return {State} A new State object.
function State.new<T>(initialValue: T): State<T>
	local self = setmetatable({}, State)
	self._value = initialValue
	self._changed = Signal.new()
	self._trove = Trove.new()
	self._isDeferred = false -- All states start in immediate mode by default.

	self.changed = self._changed
	self._trove:Add(self._changed)

	return self
end

---
-- Checks if the given object is a State object created by this module.
-- @param object The object to check.
-- @return True if the object is a State object, false otherwise.
function State.is(object: any): boolean
	return getmetatable(object) == State
end


function State.fromStream(stream: Stream.Stream, initialData): State<any>
	local streamState = State.new(initialData)
	
	streamState._trove:Add(
		stream:subscribe(function(value)
			streamState:set(value)
		end)
	)
	
	return streamState
end

---
-- Creates a State object that is two-way bound to an Instance's attribute.
-- The state will update when the attribute changes, and the attribute will update
-- when the state is set.
-- @param instance The instance to watch.
-- @param attribute The name of the attribute.
-- @return A new State object linked to the attribute.
function State.fromAttribute<T>(instance: Instance, attribute: string): State<T>
	local new = State.new(instance:GetAttribute(attribute)::T)

	new._trove:Add(instance:GetAttributeChangedSignal(attribute):Connect(function()
		new:set(instance:GetAttribute(attribute))
	end))

	new:observe(function(value)
		instance:SetAttribute(attribute, value)
	end)

	new._trove:AttachToInstance(instance)
	return new
end

---
-- Creates a State object that is bound to an Instance's property.
-- @param instance The instance to watch.
-- @param prop The name of the property.
-- @param twoWay An optional boolean to enable two-way binding. Defaults to true.
-- @return A new State object linked to the property.
function State.fromProperty<T>(instance: Instance, prop: string, twoWay: boolean?): State<T>
	local new = State.new(instance[prop]::T)

	if twoWay ~= false then
		new:observe(function(value)
			instance[prop] = value
		end)	
	end

	new._trove:Connect(instance:GetPropertyChangedSignal(prop), function()
		new:set(instance[prop])
	end)

	new._trove:AttachToInstance(instance)
	return new
end

---
-- Creates a new State whose value is computed from other States.
-- The function will re-run and the state's value will update automatically
-- and efficiently whenever any of the dependent states used inside the
-- function change. It intelligently batches multiple changes within a single
-- frame into a single recalculation.
-- @param fn The function that computes the value. It receives a `use` function
-- as its only argument, which should be called to get a state's value and track it.
-- @return A new read-only State object with the computed value.
function State.computed<T>(fn: (use: (dep: State<any>) -> any) -> T): State<T>
	local current: State<T> = State.new(nil)
	local t = current._trove
	local depsTrove = t:Extend()

	local scheduleUpdate
	--== NEW: The Scheduling Mechanism ==--
	local isDirty = false

	-- This is the SCHEDULER. It ensures `update` runs at most once per frame.
	
	-- This is the function that does the expensive work.
	local function update()
		-- Reset the flag for the next frame.
		isDirty = false

		depsTrove:Clean()
		local newDeps = {}

		-- The 'use' function is the same, but its effect is now scheduled.
		local function use(dependency: State<any>)
			assert(State.is(dependency), "Argument to 'use' must be a State object.")

			if not newDeps[dependency] then
				newDeps[dependency] = true
				-- When a dependency changes, we don't call update() directly.
				-- We call our new scheduler function instead.
				depsTrove:Add(dependency:observe(scheduleUpdate))
			end

			return dependency:peek()
		end

		local newValue = fn(use)
		
		if State.is(newValue) then
			-- If the function returned a State object, we use its value.
			depsTrove:Add(newValue:observe(function(v)
				if current._value ~= v then
					current._value = v
					current._changed:Fire(v)
				end		
			end,true))
		else
			-- We use a "silent set" here by directly modifying the internal value
			-- and then firing the signal. This avoids a potential recursive loop if
			-- the user's function somehow calls :set() on `current`.
			if current._value ~= newValue then
				current._value = newValue
				current._changed:Fire(newValue)
			end	
		end
		
	end

	function scheduleUpdate()
		-- If we're already scheduled to update, do nothing. This is the gate.
		if isDirty then
			return
		end
		-- Mark as dirty so subsequent calls in the same frame are ignored.
		isDirty = true
		-- Defer the actual, expensive `update` call to run later in this frame.
		task.defer(update)
	end
	-- Initial calculation runs immediately.
	update()

	-- We override the :set method to make the state read-only, which is a best practice.
	function current:set()
		warn("Cannot manually set the value of a computed state.")
	end

	return current
end


---
-- Binds a table of State objects and/or static values to the properties of an Instance.
-- If a value is a State object, it creates a reactive link.
-- If a value is not a State object, it sets the property once.
-- @param instance {Instance} The instance to hydrate with stateful properties.
-- @param props {{[string]: any}} A dictionary where keys are property names and values are State objects or static values.
-- @return {Instance, Trove} The instance that was hydrated, and the Trove object managing the connections.
function State.hydrate(instance: Instance, props: {[string]: any}): (Trove, {[string]: State<any>})
	local cleanupTrove = Trove.new()
	
	local states = {}

	for propName, value in pairs(props) do
		if typeof(instance[propName]) == 'RBXScriptSignal' then
			cleanupTrove:Connect(instance[propName], value)
		else
			if State.is(value) then
				-- If the value is a State object, create a reactive link.
				local connection = value:linkProperty(instance, propName)
				cleanupTrove:Add(connection)

				states[propName] = connection
			else
				-- If it's a static value, just set the property directly.
				instance[propName] = value
			end
		end
		
	end

	-- Automatically tie the cleanup trove's lifecycle to the instance.
	cleanupTrove:AttachToInstance(instance)

	return cleanupTrove--, states
end


function State.hydrateBatch(instances: {Instance}, props: {[string]:any})
	local mainTrove = Trove.new()
	for _,v in instances do
		mainTrove:Add(State.hydrate(v, props))
	end
	return mainTrove
end

-- Allows creating a new state with `State(value)` instead of `State.new(value)`.
setmetatable(State, {
	__call = function(_, initialValue)
		return State.new(initialValue)
	end,
	
})


--// Methods //--

---
-- Sets a new value for the State.
-- If the state is in deferred mode, it will batch the update until the end of the frame.
-- Returns the State object to allow for chaining.
-- @param value The new value to set.
-- @return {State} The State object itself.
function State:set<T>(value: T): State<T>
	if self:isEquivalent(value) then return self end
	
	if value==nil and self._defaultValue ~= nil then
		value = self._defaultValue
	end

	self._value = value

	if self._isDeferred then
		deferredQueue[self] = true
		if not heartbeatConnection then
			heartbeatConnection = RunService.Heartbeat:Connect(processDeferredQueue)
		end
	else
		self._changed:Fire(value)
	end

	return self
end

function State:toStream()
	local stateStream = Stream.new()
	
	self._trove:Add(stateStream)
	
	local old = self:get()
	
	stateStream:add(self:observe(function(val)
		stateStream:emit(val, old)
		old = val
	end, true))
	
	return stateStream
end


-- Sets default value of state
function State:default<T>(value:T): State<T>

	self._defaultValue = value
	
	if self:get() == nil then
		self:set(value)
	end

	return self
end


---
-- Switches this State object to deferred update mode.
-- @return {State} The State object itself.
function State:deferred(): State<T>
	self._isDeferred = true
	return self
end

---
-- Switches this State object back to immediate update mode.
-- @return {State} The State object itself.
function State:immediate(): State<T>
	self._isDeferred = false
	return self
end

---
-- Listens for changes to the state's value and provides a Trove for cleanup.
-- @param callback A function that receives the new value and a Trove for cleanup.
-- @return A Trove that can be used to destroy the entire listener.
function State:listen<T>(callback: (newValue: T, trove: Trove) -> nil): Trove
	local activeTrove: Trove = Trove.new()
	local valueTrove = activeTrove:Extend()

	local function update()
		valueTrove:Clean()
		-- We extend here to ensure the trove is fresh for the new callback execution.
		valueTrove = activeTrove:Extend()
		callback(self:peek(), valueTrove)
	end

	update()
	activeTrove:Add(self:observe(update))
	
	activeTrove:Add(function()

		if valueTrove then
			valueTrove:Destroy()
		end
	end)

	return activeTrove
end

---
-- Gets the current value of the State. This does NOT register the state as a
-- dependency inside a computed function. For that, use the provided `use` function.
-- @return The current value.
function State:get<T>(): T
	return self._value
end

---
-- Gets the current value of the State without firing any signals or registering dependencies.
-- This is the rawest way to access the value.
-- @return The current value.
function State:peek<T>(): T
	return self._value
end

---
-- Compares the state's current value with a new value to see if they are equivalent.
function State:isEquivalent<T>(value: T): boolean
	return self._value == value
end

---
-- Connects a callback function that will be called whenever the state's value changes.
-- @param callback The function to call with the new value.
-- @param callImmediately If true, the callback will be called once immediately with the current value.
-- @return A Signal connection that can be disconnected.
function State:observe<T>(callback: (newValue: T) -> nil, callImmediately: boolean?): RBXScriptConnection
	local connection = self._changed:Connect(callback)
	if callImmediately then
		task.spawn(callback, self:get())
	end
	return connection
end

---
-- Links the state's value to an instance's property.
-- The property will be updated immediately and whenever the state changes.
-- @param instance The instance to modify.
-- @param prop The name of the property to change.
-- @return A Signal connection that can be disconnected to stop the link.
function State:linkProperty(instance: Instance, prop: string): RBXScriptConnection
	return self:observe(function(newValue)
		instance[prop] = newValue
	end, true)
end

---
-- Links the state's value to an instance's attribute.
-- The attribute will be updated immediately and whenever the state changes.
-- @param instance The instance to modify.
-- @param prop The name of the property to change.
-- @return A Signal connection that can be disconnected to stop the link.
function State:linkAttribute(instance: Instance, prop: string): RBXScriptConnection
	return self:observe(function(newValue)
		instance:SetAttribute(prop,newValue)
	end, true)
end


---
-- Binds this state to another state. This state's value will be set to the other's
-- value and will update whenever the other state changes.
-- @param other The State object to listen to.
-- @return A Signal connection that can be disconnected to stop the binding.
function State:bind<T>(other: State<T>): RBXScriptConnection
	self:set(other:get())
	return other:observe(function(val)
		self:set(val)
	end)
end


---
-- Creates a new, read-only State by applying a function to the parent state's value.
-- This derived state automatically updates when the parent changes and is cleaned up
-- when the parent is destroyed. It's a convenient shorthand for `State.computed`.
--
-- @param transformFn (parentValue) -> newValue
-- @return {State} A new, read-only derived State.
function State:derive(transformFn): State<any>
	-- 'self' is the original state object
	local sourceState = self

	local derivedState = State.computed(function(use)
		-- Call the user's function with the raw value
		return transformFn(use(sourceState))
	end)
	
	sourceState._trove:Add(derivedState)
	
	return derivedState
end
State.map = State.derive
---
-- Creates a new read-only State that smoothly animates towards the parent state's value over time.
-- The returned State is read-only and its lifecycle is tied to the parent State.
-- Supports numbers, Vector2, Vector3, UDim2, and Color3 by default, or any type with a custom `lerpFn`.
--
-- @param tweenInfo (Optional) A TweenInfo object describing the animation. Defaults to a 0.3s Quad Out tween.
-- @param lerpFn (Optional) A custom function `(start, goal, alpha) -> result` for interpolating unsupported types.
-- @return {State} A new, read-only State with the animated value.
function State:tween(tweenInfo, lerpFn)
	local sourceState = self
	local animatedState = State.new(sourceState:peek())
	sourceState._trove:Add(animatedState)

	local startValue = sourceState:peek()
	local goal = sourceState:peek()
	local alpha = 1 -- Start at 1 so we are 'complete' initially

	local tInfo = tweenInfo or TweenInfo.new(0.3)

	local animationJob = {
		update = function(dt)
			if alpha >= 1 then
				return false -- Animation is complete
			end

			alpha = math.min(1, alpha + dt / tInfo.Time)
			local currentAlpha = game:GetService("TweenService"):GetValue(alpha, tInfo.EasingStyle, tInfo.EasingDirection)

			if not lerpFn and typeof(goal) == 'number' then
				lerpFn = math.lerp
			end

			local result
			if lerpFn then
				result = lerpFn(startValue, goal, currentAlpha)
			else
				result = startValue:Lerp(goal, currentAlpha)
			end

			animatedState:set(result)
			return true -- Animation is still active
		end
	}

	-- When the parent state changes, update the goal and restart the animation.
	sourceState:observe(function(newGoal)
		if newGoal == goal then return end

		startValue = animatedState:peek()
		goal = newGoal
		alpha = 0
		Animator.add(animationJob)
	end)

	-- When the animated state is destroyed, remove its job from the scheduler.
	animatedState._trove:Add(function()
		Animator.remove(animationJob)
	end)
	
	return animatedState
end

---
-- Creates a new read-only State that animates towards the parent state's value using spring physics.
-- The returned State is read-only and its lifecycle is tied to the parent State.
-- Supports numbers and Vector3.
--
-- @param damping (Optional) The spring's damping ratio. Higher values are stiffer. Defaults to 1.
-- @param frequency (Optional) The spring's frequency. Higher values are faster. Defaults to 5.
-- @return {State} A new, read-only State with the animated value.
function State:spring(damping, frequency)
	local sourceState = self
	local animatedState = State.new(sourceState:peek())
	sourceState._trove:Add(animatedState)

	damping = damping or 1
	frequency = frequency or 5

	local velocity
	local valueType = typeof(sourceState:peek())
	if valueType == "number" then
		velocity = 0
	elseif valueType == "Vector3" then
		velocity = Vector3.new()
	else
		error("State:spring only supports number and Vector3 values.", 2)
	end

	local animationJob = {
		update = function(dt)
			local current = animatedState:peek()
			local goal = sourceState:peek()

			local isComplete
			if valueType == "number" then
				isComplete = math.abs(current - goal) < 0.001 and math.abs(velocity) < 0.001
			else -- Vector3
				isComplete = (current - goal).Magnitude < 0.001 and velocity.Magnitude < 0.001
			end

			if isComplete then
				if current ~= goal then animatedState:set(goal) end
				return false -- Animation complete
			end

			-- Spring physics calculation (critically damped spring)
			local f = 1 + 2 * dt * damping * frequency
			local oo = frequency * frequency
			local hoo = dt * oo
			local hhoo = dt * hoo
			local detInv = 1 / (f + hhoo)
			local detX = (f * current) + (dt * velocity) + (hhoo * goal)
			local detV = velocity + (hoo * (goal - current))

			velocity = detV * detInv
			animatedState:set(detX * detInv)

			return true -- Animation active
		end,
	}

	-- When the parent state changes, kickstart the animation.
	sourceState:observe(function()
		Animator.add(animationJob)
	end)

	-- When the animated state is destroyed, remove its job from the scheduler.
	animatedState._trove:Add(function()
		Animator.remove(animationJob)
	end)
	

	return animatedState
end

---
-- Destroys the state object and cleans up all its connections and signals.
function State:destroy()
	self._trove:Destroy()
end


return State
