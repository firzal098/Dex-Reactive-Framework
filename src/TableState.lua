-- TableState.lua
--[[
	A derived state module that specializes in managing tables. It provides
	a simple and direct API for mutating table state without needing to manually
	clone the table for each change.

	It offers fine-grained signals to observe when specific entries are
	added, updated, or removed, which is more powerful than the single `changed`
	signal from a standard State object.
]]

-- Dependencies
local Trove = require(script.Parent.Trove) --! UPDATE THIS PATH if needed
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(script.Parent.State) --! UPDATE THIS PATH if needed

local Signal = require(ReplicatedStorage.Packages.Signal) --! UPDATE THIS PATH if needed

-- Type Declaration
export type TableState<K, V> = typeof(setmetatable({}, {} :: { __index: any })) & {
	set: (self: TableState<K, V>, key: K, value: V) -> (),
	remove: (self: TableState<K, V>, key: K) -> (),
	insert: (self: TableState<K, V>, value: V) -> number,
	clear: (self: TableState<K, V>) -> (),
	reconcile: (self: TableState<K, V>, newTable: {[K]: V}) -> (),
	sync: (self: TableState<K, V>, newTable: {[K]: V}) -> (),
	bind: (self: TableState<K, V>, other: TableState<K, V>) -> RBXScriptConnection,
	
	state: TableState<K,V>,

	get: (self: TableState<K, V>, key: K) -> V?,
	getState: (self: TableState<K, V>) -> typeof(State.new({})),
	peek: (self: TableState<K, V>) -> {[K]: V},

	observe: (self: TableState<K, V>, callback: (newTable: {[K]: V}) -> (), callImmediately: boolean?) -> RBXScriptConnection,
	observeEntryAdded: (self: TableState<K, V>, callback: (key: K, value: V) -> ()) -> RBXScriptConnection,
	observeEntryUpdated: (self: TableState<K, V>, callback: (key: K, newValue: V, oldValue: V) -> ()) -> RBXScriptConnection,
	observeEntryRemoved: (self: TableState<K, V>, callback: (key: K, oldValue: V) -> ()) -> RBXScriptConnection,

	destroy: (self: TableState<K, V>) -> (),
	Destroy: (self: TableState<K, V>) -> (),
}

-- Module
local TableState = {}
TableState.__index = TableState

local function shallowCopy(original)
	local copy = {}
	for k, v in pairs(original) do
		copy[k] = v
	end
	return copy
end


---
-- Creates a new TableState object.
-- @param initialTable An optional table to initialize the state with.
-- @return {TableState} A new TableState instance.
function TableState.new<K, V>(initialTable: {[K]: V}?): TableState<K, V>
	local self = setmetatable({}, TableState)

	assert(initialTable == nil or typeof(initialTable) == "table", "initialValue must be a table or nil")

	self._trove = Trove.new()
	self._state = self._trove:Add(State.new(initialTable or {}))
	
	self.state = self._state

	-- Fine-grained signals for specific table changes
	self._onEntryAdded = self._trove:Add(Signal.new())
	self._onEntryUpdated = self._trove:Add(Signal.new())
	self._onEntryRemoved = self._trove:Add(Signal.new())

	return self
end

-- Allows creating with `TableState(...)` instead of `TableState.new(...)`.
setmetatable(TableState, {
	__call = function(_, initialValue)
		return TableState.new(initialValue)
	end,
})


---
-- Sets or updates a key-value pair in the table.
-- Fires `onEntryAdded` or `onEntryUpdated` accordingly.
function TableState:set(key, value)
	local oldTable = self._state:peek()
	local oldValue = oldTable[key]

	if oldValue == value then return end

	local newTable = shallowCopy(oldTable)
	newTable[key] = value
	self._state:set(newTable)

	if oldValue == nil then
		self._onEntryAdded:Fire(key, value)
	else
		self._onEntryUpdated:Fire(key, value, oldValue)
	end
end

---
-- Removes a key from the table.
-- Fires `onEntryRemoved` if the key existed.
function TableState:remove(key)
	local oldTable = self._state:peek()
	if oldTable[key] == nil then return end

	local oldValue = oldTable[key]
	local newTable = shallowCopy(oldTable)
	newTable[key] = nil
	self._state:set(newTable)

	self._onEntryRemoved:Fire(key, oldValue)
