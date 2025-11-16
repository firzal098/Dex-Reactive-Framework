local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ComponentList = require('./ComponentList')
local Rodux = require('../Packages/rodux')
local Promise = require('./Promise')
local Net = require('./Net')
local Signal = require('./Signal')
local Stream = require('./Stream')
local Trove = require('./Trove')
local State = require('./State')

local DispatchEvent = Net:RemoteEvent('DispatchEvent')
local RequestConnect = Net:RemoteFunction('ConnectRequest')

local ReplicatedState = {}
local Type = require(script.Type)
ReplicatedState.Util = require(script.Util)


local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()

ReplicatedState.rodux = Rodux

local function server_method()
	assert(RunService:IsServer(), 'This method is server-only')
end

local function client_method()
	assert(RunService:IsClient(), 'This method is client-only')
end

local classEndpoint = {}
classEndpoint.__index = classEndpoint

function classEndpoint:dispatch(actionData, player: Player)
	server_method()
	assert(not self._per_player or player ~= nil, "per_player ReplicatedState must specify which player to dispatch action")
	
	if self._per_player_endpoints and player then
		
		local playerEndpoint = self._per_player_endpoints:get(player)

		if playerEndpoint == nil then
			warn('[ReplicatedState] ENDPOINT', player, 'HAS NOT YET SET UP. ACTIONS DROPPED.')
			warn('[ReplicatedState] Warning for Token:', self.token)
		else
			playerEndpoint._store:dispatch(actionData)
		end

	else
		self._store:dispatch(actionData)
	end

end

function classEndpoint:toStream(trove:Trove.Trove)
	
	local trove:Trove.Trove = trove or self._trove
	
	local initialStream = Stream.defer():map(function()
		return self:getState(), {}
	end);
	
	local endpointStream = trove:Add(
		Stream.merge({
			trove:Add(initialStream);
			trove:Add(initialStream:switchMap(function()
				return Stream.fromSignal(self.stateChanged):map(function(actionName, action, state)
					return state, action
				end)				
			end))
		})
	)
	
	return endpointStream
end

function classEndpoint:toState(trove:Trove.Trove?)
	
	local trove = trove or self._trove
	local state = State.fromStream(self:toStream(trove), self:getState())
	
	return state
end

function classEndpoint:getState()
	return self._store and self._store:getState()
end

function classEndpoint:await()
	self._connection_promise:await()
end

function classEndpoint:onConnect()
	return self._connection_promise:andThen(function(...)
		return ...
	end)
end


function classEndpoint:connectPlayer(player:Player)
	server_method()
	self._connections[player] = true
end

function classEndpoint:disconnectPlayer(player)
	server_method()
	self._connections[player] = nil
end

function classEndpoint:initializeForPlayer(player: Player, initialData): Endpoint<any, any>
	server_method()
	assert(self._per_player_endpoints, 'This method is only for per-player ReplicatedState')
	
	return self._per_player_endpoints:ensure(player, initialData)
	
end

function classEndpoint:getFor(player: Player)
	server_method()

	if self._per_player_endpoints ~= nil then
		return self._per_player_endpoints:get(player)
	end
end

function classEndpoint:getForAsync(player: Player): Promise.Promise
	server_method()
	
	if self._per_player_endpoints ~= nil then
		
		local current = self:getFor(player)
		if current then
			return Promise.resolve(current)
		else
			return Promise.fromEvent(self.playerInitialized, function(_player, endpoint)
				return player == _player
			end):andThen(function(_, endpoint)
				return endpoint
			end)
		end
		
	end
	
	return Promise.reject('Not a per-player ReplicatedState')
end

function classEndpoint:mapState(fn: (state:any)->(any)):State.State<any>
	assert(self._state, 'Data is still not loaded')

	return self._state:map(fn)
