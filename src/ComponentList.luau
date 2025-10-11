-- ComponentList.lua (Flexible Architecture)
--[[
	A flexible module for managing a collection of components. It can be used in two ways:
	1. As a manual list manager, where components are added/removed imperatively.
	2. As a declarative system, where it automatically syncs with a TableState or State object.

	In both modes, it exposes the managed component collection as a reactive TableState,
	allowing other systems to observe the creation and destruction of components.
]]

-- Dependencies
local Trove = require(script.Parent.Trove)
local State = require(script.Parent.State)
local TableState = require(script.Parent.TableState)

type Trove = Trove.Trove

-- Type Declaration
export type ComponentList<E, C> = typeof(setmetatable({}, {} :: { __index: any })) & {
	-- Manual Control API
	add: (self: ComponentList<E, C>, entry: E, ...any) -> C?,
	remove: (self: ComponentList<E, C>, entry: E) -> (),
	update: (self: ComponentList<E, C>, newEntries: {E}) -> (),

	state: ComponentList<E,C>,

	-- Reactive Output API (Behaves like a TableState of components)
	get: (self: ComponentList<E, C>, entry: E) -> C?,
	produce: (self: ComponentList<E, C>, entry: E, ...any) -> C?,
	ensure: (self: ComponentList<E, C>, entry: E, ...any) -> C?,
	getState: (self: ComponentList<E, C>) -> typeof(State.new({})),

	getTableState: (self: ComponentList<E, C>) -> typeof(TableState.new()),

	peek: (self: ComponentList<E, C>) -> {[E]: C},
	observeEntryAdded: (self: ComponentList<E, C>, callback: (entry: E, component: C) -> ()) -> RBXScriptConnection,
	observe: (self: ComponentList<E, C>, callback: (entry: E, component: C) -> (), callImmediately:boolean) -> RBXScriptConnection,
	observeEntryRemoved: (self: ComponentList<E, C>, callback: (entry: E, component: C) -> ()) -> RBXScriptConnection,
	reduce: (self: ComponentList<E, C>, reducer: (acc: any, component: C, entry: E, use: any) -> any, initialValue: any) -> State.State<any>,

	destroy: (self: ComponentList<E, C>) -> (),
}

-- Module
local ComponentList = {}
ComponentList.__index = ComponentList

--- The basic constructor for creating a manual ComponentList.
function ComponentList.new<E, C>(producer: (entry: E, trove: Trove) -> C): ComponentList<E, C>
	local self = setmetatable({}, ComponentList)

	self._trove = Trove.new()
	self._producer = producer

	-- Internal state to hold the managed components, exposed via a TableState.
	self._componentState = self._trove:Add(TableState.new())
	self._managedTroves = {} -- Maps data entries to their component's trove

	self.state = self._componentState

	-- When a component is removed from our output state, ensure its trove is cleaned up.
	self._trove:Add(self._componentState:observeEntryRemoved(function(entry, _)
		local componentTrove = self._managedTroves[entry]
		if componentTrove then
			self._trove:Remove(componentTrove)
			self._managedTroves[entry] = nil
		end
	end))

	return self
end

--- Declarative constructor that syncs with a TableState.
function ComponentList.fromTableState<E, C>(
	sourceData: typeof(TableState.new()),
	producer: (entry: E, trove: Trove) -> C
): ComponentList<E, C>
	local self = ComponentList.new(producer)

	-- Initial sync
	self:update(sourceData:peek())

	-- Listen for fine-grained changes for efficiency
	self._trove:Add(sourceData:observeEntryAdded(function(entry, _)
		self:add(entry)
	end))
	self._trove:Add(sourceData:observeEntryRemoved(function(entry, _)
		self:remove(entry)
	end))

	return self
end

--- Declarative constructor that syncs with any State object holding a table/array.
function ComponentList.fromState<E, C>(
	sourceState: typeof(State.new({})),
	producer: (entry: E, trove: Trove) -> C
): ComponentList<E, C>
	local self = ComponentList.new(producer)
	self._trove:Add(sourceState:listen(function(newEntries)
		self:update(newEntries or {})
	end))
	return self
end

setmetatable(ComponentList, {
	__call = function(_, producer)
		return ComponentList.new(producer)
	end,
})

--== Public API ==--

---
-- Creates a new derived State object whose value is the result of reducing
-- the component list. The reducer function is re-run whenever the component
-- list changes or any state that is watched with the provided `use` function changes.
-- @param reducerFn The function to execute for each component: `(accumulator, component, entry, use) -> newAccumulator`.
-- @param initialValue The initial value of the accumulator.
-- @return {State} A new computed State object with the reduced value.
function ComponentList:reduce(reducerFn, initialValue)
	-- This method creates and returns a State.computed, configured for reduction.
	return State.computed(function(use)


		-- 1. The top-level dependency is the component list itself.
		-- If any component is added or removed, the entire reduction re-runs.
		local components = use(self:getState())

		-- 2. Run the reduction, passing the `use` function into the reducer.
		local accumulator = initialValue
		for entry, component in pairs(components) do
			-- The user's reducer can now create additional, granular dependencies
			-- on the internal state of each component.
			accumulator = reducerFn(accumulator, component, entry, use)
		end

		-- 3. Return the final aggregated value.
		return accumulator
	end)
end

function ComponentList:add(entry, ...)
	if self._managedTroves[entry] then
		return self._componentState:get(entry)
	end

	local componentTrove = self._trove:Extend()

	local componentInstance = self._producer(entry, componentTrove, ...)

	if componentInstance then
		self._managedTroves[entry] = componentTrove
		self._componentState:set(entry, componentInstance)
	else
		componentTrove:Destroy()
	end

	return componentInstance
end

ComponentList.produce = ComponentList.add
ComponentList.ensure = ComponentList.add

function ComponentList:remove(entry)
	-- Removing the entry from the component state will trigger the
	-- `observeEntryRemoved` listener we set up in .new(), which handles cleanup.
	self._componentState:remove(entry)
end

function ComponentList:update(newEntries)
	local desiredState = {}
	-- The entries in a dictionary are the keys, in an array they are the values
	local isArray = #newEntries > 0 or next(newEntries) == nil

	if isArray then
		for _, entry in ipairs(newEntries) do
			desiredState[entry] = true
			self:add(entry)
		end
	else
		for entry in pairs(newEntries) do
			desiredState[entry] = true
			self:add(entry)
		end
	end

	for entry in pairs(self:peek()) do
		if not desiredState[entry] then
			self:remove(entry)
		end
	end
end

--== Delegate API (Behaves like a TableState) ==--

function ComponentList:get(entry)
	return self._componentState:get(entry)
end

function ComponentList:getState()
	return self._componentState:getState()
end

function ComponentList:getTableState()
	return self._componentState
end

function ComponentList:peek()
	return self._componentState:peek()
end

function ComponentList:observe(callback, callImmediately)
	return self._componentState:observe(callback, callImmediately)
end

function ComponentList:observeEntryAdded(callback)
	return self._componentState:observeEntryAdded(callback)
end

function ComponentList:observeEntryRemoved(callback)
	return self._componentState:observeEntryRemoved(callback)
end

function ComponentList:destroy()
	self._trove:Destroy()
	self._managedTroves = {}
end
ComponentList.Destroy = ComponentList.destroy

return ComponentList
