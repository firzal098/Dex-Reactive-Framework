local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Input = {}
Input.__index = Input

local Context = {}
Context.__index = Context

local Constructor = {}

local Signal = require(ReplicatedStorage.Packages.Signal)
local State = require(script.Parent.State)
local Trove = require(ReplicatedStorage.Packages.Trove)


function Input.addInput(self: Input, raw: RawInput)
	
	table.insert(self._rawInputs, raw)
	
	if typeof(raw) == 'EnumItem' and  (raw.EnumType==Enum.KeyCode or raw.EnumType==Enum.UserInputType) then
		
		self._trove:Connect(UserInputService.InputBegan, function(input: InputObject, gameProcessedEvent: boolean) 
			if gameProcessedEvent then return end
			if input.UserInputType==raw or input.KeyCode==raw then
				self:press()			
			end	
		end)
		self._trove:Connect(UserInputService.InputEnded, function(input: InputObject, gameProcessedEvent: boolean) 
			if gameProcessedEvent then return end
			if input.UserInputType==raw or input.KeyCode==raw then
				self:pressEnd()
			end	
		end)
		
	elseif Signal.Is(raw) or typeof(raw)=='RBXScriptSignal' then
		
		self._trove:Connect(raw, function(...: any) 
			local id = self:press()
			task.delay(0.05, function()
				self:pressEnd(id)	
			end)
		end)
	
	elseif typeof(raw)=='Instance' and raw:IsA('GuiButton') then
		
		self._trove:Connect(raw.MouseButton1Down, function()
			self:press()
		end)
		self._trove:Connect(raw.MouseButton1Up, function()
			self:pressEnd()
		end)
		
	elseif typeof(raw)=='string' then
		
		for _,v in CollectionService:GetTagged(raw) do
			self:addInput(v)
		end
		self._trove:Connect(CollectionService:GetInstanceAddedSignal(raw), function(v)
			self:addInput(v)
		end)
		
	end
end


function Input.press(self: Input)
	local isPressed = self.Pressed:get()

	if not self.Enabled:get() then return end
	if isPressed then return end
	
	local pressId = self._pressId + 1
	self._pressId = pressId
	
	self.Pressed:set(true)
	return pressId
end

function Input.pressEnd(self: Input, id:number)

	if not self.Enabled:get() then return end
	if id and id ~= self._pressId then return end	
	self.Pressed:set(false)
end

function Input.Destroy(self: Input)
	self._trove:Destroy()
end

function Input.onPress(self: Input, fn)
	return self._pressed:Connect(fn)
end

function Input.setContext(self: Input, context: Context)
	self.Context:set(context)
end


function Constructor.context(inputs: {Input})
	
	local self = setmetatable({
		Enabled = State(true);
	},Context)
	
	return self
end

function Constructor.input(inputs: {RawInput})
	local _trove = Trove.new()

	local self = setmetatable({

		Pressed = State(false);
		Enabled = State(true);
		Context = State(nil);

		_rawInputs = {};
		_pressed = Signal.new();
		_pressTrove = _trove:Extend();
		_pressId = 0;
		_trove = _trove;


	},Input)

	for _, input in inputs do
		self:addInput(input)
	end

	self.Pressed:observe(function(pressed)
		if pressed then
			self._pressed:Fire(self._pressTrove);
		else
			self._pressTrove:Clean();
		end
	end)

	self.Context:listen(function(context: Context, trove): nil 
		if context ~= nil then
			trove:Add(self.Enabled:bind(context.Enabled))
		end
	end)

	_trove:Add(self._pressed)
	_trove:Add(self.Pressed)
	_trove:Add(self.Enabled)

	return self
end
setmetatable(Constructor, {
	__call = function(self,...)
		return Constructor.input(...)
	end,
})

export type RawInput =
	Enum.KeyCode
	| Enum.UserInputType
	| RBXScriptSignal
	| GuiButton
	| string

export type Input = typeof(Constructor.input())
export type Context = typeof(Constructor.context())
return Constructor