end
local function constructEndpoint(token: ModuleScript, trove, parameters)
	
	local reducers = parameters.reducers
	local rawActions = parameters.actions
	local replication = parameters.replication
	local helper = parameters.helper or {}

	local actions = {}
	for actionName, fn in rawActions do
		actions[actionName] = Rodux.makeActionCreator(actionName, fn)
	end


	local endpoint = setmetatable({
		_trove = trove;
		_connections = {};
		_dispatchEvent = trove:Add(Signal.new());
		_store = nil;
		_connection_promise = nil;
		_replication = replication;
		_per_player_endpoints = nil;
		_per_player = replication == 'per_player';
		_state = nil;
		
		playerInitialized = trove:Add(Signal.new());
		stateChanged = trove:Add(Signal.new());

		reducers = reducers;
		actions = actions;
		token = token;

		remoteEvents = {};
		remoteFunctions = {};
		helper = helper;
	}, classEndpoint)

	if parameters.remotes then
		if parameters.remotes.events then
			local events = {}
			for _,v in parameters.remotes.events do
				events[v] = Net:RemoteEvent(v)
			end
			endpoint.remoteEvents = events
		end

		if parameters.remotes.functions then
			local functions = {}
			for _,v in parameters.remotes.functions do
				functions[v] = Net:RemoteFunction(v)
			end
			endpoint.remoteFunctions = functions
		end
	end
	local middlewares = nil

	local function stateChangedMiddleware()
		return function(nextDispatch, store)
			return function	(action)

				nextDispatch(action)
				endpoint.stateChanged:Fire(action.type, action, store:getState())

			end
		end
	end

	if IS_SERVER then
		middlewares = {
			function(nextDispatch, store)
				return function(action)
					nextDispatch(action)
					for player in endpoint._connections do
						DispatchEvent:FireClient(player, token, action)
					end
				end
			end,
			stateChangedMiddleware()
		}
	elseif IS_CLIENT then
		middlewares = {
			stateChangedMiddleware()
		}
	end

	if IS_CLIENT then

		endpoint._connection_promise  = trove:AddPromise(
			Promise.try(function()
				return RequestConnect:InvokeServer(token)
			end)
				:andThen(function(latestData)

					endpoint._store = trove:Add(
						Rodux.Store.new(reducers, latestData, middlewares),
						'destruct'
					)

					endpoint._dispatchEvent:Connect(function(actionData)
						endpoint._store:dispatch(actionData)
					end)

					endpoint._state = endpoint:toState()
					return latestData
				end)
				:catch(function(err)
					warn('Error while trying to connect to endpoint', token, ':')
					warn(err)
				end)
		)
	else
		local initialData = parameters.initialData
		
		
		
		if replication == 'global' then

			endpoint._store = trove:Add(
				Rodux.Store.new(reducers, initialData, middlewares),
				'destruct'
			)
			
			endpoint._state = endpoint:toState()
			endpoint._connection_promise = Promise.resolve(initialData)

		elseif replication == 'per_player' then

			endpoint._per_player_endpoints = trove:Add(
				ComponentList.new(function(player: Player, trove, _playerInitialData)
					
					_playerInitialData = _playerInitialData or initialData

					if parameters.validation then
						_playerInitialData = parameters.validation(_playerInitialData)
					end
					
					local playerEndpoint =  constructEndpoint(token, trove, {
						replication = 'global',
						reducers = parameters.reducers,
						actions = parameters.actions,
						initialData = _playerInitialData,
						helper = helper,
					})
				
					endpoint.playerInitialized:Fire(player, playerEndpoint)
					
					return playerEndpoint
				end)
			)

			endpoint._connection_promise = Promise.resolve(initialData)
		end
	end

	return endpoint
end

local endpoints = ComponentList.new(function(token: ModuleScript, trove, parameters)
	return constructEndpoint(token, trove, parameters)
end)

local a = endpoints:get(script)

function ReplicatedState.new<T>(parameters: T)
	local token: ModuleScript = parameters.token
	
	return endpoints:ensure(token, parameters)
end


function ReplicatedState.setup(folder: Folder)
	server_method()
	
	for _, token: ModuleScript in folder:GetChildren() do
		if token:IsA('ModuleScript') then
			local parameters = require(token)
			parameters.token = token
			
			ReplicatedState.new(parameters)
		end
	end
end

local function main()
	
	if IS_CLIENT then
		
		while not script:GetAttribute('ServerInitialized') do
			script:GetAttributeChangedSignal('ServerInitialized'):Wait()
		end
		
		DispatchEvent.OnClientEvent:Connect(function(token, ...)
			if endpoints:get(token) then
				endpoints:get(token)._dispatchEvent:Fire(...)
			end
		end)
		
		script:SetAttribute('ClientInitialized', true)
		
	elseif IS_SERVER then
		
		RequestConnect.OnServerInvoke = function(player: Player, token)
			local endpoint = endpoints:get(token)
			if endpoint then
				
				if endpoint._per_player_endpoints then
					local playerEndpoint = endpoint._per_player_endpoints:get(player)
					
					if playerEndpoint == nil then
							
						local connection
						
						playerEndpoint = Promise.new(function(resolve)
							
							print('[ReplicatedState] Waiting for endpoint initialization for',player,'.... (Token:', endpoint.token,')')
						
							connection = endpoint._per_player_endpoints:observeEntryAdded(function(_player, endpoint)
								if player == _player then
									resolve(endpoint)
								end
							end)
							
						end):finally(function()
							if connection then
								connection:Disconnect()
							end
						end):expect()
						
					end
					
					if playerEndpoint then
						playerEndpoint:connectPlayer(player)
						
						return playerEndpoint._store:getState()
					end
				else
					endpoint:connectPlayer(player)
					
					return endpoint._store:getState()
				end
				
				
			end
			warn('Invalid token:',token)
			error('Invalid Token')
		end
		
		Players.PlayerRemoving:Connect(function(player: Player)
			for _, endpoint in endpoints:peek() do
				if endpoint._per_player then
					-- For per-player, the only thing to do is remove their component
					endpoint._per_player_endpoints:remove(player)
				else
					-- For global, disconnect them from the main list
					endpoint:disconnectPlayer(player)
				end
			end
		end)
		
		script:SetAttribute('ServerInitialized', true)
	end
	
	return ReplicatedState
end

export type Endpoint<S,R> = Type.Endpoint<S,R>

return main()
