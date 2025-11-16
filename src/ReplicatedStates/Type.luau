--[[
	Type definitions for the ReplicatedState implementation.

	This module uses Luau type annotations to define the structure of
	actions, reducers, parameters, and the ReplicatedState Endpoint itself,
	allowing for better type safety in the calling code.
--]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = {}

local Modules =ReplicatedStorage.Modules
local Promise = require(ReplicatedStorage.Packages.Promise)
local Signal = require(ReplicatedStorage.Modules.Signal)
local Stream = require(ReplicatedStorage.Modules.Stream)
local State = require(ReplicatedStorage.Modules.State)
local Trove = require(ReplicatedStorage.Modules.Trove)
local ComponentList = require(ReplicatedStorage.Modules.ComponentList)

-- EXTERNAL UTILITY TYPES (These are assumed to be available via require, e.g., from replicatedstorage.Modules)
-- Their structural types are defined here for Luau compatibility.

export type Promise<T> = Promise.Promise<T>

export type Signal = typeof(Signal.new())
export type Stream = Stream.Stream
export type Trove = Trove.Trove

export type ComponentList<K, V> = ComponentList.ComponentList<K,V>


-- STANDARD RODUX TYPES
-- A: Represents the concrete structure of an Action
export type Action = {
	type: string,
	[string]: any,
}

-- S: State, A: Action
export type Reducer<S, A> = (state: S, action: A) -> S

-- R: The map of reducers (often passed to Rodux.Store.new)
export type Reducers<S, A> = {
	[string]: Reducer<S, A>
}

-- The internal Rodux Store structure
export type Store<S, A> = {
	dispatch: (self: any, action: A) -> (),
	getState: (self: any) -> S,
	changed: Signal<() -> ()>,
}

-- The function that creates an action (used by Endpoint.actions)
export type ActionCreator<A> = (...any) -> A


-- REPLICATED STATE DEFINITIONS

-- The configuration table passed to ReplicatedState.new()
export type Parameters<S, R> = {
	token: ModuleScript,
	reducers: R, -- R must be a Reducers<S, Action>
	actions: {[string]: (...any) -> any}, -- Raw actions: functions that return data for makeActionCreator
	replication: 'global' | 'per_player',
	initialData: S,
	helper: {[string]: any}?,
	remotes: {
		events: {string}?,
		functions: {string}?,
	},
	validation: (data: S) -> S, -- Used only by the server for initial state validation
}

-- The main Endpoint object returned by ReplicatedState.new()
-- S: The State type, R: The Reducers type
export type Endpoint<S, R> = {
	-- Private Members (internal implementation details)
	_trove: Trove,
	_connections: {[Player]: boolean},
	_dispatchEvent: Signal<(Action) -> ()>,
	_store: Store<S, Action> | nil,
	_connection_promise: Promise<S> | nil,
	_replication: 'global' | 'per_player',
	-- This holds the player-specific endpoints if replication is 'per_player'
	_per_player_endpoints: ComponentList<Player, Endpoint<S, R>> | nil,
	_per_player: boolean,

	-- Public Properties
	playerInitialized: Signal<(player: Player, endpoint: Endpoint<S, R>) -> ()>,
	-- Fired after any action is dispatched and the state changes
	stateChanged: Signal<(actionName: string, action: Action, state: S) -> ()>,

	reducers: R,
	actions: {[string]: ActionCreator<Action>},
	token: ModuleScript,

	remoteEvents: {[string]: RemoteEvent},
	remoteFunctions: {[string]: RemoteFunction},
	helper: {[string]: any},

	-- Public Methods
	dispatch: (self: Endpoint<S, R>, actionData: Action, player: Player?) -> (),
	toStream: (self: Endpoint<S, R>, trove: Trove?) -> Stream<any>,
	toState: (self: Endpoint<S,R>, trove: Trove?) -> State.State<any>,
	getState: (self: Endpoint<S, R>) -> S | nil,
	
	-- Awaits the initial connection/setup and returns the current state
	await: (self: Endpoint<S, R>) -> S,
	onConnect: (self: Endpoint<S, R>) -> Promise<S>,
	-- Server-only methods
	connectPlayer: (self: Endpoint<S, R>, player: Player) -> (),
	disconnectPlayer: (self: Endpoint<S, R>, player: Player) -> (),
	-- Server-only: Initializes a player's isolated state (if 'per_player')
	initializeForPlayer: (self: Endpoint<S, R>, player: Player, initialData: S?) -> Endpoint<S, R> | nil,
	-- Server-only: Retrieves a player's isolated state (if 'per_player')
	getFor: (self: Endpoint<S, R>, player: Player) -> Endpoint<S, R> | nil,
}


return Types
