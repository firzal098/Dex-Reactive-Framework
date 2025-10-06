--[[
	PriorityQueue Module
	
	Description:
	A module to handle a priority queue. You can insert items (which are wrapped in State objects) 
	with a numerical priority and an optional duration. The module retrieves the item with the 
	lowest priority number that has not expired. Items with a duration are automatically 
	removed in real-time when they expire.

	The `.value` property is a State object that always reflects the value of the current 
	highest-priority item. The `.changed` signal fires with this raw value whenever the top of 
	the queue changes.

	Usage:
	1. Place this script as a ModuleScript.
	2. Ensure 'State.lua', 'Signal.lua', and 'Trove.lua' modules are where this script can access them.
	3. Require this module in another script to use it.
	
	Example 1 (Standard):
	local myTasks = PriorityQueue.new(function(newValue)
		if newValue then
			print("New highest priority task:", newValue)
		else
			print("The task queue is now empty.")
		end
	end)
	
	local temporaryTask = myTasks:insert("A temporary task", 1, 5) -- Lasts 5 seconds
	myTasks:insert("A permanent task", 2) 

	Example 2 (Instance-based):
	-- A client might create a queue that monitors a folder.
	local myTasksFromFolder = PriorityQueue.new(nil, workspace.TaskFolder)

	-- A server can create a task instance without needing a queue object.
	local taskInstance = PriorityQueue.createInstance("A new server-created task", 1)
	taskInstance.Parent = workspace.TaskFolder -- The client's queue will automatically pick this up.

	-- When you're done, destroy the queue to clean up background tasks.
	-- myTasks:destroy()
]]

-- Services & Dependencies
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage.Packages

-- Make sure the paths to your modules are correct
local State = require(script.Parent.State)
local Signal = require(Packages.Signal)
local Trove = require(Packages.Trove)

-- Type Imports & Forward Declarations
type State<T> = State.State<T>
type Trove = typeof(Trove.new())
type Signal = typeof(Signal.new())

local PriorityQueue -- Forward-declaration for circular type reference

--[[
	Type Definitions
	These types are exported for use in other scripts.
]]

--- Represents a single item within the PriorityQueue.
export type QueueItem<T> = {
	--- The State object holding the item's value.
	value: State<T>,
	--- The numerical priority of the item. Lower numbers have higher priority.
	priority: State<number>,
	--- The `os.clock()` time at which the item expires and should be removed.
	expiration_time: number?,
	--- A reference to the parent queue this item belongs to.
	queue: PriorityQueue,
	--- A reactive State object to control the item's visibility in the queue. Setting to true hides it.
	hidden: State<boolean>,
	--- A trove for managing connections and objects related to this item.
	_trove: Trove?,
	--- Removes the item from its queue.
	remove: (self: QueueItem<T>) -> (),
	--- Sets or updates the item's expiration time.
	expire: (self: QueueItem<T>, duration: number) -> (),
	--- Temporarily hides the item by setting its `hidden` state to true.
	hide: (self: QueueItem<T>) -> (),
	--- Unhides the item by setting its `hidden` state to false.
	unhide: (self: QueueItem<T>) -> (),
	--- An alias for `unhide`.
	enable: (self: QueueItem<T>) -> (),
	--- An alias for `hide`.
	disable: (self: QueueItem<T>) -> (),
}

--- The main PriorityQueue object.
export type PriorityQueue = {
	--// Properties //--

	--- A State object whose value is always the raw value of the highest-priority item.
	value: State<any?>,
	--- A Signal that fires with the raw value whenever the highest-priority item changes.
	changed: Signal,

	--// Private Properties //--

	--- The internal array storing all QueueItem objects.
	_data: { QueueItem<any> },
	--- A flag to control the background expiration-checking loop.
	_active: boolean,
	--- An internal State that holds the State object of the current highest-priority item.
	_current_head: State<State<any>?>,
	--- The main Trove for cleaning up all connections and objects created by this queue.
	_trove: Trove,

	--// Methods //--

	--- Inserts a value into the queue with a given priority.
	insert: <T>(self: PriorityQueue, value: T | State<T>, priority: number, duration: number?) -> QueueItem<T>?,
	--- Retrieves and removes the State object with the highest priority from the queue.
	retrieve: (self: PriorityQueue) -> State<any>?,
	--- Peeks at the highest-priority State object without removing it.
	peek: (self: PriorityQueue) -> State<any>?,
	--- Cleans up the queue, stopping background tasks and destroying all items.
	destroy: (self: PriorityQueue) -> (),
	--- An alias for `destroy`.
	Destroy: (self: PriorityQueue) -> (),
	--- Checks if the queue is empty.
	is_empty: (self: PriorityQueue) -> boolean,
	--- Returns the number of items in the queue.
	size: (self: PriorityQueue) -> number,

	--// Internal Methods //--

	--- Updates the internal head state based on the current highest-priority item.
	_update_head: (self: PriorityQueue) -> (),
	--- Links a Roblox Instance's lifetime to a queue item.
	_linkInstanceToItem: (self: PriorityQueue, instance: Instance, item: QueueItem<any>) -> (),
}


