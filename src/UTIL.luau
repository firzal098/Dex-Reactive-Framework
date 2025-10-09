local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Signal = require(ReplicatedStorage.Packages.Signal)

local defaultTweenInfo = TweenInfo.new(0.3)
local util = {}

function util.instance(name: string, parent: Instance, props: {[string]: any}, childs: {Instance})
	local v = Instance.new(name) 
	for prop,propValue in props do
		v[prop] = propValue
	end	
	if childs then
		for _,v in childs do
			v.Parent = v
		end
	end
	v.Parent = parent
	return v
end

function util.character(player: Player?, fn)
	player = player or game.Players.LocalPlayer
	if player.Character then
		task.spawn(fn, player.Character)
	end
	return player.CharacterAdded:Connect(fn)
end

function util.Tween(instance:Instance, props:{[string]:any}, optionalTweenInfo: TweenInfo?)
	local Tween = TweenService:Create(instance,optionalTweenInfo or defaultTweenInfo, props)
	Tween:Play()
	return Tween
end

function util.loadModules(source: Instance)
	for _,v in source:GetChildren() do
		if v:IsA('ModuleScript') then
			task.spawn(require,v)
		else
			util.loadModules(v)
		end
	end
end

function util.createListener(signal, container)
	container = container or {}
	
	local new = Signal.new()
	
	signal:Connect(function(key,value)
		container[key]=value
		new:Fire(key,value)
	end)
	
	return function(fn)
		for key,value in container do
			task.spawn(fn,key,value)
		end
		return new:Connect(function(key,value)
			fn(key,value)
		end)
	end
end

function util.waitUntilLoaded()
	while not game:IsLoaded() do
		game.Loaded:Wait()
	end
end

function util.setAttributes(instance:Instance, attributes: {[string]: any})
	for key,value in attributes do
		instance:SetAttribute(key,value)
	end
end

function util.waitForAttribute(instance:Instance, attribute: string)
	while instance:GetAttribute(attribute) == nil do
		instance:GetAttributeChangedSignal(attribute):Wait()
	end
	return instance:GetAttribute(attribute)
end

function util.formatToRupiah(amount)
	local formatted = tostring(amount)
	local result = ""
	local count = 0

	for i = #formatted, 1, -1 do
		local digit = formatted:sub(i, i)
		count = count + 1
		result = digit .. result
		if count % 3 == 0 and i > 1 then
			result = "," .. result
		end
	end

	return "Rp. " .. result
end

local headshotCache = {}
function util.getPlayerHeadshot(player: Player)
	if not headshotCache[player] then
		local userId = player.UserId
		local thumbType = Enum.ThumbnailType.HeadShot
		local thumbSize = Enum.ThumbnailSize.Size420x420
		local content, isReady = game.Players:GetUserThumbnailAsync(userId, thumbType, thumbSize)
		headshotCache[player] = content
	end
	
	return headshotCache[player]
end

function util.troveBatch(trove, cleanups)
	for _,v in cleanups do
		trove:Add(v)
	end
end

return util
