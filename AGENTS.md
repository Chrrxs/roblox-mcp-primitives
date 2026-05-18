# Roblox MCP Primitives — Agent Usage

When `execute_luau` and `get_console_output` aren't enough, use these three Studio-only bridges. `execute_luau` runs in an identity-10 sandbox on the client peer with an isolated `require` cache — if a probe shows unexpected runtime state, route it through one of these.

## Server eval bridge — run code on the server peer
```lua
local rf = game:GetService("ReplicatedStorage"):WaitForChild("__StudioServerEval", 3)
local ok, result = rf:InvokeServer([[ return whatever ]])
```
Returns `(ok, ...returns)` from pcall. Requires `ServerScriptService.LoadStringEnabled = true`.

## Client eval bridge — run code in the client peer's runtime VM
LocalScripts can't `loadstring`, so the bridge takes a ModuleScript:
```lua
local bf = game:GetService("ReplicatedStorage"):WaitForChild("__StudioClientEval", 3)
local m = Instance.new("ModuleScript")
m.Source = [[ return require(...).whatever ]]
m.Parent = workspace
local ok, result = bf:Invoke(m)
m:Destroy()  -- ALWAYS destroy; require cache is keyed by Instance pointer
```
Use this (not `execute_luau` directly) when you need to see runtime-mutated modules, or to send packets through module-cached networking libs — those need the runtime's cached Net module, not a fresh require.

## Log buffer — read recent session logs
```lua
local buf = game:GetService("ReplicatedStorage"):WaitForChild("__ClientLogBuffer").Value
return string.sub(buf, -8000)  -- recent tail
```
Format: `[HH:MM:SS.mmm] [OUT|INFO|WARN|ERR ] message`. Buffer is monotonic, deduped, 64KB rolling (oldest quarter drops). Captures every print from the session into a single chronological stream — use it instead of `get_console_output` when its 10KB drop-newest cap has lost recent messages.

**Always grep errors first** after risky work — domain-filtered probes hide unrelated errors:
```lua
for line in buf:gmatch("[^\n]+") do
  if line:find("%[ERR ?%]") or line:find("%[WARN%]") then -- collect end
end
```

## Hard rules
- **Fresh ModuleScript per client-bridge call** — reusing one returns stale cached results.
- **Grep `[ERR ]` / `[WARN]` explicitly** — packet-filtered probes hide unrelated errors that fired in the same window.
- **Don't poll the log buffer in a tight loop** — it's a replicated StringValue.