-- Module Table
local priority_queue = {}
priority_queue.__index = priority_queue

-- Metatable for items in the queue to give them methods like :remove()
local QueueItemMT = {}
QueueItemMT.__index = QueueItemMT

---
-- Removes the item from its associated queue.
-- This cleans up the item's State object and any instance links.
function QueueItemMT:remove()
	if not self.queue then return end

	local queue: PriorityQueue = self.queue
	local queue_data = queue._data

	for i = #queue_data, 1, -1 do
		if queue_data[i] == self then
			-- Clean up the item's trove, which handles the hidden state, instance links, etc.
			if self._trove then
				self._trove:Destroy()
			end
			self.value:destroy()
			table.remove(queue_data, i)
			self.queue = nil
			queue:_update_head()
			break
		end
	end
end

---
-- Sets or updates the expiration time for this item.
-- @param duration The number of seconds from now until the item expires.
function QueueItemMT:expire(duration: number)
	self.expiration_time = os.clock() + duration
end

---
-- Temporarily hides the item by setting its `hidden` state to true.
-- The queue will reactively update to find the next highest-priority item.
function QueueItemMT:hide()
	self.hidden:set(true)
end

---
-- Makes a hidden item visible again by setting its `hidden` state to false.
-- The queue will reactively update.
function QueueItemMT:unhide()
	self.hidden:set(false)
end

-- Aliases for hide/unhide
QueueItemMT.disable = QueueItemMT.hide
QueueItemMT.enable = QueueItemMT.unhide


--// Constructor & Static Methods //--

---
-- Creates and returns a new, empty priority queue object.
-- @param handler An optional function to call when the highest-priority item changes.
-- @param instanceFolder An optional Folder instance to monitor for new task instances.
-- @return A new PriorityQueue object.
function priority_queue.new(handler: ((newValue: any?) -> ())?, instanceFolder: Folder?): PriorityQueue
	local self = setmetatable({}, priority_queue)

	self._data = {}
	self._active = true
	self._trove = Trove.new()

	-- _current_head holds a State of the *highest priority State object*
	self._current_head = self._trove:Add(State.new(nil))
	-- self.value holds a State of the *value inside the highest priority State object*
	self.value = self._trove:Add(State.new(nil))

	self.changed = self._trove:Construct(Signal)

	-- Bind self.value to the value of the head state
	self._trove:Add(self._current_head:listen(function(head: State<any>?, trove: Trove)
		if head then
			trove:Add(self.value:bind(head))
		else
			self.value:set(nil)
		end
	end))

	-- Fire the public 'changed' signal when the final value changes
	self._trove:Add(self.value:observe(function(value: any)
		self.changed:Fire(value)
	end))

	if handler and typeof(handler) == "function" then
		self._trove:Connect(self.changed, handler)
	end

	-- Internal helper to link an existing instance to a new queue item
	local function linkInstance(instance: Instance)
		if not instance:IsA("Configuration") or instance:GetAttribute("__PriorityQueueLinked") then
			return
		end

		local value = instance:GetAttribute("value")
		local priority = instance:GetAttribute("priority")

		if value == nil or priority == nil or typeof(priority) ~= "number" then
			warn("PriorityQueue: Link failed - Instance '"..instance.Name.."' is missing required attributes 'value' or 'priority', or priority is not a number.")
			return
		end

		local duration = instance:GetAttribute("duration")
		local item = self:insert(value, priority, duration)

		if item then
			self:_linkInstanceToItem(instance, item)
		end
	end

	-- If a folder is provided, automatically populate the queue and listen for new children
	if instanceFolder and typeof(instanceFolder) == "Instance" and instanceFolder:IsA("Folder") then
		for _, instance in ipairs(instanceFolder:GetChildren()) do
			linkInstance(instance)
		end
		self._trove:Connect(instanceFolder.ChildAdded, linkInstance)
	end

	-- Start a background thread to check for and remove expired items
	self._trove:Add(task.spawn(function()
		while self._active do
			local now = os.clock()
			-- Iterate backwards to safely remove items while looping
			for i = #self._data, 1, -1 do
				local item = self._data[i]
				if item and item.expiration_time and now > item.expiration_time then
					item:remove()
				end
			end
			task.wait(0.1)
		end
	end))

	return self
end

---
-- A static helper function to create an Instance with the correct attributes
-- for a queue to consume when using the `instanceFolder` feature.
-- @param value The value of the task.
-- @param priority The priority of the task (lower is higher).
-- @param duration An optional duration in seconds.
-- @return A new Configuration instance with the specified attributes.
function priority_queue.createInstance(value: any, priority: number, duration: number?): Instance
	local instance = Instance.new("Configuration")
	instance:SetAttribute("value", value)
	instance:SetAttribute("priority", priority)
	if duration then
		instance:SetAttribute("duration", duration)
	end
	return instance
end


--// Internal Methods //--

