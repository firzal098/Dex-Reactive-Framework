-- Animator.luau
-- A centralized scheduler for managing all tween and spring-based animations
-- in the framework. This ensures all animations are synchronized and updated
-- efficiently on a single RunService connection.

local RunService = game:GetService("RunService")

local Animator = {}

-- A table containing all active animation "jobs".
local activeAnimations = {}
local connection = nil

-- The core update loop. Iterates through all active animations and updates them.
local function update(dt)
	if next(activeAnimations) == nil then
		connection:Disconnect()
		connection = nil
		return
	end

	for job in pairs(activeAnimations) do
		-- Each job has an `update` method that returns `true` if it's still active.
		if not job.update(dt) then
			-- If the job is complete, remove it from the scheduler.
			Animator.remove(job)
		end
	end
end

---
-- Adds an animation job to the central scheduler.
-- A "job" is a table with an `update(dt)` method.
-- @param job The animation job to add.
function Animator.add(job)
	activeAnimations[job] = true
	-- Lazily create the connection only when the first animation is added.
	if not connection then
		connection = RunService.Heartbeat:Connect(update)
	end
end

---
-- Removes an animation job from the central scheduler.
-- @param job The animation job to remove.
function Animator.remove(job)
	activeAnimations[job] = nil
end

return Animator
