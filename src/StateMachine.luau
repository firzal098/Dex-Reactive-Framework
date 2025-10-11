-- StateMachine.lua (With Optional Transitions)
--[[
	A module for creating a formal Finite State Machine (FSM). It provides a structured
	way to manage application or character state.

	It can operate in two modes:
	- Strict Mode: If a `transitions` table is provided, it enforces valid state changes.
	- Flexible Mode: If no `transitions` table is provided, any state can transition to any other.
]]

-- Dependencies (ensure paths are correct)
local Trove = require(script.Parent.Trove)
local State = require(script.Parent.State)

-- Type Declaration
export type StateMachine = typeof(setmetatable({}, {} :: { __index: any })) & {
	currentState: typeof(State.new("")),
	onEnter: (self: StateMachine, stateName: string, callback: (trove: Trove) -> ()) -> (),
	transitionTo: (self: StateMachine, newState: string) -> (),
	destroy: (self: StateMachine) -> (),
}

-- Module
local StateMachine = {}
StateMachine.__index = StateMachine

---
-- Creates a new Finite State Machine.
-- @param initialState The name of the starting state.
-- @param transitions (Optional) A dictionary defining valid transitions for Strict Mode.
--   Example: `{ Lobby = {"Intermission"}, Intermission = {"RoundActive"} }`
-- @return {StateMachine} A new StateMachine instance.
function StateMachine.new(initialState: string, transitions: {[string]: {string}}?): StateMachine
	local self = setmetatable({}, StateMachine)

	self._trove = Trove.new()
	self._transitions = transitions -- This can be nil for Flexible Mode
	self._onEnterCallbacks = {}
	self._currentStateTrove = nil

	self.currentState = self._trove:Add(State.new(initialState))

	self._trove:Add(self.currentState:observe(function(newState)
		if self._currentStateTrove then
			self._currentStateTrove:Destroy()
			self._currentStateTrove = nil
		end

		local onEnterCallback = self._onEnterCallbacks[newState]
		if onEnterCallback then
			local newTrove = self._trove:Extend()
			self._currentStateTrove = newTrove
			onEnterCallback(newTrove)
		end
	end, true))

	return self
end

setmetatable(StateMachine, { __call = function(_, initialState, transitions) return StateMachine.new(initialState, transitions) end })


function StateMachine:onEnter(stateName: string, callback: (trove: Trove) -> ())
	assert(typeof(stateName) == "string", "stateName must be a string")
	assert(typeof(callback) == "function", "callback must be a function")
	self._onEnterCallbacks[stateName] = callback
end


function StateMachine:transitionTo(newState: string)
	local currentState = self.currentState:peek()
	if currentState == newState then return end

	-- If we are in Flexible Mode (no transitions defined), always allow the transition.
	if not self._transitions then
		self.currentState:set(newState)
		return
	end

	-- Otherwise, we are in Strict Mode. Validate the transition.
	local validTransitions = self._transitions[currentState]
	local isValid = validTransitions and table.find(validTransitions, newState)

	if isValid then
		self.currentState:set(newState)
	else
		warn(string.format("StateMachine: Invalid transition from '%s' to '%s' attempted.", currentState, newState))
	end
end


function StateMachine:destroy()
	self._trove:Destroy()
end

StateMachine.Destroy = StateMachine.destroy

return StateMachine