---
-- Checks if the head item has changed and updates the internal `_current_head` state.
-- This triggers the chain reaction that updates the public `.value` state.
function priority_queue:_update_head()
	local new_head = self:peek()
	if self._current_head:get() ~= new_head then
		self._current_head:set(new_head)
	end
end

---
-- Links an instance's lifetime to a queue item, so destroying the instance
-- also removes the item from the queue.
-- @param instance The instance to link.
-- @param item The queue item to link it to.
function priority_queue:_linkInstanceToItem(instance: Instance, item: QueueItem<any>)
	if not item._trove then return end

	-- Tag the instance to prevent it from being re-linked by the folder listener
	instance:SetAttribute("__PriorityQueueLinked", true)

	-- When the instance is destroyed, remove the item from the queue.
	item._trove:Connect(instance.Destroying, function()
		item:remove()
	end)

	-- When the item is removed by other means (retrieve, expire), untag the instance
	item._trove:Add(function()
		if instance and instance.Parent then -- Check if instance still exists
			instance:SetAttribute("__PriorityQueueLinked", nil)
		end
	end)
end


--// Public Methods //--

---
-- Inserts a value into the queue with a given priority.
-- If the value is not a State object, it's converted automatically.
-- @param value The value to insert. Can be a raw value or a State object.
-- @param priority The priority of the item (lower number is higher priority).
-- @param duration An optional duration in seconds until the item expires.
-- @return The created queue item, which has a `:remove()` method.
function priority_queue:insert<T>(value: T | State<T>, priority: number, duration: number?)
	local state_value: State<T>
	if State.is(value) then
		state_value = value
	else
		state_value = State.new(value)
	end

	if typeof(priority) ~= "number" then
		warn("priority_queue:insert() - Priority must be a number. Got "..typeof(priority))
		return nil
	end

	local expiration_time = nil
	if duration and typeof(duration) == "number" then
		expiration_time = os.clock() + duration
	end

	local new_item: QueueItem<T> = {
		value = state_value,
		priority = State(priority),
		expiration_time = expiration_time,
		queue = self,
		hidden = State.new(false),
		_trove = Trove.new(),
	}

	setmetatable(new_item, QueueItemMT)

	-- Add the hidden state to the item's trove so it's destroyed automatically
	new_item._trove:Add(new_item.hidden)
	-- Listen for changes to the hidden state and update the queue's head
	new_item._trove:Add(new_item.hidden:observe(function()
		self:_update_head()
	end))
	
	new_item._trove:Add(new_item.priority)
	
	new_item.priority:observe(function()
		self:_update_head()
	end)

	table.insert(self._data, new_item)
	self:_update_head()

	return new_item :: QueueItem<T>
end

---
-- Retrieves and removes the State object with the lowest priority number from the queue.
-- Expired items are skipped and removed.
-- @return The State object with the highest priority, or nil if the queue is empty.
function priority_queue:retrieve(): State<any>?
	while #self._data > 0 do
		local lowest_priority = math.huge
		local index_of_lowest = -1

		for i, item in ipairs(self._data) do
			if item.hidden:get() then continue end

			if item.priority:get() < lowest_priority then
				lowest_priority = item.priority:get()
				index_of_lowest = i
			end
		end

		if index_of_lowest == -1 then
			break -- No visible items found
		end

		local candidate = self._data[index_of_lowest]

		-- Double-check expiration before retrieving
		if candidate.expiration_time and os.clock() > candidate.expiration_time then
			candidate:remove() -- This will trigger a loop to find the next best
		else
			local retrieved_state = candidate.value
			candidate:remove() -- This removes the item and updates the head
			return retrieved_state
		end
	end

	-- If the loop finishes without returning, the queue is empty of valid items
	self:_update_head()
	return nil
end

---
-- Peeks at the next valid (non-expired, visible) State object without removing it.
-- @return The highest-priority State object, or nil if none exists.
function priority_queue:peek(): State<any>?
	local lowest_priority = math.huge
	local value_of_lowest: State<any>? = nil
	local now = os.clock()

	for _, item in ipairs(self._data) do
		if item.hidden:get() then continue end

		-- Ensure the item is not expired before considering it
		if not (item.expiration_time and now > item.expiration_time) then
			if item.priority:get() < lowest_priority then
				lowest_priority = item.priority:get()
				value_of_lowest = item.value
			end
		end
	end

	return value_of_lowest
end

---
-- Cleans up the queue, stopping background checks, and destroying all contained items.
-- Call this when the queue is no longer needed to prevent memory leaks.
function priority_queue:destroy()
	self._active = false

	-- Destroy items in reverse to avoid table shifting issues
	for i = #self._data, 1, -1 do
		self._data[i]:remove()
	end
	self._data = {}

	self._trove:Destroy()
end

-- Alias for destroy
priority_queue.Destroy = priority_queue.destroy


--// Utility Functions //--

---
-- Checks if the queue is empty.
-- @return True if the queue has no items, false otherwise.
function priority_queue:is_empty(): boolean
	return #self._data == 0
end

---
-- Returns the total number of items currently in the queue.
-- @return The number of items.
function priority_queue:size(): number
	return #self._data
end

return priority_queue