end


---
-- Binds this TableState to another TableState in one direction.
-- This state will automatically synchronize its contents to match the `other` state.
-- Any manual changes to this state will be overwritten by the binding.
-- @param other The TableState to listen to.
-- @return A connection that can be added to a trove for cleanup.
function TableState:bind(other)
	assert(getmetatable(other) == TableState, "Argument to :bind must be a TableState.")

	-- 1. Initial Sync: Immediately run our :sync method to match the other's current state.
	self:sync(other:peek())

	-- 2. Ongoing Sync: Observe the other's underlying State object.
	-- Whenever it changes, re-run our :sync method.
	return other:getState():observe(function(newTable)
		self:sync(newTable)
	end)
end

---
-- Inserts a value into the table (for array-like tables).
-- Fires `onEntryAdded`.
-- @return The index where the value was inserted.
function TableState:insert(value)
	local oldTable = self._state:peek()
	local newTable = shallowCopy(oldTable)
	table.insert(newTable, value)
	self._state:set(newTable)

	local newIndex = #newTable
	self._onEntryAdded:Fire(newIndex, value)
	return newIndex
end

---
-- Removes all entries from the table.
-- Fires `onEntryRemoved` for every entry that was removed.
function TableState:clear()
	local oldTable = self._state:peek()
	if next(oldTable) == nil then return end

	self._state:set({})

	for key, oldValue in pairs(oldTable) do
		self._onEntryRemoved:Fire(key, oldValue)
	end
end

---
-- Merges another table into the current state.
-- Overwrites existing keys and adds new ones. Does not remove keys.
function TableState:reconcile(newValues)
	local oldTable = self._state:peek()
	local newTable = shallowCopy(oldTable)

	for key, value in pairs(newValues) do
		local oldValue = newTable[key]
		if oldValue ~= value then
			newTable[key] = value
			if oldValue == nil then
				self._onEntryAdded:Fire(key, value)
			else
				self._onEntryUpdated:Fire(key, value, oldValue)
			end
		end
	end

	self._state:set(newTable)
end

---
-- Synchronizes the state to exactly match the new table provided.
-- This will add new entries, update existing ones, and REMOVE entries
-- that are not present in the new table.
-- @param newTable The definitive new state for the table.
function TableState:sync(newTable)
	local oldTable = self._state:peek()

	if oldTable == newTable then return end

	-- The newTable is the final state. No need to copy.
	self._state:set(newTable)

	-- Check for added or updated entries
	for key, newValue in pairs(newTable) do
		local oldValue = oldTable[key]
		if oldValue == nil then
			self._onEntryAdded:Fire(key, newValue)
		elseif oldValue ~= newValue then
			self._onEntryUpdated:Fire(key, newValue, oldValue)
		end
	end

	-- Check for removed entries
	for key, oldValue in pairs(oldTable) do
		if newTable[key] == nil then
			self._onEntryRemoved:Fire(key, oldValue)
		end
	end
end


---
-- Gets the value for a specific key.
function TableState:get(key)
	return self._state:peek()[key]
end

---
-- Returns a direct reference to the underlying State object.
function TableState:getState()
	return self._state
end

---
-- Returns the raw, underlying table.
function TableState:peek()
	return self._state:peek()
end

---
-- Observes the entire table for any change.
function TableState:observe(callback, callImmediately)
	return self._state:observe(callback, callImmediately)
end

---
-- Connects a callback that fires when a new entry is added.
function TableState:observeEntryAdded(callback)
	return self._onEntryAdded:Connect(callback)
end

---
-- Connects a callback that fires when an existing entry is updated.
function TableState:observeEntryUpdated(callback)
	return self._onEntryUpdated:Connect(callback)
end

---
-- Connects a callback that fires when an entry is removed.
function TableState:observeEntryRemoved(callback)
	return self._onEntryRemoved:Connect(callback)
end


---
-- Destroys the TableState and cleans up all internal resources.
function TableState:destroy()
	self._trove:Destroy()
end

TableState.Destroy = TableState.destroy

return TableState

