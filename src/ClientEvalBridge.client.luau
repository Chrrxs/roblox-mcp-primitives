-- Studio-only client-side eval bridge for the Roblox Studio MCP.
--
-- Mirrors ServerEvalBridge but for the client peer. The MCP's execute_luau
-- runs in a separate require / module-cache context from the regular
-- LocalScripts (identity 10, "AssistantCommand" chunks). A direct
-- `require(...)` from execute_luau therefore returns a *fresh* module
-- table, not the one the running game holds — so you can't see runtime
-- mutations from execute_luau probes.
--
-- LocalScripts can't use `loadstring` (identity 2). Workaround: the caller
-- creates a temporary ModuleScript whose Source is the eval code, passes
-- the Instance to this bridge, and the bridge `require`s it. The require
-- executes inside this LocalScript's VM, so it shares the runtime's module
-- cache. The caller destroys the ModuleScript afterwards.
--
-- Usage from execute_luau (client peer):
--   local bf = game:GetService("ReplicatedStorage"):WaitForChild("__StudioClientEval", 3)
--   local m = Instance.new("ModuleScript")
--   m.Source = [[
--     local Players = game:GetService("Players")
--     return Players.LocalPlayer.Character ~= nil
--   ]]
--   m.Parent = workspace  -- anywhere descendant-of-game works
--   local ok, result = bf:Invoke(m)
--   m:Destroy()  -- evict from require cache, prevent leakage
--
-- Each invocation needs a fresh ModuleScript instance: Roblox keys the
-- require cache by Instance pointer, so re-using the same one returns the
-- previous result (or previous error).
--
-- Studio-only — the BindableFunction is never created in prod, so any code
-- depending on it will WaitForChild-timeout. Do not remove the IsStudio gate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local REMOTE_NAME = "__StudioClientEval"

-- Replace any leftover instance from a prior session (Rojo re-sync, etc.)
local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if existing then
	existing:Destroy()
end

local bf = Instance.new("BindableFunction")
bf.Name = REMOTE_NAME
bf.Parent = ReplicatedStorage

bf.OnInvoke = function(payload: any): (boolean, any)
	if typeof(payload) ~= "Instance" or not payload:IsA("ModuleScript") then
		return false, "payload must be a ModuleScript instance"
	end
	return pcall(require, payload)
end

print(`[ClientEvalBridge] ready — BindableFunction at ReplicatedStorage.{REMOTE_NAME}`)
