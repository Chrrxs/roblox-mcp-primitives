-- Studio-only server-side eval bridge for the Roblox Studio MCP.
--
-- The MCP's execute_luau tool runs in the client peer during a Play session
-- (identity 10, chunk name "AssistantCommand"). Some debugging tasks need to
-- inspect or mutate state on the server peer — this bridge accepts a Luau
-- source string over a RemoteFunction, runs it server-side via loadstring,
-- and returns the result tuple from pcall.
--
-- Usage from execute_luau (client peer):
--   local rf = game:GetService("ReplicatedStorage"):WaitForChild("__StudioServerEval", 3)
--   local ok, count, jobId = rf:InvokeServer("return #game:GetService('Players'):GetPlayers(), game.JobId")
--
-- Requires ServerScriptService.LoadStringEnabled = true (set it in Studio
-- under ServerScriptService > Properties).
--
-- Studio-only — the RemoteFunction is never created in prod, so any code
-- depending on it will WaitForChild-timeout. Do not remove the IsStudio gate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local REMOTE_NAME = "__StudioServerEval"

-- Replace any leftover instance from a prior session (Rojo re-sync, etc.)
local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if existing then
	existing:Destroy()
end

local rf = Instance.new("RemoteFunction")
rf.Name = REMOTE_NAME
rf.Parent = ReplicatedStorage

rf.OnServerInvoke = function(_player: Player, source: string)
	if type(source) ~= "string" then
		return false, "source must be a string"
	end
	local fn, compileErr = loadstring(source, "StudioServerEval")
	if not fn then
		return false, compileErr
	end
	return pcall(fn)
end

print(`[ServerEvalBridge] ready — RemoteFunction at ReplicatedStorage.{REMOTE_NAME}`)
