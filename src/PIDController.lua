--[[
	A robust PID controller that supports both Vector3 and number values,
	with advanced debugging and anti-windup capabilities.

	Overhauled based on a professional implementation, while maintaining a
	compatible API with previous versions.
]]

local PIDController = {}
PIDController.__index = PIDController
-- Type-agnostic clamping function
local function clamp(val, min, max)
	if typeof(val) == "Vector3" then
		return Vector3.new(
			math.clamp(val.X, min.X, max.X),
			math.clamp(val.Y, min.Y, max.Y),
			math.clamp(val.Z, min.Z, max.Z)
		)
	else
		return math.clamp(val, min, max)
	end
end

--[=[
	@param kp number -- Proportional gain (P)
	@param ki number -- Integral gain (I)
	@param kd number -- Derivative gain (D)
	@param min? number | Vector3 -- Minimum value the controller can output
	@param max? number | Vector3 -- Maximum value the controller can output
	@return PIDController
]=]
function PIDController.new(kp: number, ki: number, kd: number, min: any, max: any): any
	local self = setmetatable({}, PIDController)

	-- Tuning Gains
	self._kp = kp or 1
	self._ki = ki or 0
	self._kd = kd or 0

	-- Output Limits
	self._min = min
	self._max = max

	-- Internal State
	self._integralSum = nil
	self._lastError = nil
	self._lastOutput = nil

	-- Debugging state
	self._debugInstance = nil
	self._originalUpdate = self.update -- Store original update for debug restoration

	return self
end

--[=[
	Resets the PID's internal state to zero.
	Essential when tuning gains live or when the target changes drastically.
]=]
function PIDController:reset()
	self._integralSum = nil
	self._lastError = nil
	self._lastOutput = nil
end

--[=[
	Calculates the control output. This method is type-agnostic and will
	work with either numbers or Vector3s passed into it.

	@param target number | Vector3 -- The desired value (setpoint)
	@param current number | Vector3 -- The current measured value (process variable)
	@param dt number -- The time delta since the last update (should be fixed for stability)
	@return number | Vector3
]=]
function PIDController:update(target: any, current: any, dt: number): any

	-- 1. Calculate Error
	local err = target - current

	-- 2. Initialize internal state on first run with the correct data type
	if self._integralSum == nil then
		if typeof(err) == "Vector3" then
			self._integralSum = Vector3.new()
			self._lastError = Vector3.new()
		else -- Assumes number
			self._integralSum = 0
			self._lastError = 0
		end
	end

	-- 3. Calculate Integral Term (with Anti-Windup)
	-- Only accumulate integral if the output is not saturated or if the error
	-- would push the output back towards the valid range.
	if self._lastOutput then
		if typeof(err) == "number" then
			if (self._lastOutput >= self._max and err > 0) or (self._lastOutput <= self._min and err < 0) then
				-- Do not accumulate integral to prevent windup
			else
				self._integralSum = self._integralSum + err * dt
			end
		else -- Vector3 logic is more complex, simple accumulation for now
			self._integralSum = self._integralSum + err * dt
		end
	else
		self._integralSum = self._integralSum + err * dt
	end

	local iOut = self._ki * self._integralSum

	-- 4. Calculate Derivative Term
	local derivative = (err - self._lastError) / dt
	local dOut = self._kd * derivative

	-- 5. Calculate Proportional Term
	local pOut = self._kp * err

	-- 6. Combine all terms
	local output = pOut + iOut + dOut

	-- 7. Clamp output if limits are defined
	if self._min and self._max then
		output = clamp(output, self._min, self._max)
	end

	-- 8. Save state for next iteration
	self._lastError = err
	self._lastOutput = output

	return output
end

--[=[
	Enables live-tuning of the PID gains by creating attributes
	on a specified instance. Changes made in the Properties panel
	will reflect in real-time.

	@param instance Instance -- The instance to host the debug attributes
]=]
function PIDController:debug(instance: Instance)
	if not game:GetService("RunService"):IsStudio() or self._debugInstance then
		return
	end

	self._debugInstance = instance

	-- Helper to bind an instance attribute to a controller property
	local function bindAttribute(attrName, propName, shouldReset)
		instance:SetAttribute(attrName, self[propName])
		instance:GetAttributeChangedSignal(attrName):Connect(function()
			self[propName] = instance:GetAttribute(attrName)
			if shouldReset then
				self:reset()
			end
		end)
	end

	-- Bind gains (resets controller on change)
	bindAttribute("Kp", "_kp", true)
	bindAttribute("Ki", "_ki", true)
	bindAttribute("Kd", "_kd", true)

	-- Bind limits (does not need to reset)
	if self._min and self._max then
		bindAttribute("MinOutput", "_min", false)
		bindAttribute("MaxOutput", "_max", false)
	end

	instance:SetAttribute("Output", if typeof(self._lastError) == "Vector3" then "Vector3" else 0)

	-- Monkey-patch the update function for this specific instance
	-- to read attributes before calculating and write output after.
	-- This is more efficient than checking for a debug instance on every frame.
	self.update = function(self, target, current, dt)
		-- Read the latest values from attributes (in case they were changed manually)
		self._kp = instance:GetAttribute("Kp")
		self._ki = instance:GetAttribute("Ki")
		self._kd = instance:GetAttribute("Kd")

		-- Call the original, core update logic
		local output = self._originalUpdate(self, target, current, dt)

		-- Write the live output back to an attribute for monitoring
		instance:SetAttribute("Output", output)

		return output
	end
end

--[=[
	Cleans up any debug instances and connections.
]=]
function PIDController:destroy()
	if self._debugInstance then
		self.update = self._originalUpdate -- Restore original update method
		-- Consider removing attributes if desired, though not strictly necessary
		self._debugInstance = nil
	end
end
export type PIDController = typeof(PIDController)
return PIDController
