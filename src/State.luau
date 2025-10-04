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

-- Forward declaration of the State type
export type State<T> = typeof(setmetatable({}, {} :: { __index: any })) & {
	_value: T,
	_changed: Signal,
	_trove: Trove,
	_isDeferred: boolean,

	get: (self: State<T>) -> T,
	peek: (self: State<T>) -> T,
	set: (self: State<T>, newValue: T) -> State<T>,
	observe: (self: State<T>, callback: (newValue: T) -> (), callImmediately: boolean?) -> RBXScriptConnection,
	listen: (self: State<T>, callback: (newValue: T, trove: Trove) -> ()) -> Trove,
	linkProperty: (self: State<T>, instance: Instance, prop: string) -> RBXScriptConnection,
	linkAttribute: (self: State<T>, instance: Instance, attribute: string) -> RBXScriptConnection,
	bind: (self: State<T>, other: State<T>) -> RBXScriptConnection,
	deferred: (self: State<T>) -> State<T>,
	immediate: (self: State<T>) -> State<T>,
	destroy: (self: State<T>) -> (),
	default: (self: State<T>, value: any) -> State<T>,
}

export type Trove = typeof(Trove.new())
-- Module
local State = {}
State.__index = State

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
	assert(typeof(instance)=='Instance', 'First argument must be Instance')
	
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
		-- We use a "silent set" here by directly modifying the internal value
		-- and then firing the signal. This avoids a potential recursive loop if
		-- the user's function somehow calls :set() on `current`.
		if current._value ~= newValue then
			current._value = newValue
			current._changed:Fire(newValue)
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
function State.hydrate(instance: Instance, props: {[string]: any}): (Instance, Trove)
	local cleanupTrove = Trove.new()

	for propName, value in pairs(props) do
		if State.is(value) then
			-- If the value is a State object, create a reactive link.
			local connection = value:linkProperty(instance, propName)
			cleanupTrove:Add(connection)
		else
			-- If it's a static value, just set the property directly.
			instance[propName] = value
		end
	end

	-- Automatically tie the cleanup trove's lifecycle to the instance.
	cleanupTrove:AttachToInstance(instance)

	return instance, cleanupTrove
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
	
	self._trove:Add(activeTrove)

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
-- The property will be updated immediately and whenever the state changes.
-- @param instance The instance to modify.
-- @param prop The name of the property to change.
-- @return A Signal connection that can be disconnected to stop the link.
function State:linkAttribute(instance: Instance, attribute: string): RBXScriptConnection
	return self:observe(function(newValue)
		instance:SetAttribute(attribute,newValue)
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
-- Destroys the state object and cleans up all its connections and signals.
function State:destroy()
	self._trove:Destroy()
end



return State
