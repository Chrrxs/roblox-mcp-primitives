# Roblox MCP Primitives

Three small Studio-only utilities that bridge gaps in the [Roblox Studio MCP](https://create.roblox.com/docs/studio/mcp) when you're driving a Roblox project from an AI agent (Claude Code, Cursor, etc.).

The MCP's `execute_luau` tool runs in a sandboxed identity-10 context on the client peer. It can read instance trees and run code, but its module cache is isolated from your running game scripts, and its `get_console_output` is hard-capped at 10 KB with drop-newest semantics so recent messages disappear after a busy boot. These primitives plug those gaps.

| Primitive | What it does | When you need it |
|---|---|---|
| **Server eval bridge** | Run arbitrary Luau on the server peer via `loadstring` | Inspecting / mutating server state (datastore wrappers, ECS world, services) |
| **Client eval bridge** | Run arbitrary Luau on the client peer in the LocalScript VM | Inspecting client runtime state (cached module mutations, in-flight UI state) |
| **Log buffer** | 64KB rolling buffer of all prints in the session, timestamped and deduped | Reading recent logs after a busy boot when `get_console_output`'s 10 KB cap has dropped what you wanted to see |

All three are guarded by `RunService:IsStudio()` and exit early in production — safe to leave in the project tree.

> See [AGENTS.md](./AGENTS.md) for a copy-pasteable cheat sheet to drop into your agent's system prompt.

## Install

### Option A — Rojo serve

```bash
git clone https://github.com/Chrrxs/roblox-mcp-primitives.git
cd roblox-mcp-primitives
rojo serve default.project.json
```

Connect Studio to `localhost:34872`. The four scripts land in their correct services (`ServerScriptService` and `StarterPlayer.StarterPlayerScripts`) and auto-run.

### Option B — Copy files

Drop these into your existing project tree:

- `src/ServerEvalBridge.server.luau` → `ServerScriptService`
- `src/LogBufferServer.server.luau` → `ServerScriptService`
- `src/ClientEvalBridge.client.luau` → `StarterPlayer.StarterPlayerScripts`
- `src/LogBufferClient.client.luau` → `StarterPlayer.StarterPlayerScripts`

### Required Studio setting

The server eval bridge needs `loadstring` enabled:

`ServerScriptService` → Properties → `LoadStringEnabled = true`

(The client eval bridge doesn't need this — it uses the ModuleScript-require trick instead.)

## Usage

### Server eval bridge

```lua
-- From execute_luau (client peer):
local rf = game:GetService("ReplicatedStorage"):WaitForChild("__StudioServerEval", 3)
local ok, count = rf:InvokeServer([[
  return #game:GetService("Players"):GetPlayers()
]])
```

`InvokeServer` returns `(ok, ...returns)` — the first return is `pcall`'s success flag, the rest is whatever your code returned. If `ok` is `false`, the second value is the error message.

### Client eval bridge

```lua
-- From execute_luau (client peer):
local bf = game:GetService("ReplicatedStorage"):WaitForChild("__StudioClientEval", 3)

local m = Instance.new("ModuleScript")
m.Source = [[
  local Players = game:GetService("Players")
  return Players.LocalPlayer.Character ~= nil
]]
m.Parent = workspace
local ok, hasChar = bf:Invoke(m)
m:Destroy()  -- evict from require cache
```

Why a ModuleScript instead of a source string: LocalScripts run at identity 2, which can't use `loadstring`. The caller (identity 10) can set `ModuleScript.Source`, and the bridge `require`s the resulting ModuleScript — which executes in the LocalScript's VM with its module cache. Each invocation needs a *fresh* ModuleScript instance (Roblox keys the require cache by Instance pointer).

A nice corollary: any networking library that buffers sends through its own module state (most packet/bridge libraries do, to coalesce per-frame flushes) becomes drivable from your probe. The bridge requires the same cached module the runtime uses, so a `:send(...)` from inside the eval actually flushes through the running session — no shadow buffer that never reaches the wire:

```lua
m.Source = [[
  local Network = require(game:GetService("ReplicatedStorage").Network)
  Network.RequestPurchase:send({ itemId = "Sword" })
  return true
]]
```

For plain `RemoteEvent:FireServer(...)` you don't need this — RemoteEvents are Instances and fire directly from any context. The pattern matters specifically for module-cached networking layers.

### Log buffer

```lua
-- From execute_luau (either peer):
local buffer = game:GetService("ReplicatedStorage"):WaitForChild("__ClientLogBuffer")

-- Full buffer (up to 64 KB):
return buffer.Value

-- Just the tail:
return string.sub(buffer.Value, -8000)
```

Format: `[HH:MM:SS.mmm] [OUT|INFO|WARN|ERR ] message`. Timestamps are wall-clock milliseconds via `DateTime.now()` (coherent across both peers), and the buffer guarantees **monotonic non-decreasing timestamps** + **deduplication** of messages reflected to both peers within a 2-second window — so a single `print` in Studio Play produces exactly one entry, not two.

To filter for errors only:

```lua
local hits = {}
for line in buffer.Value:gmatch("[^\n]+") do
  if line:find("%[WARN%]") or line:find("%[ERR ?%]") then
    table.insert(hits, line)
  end
end
return hits
```

When the buffer exceeds 64 KB the oldest quarter is dropped with a `...[truncated]...` marker — so a long session won't OOM, but you may lose history.

## Why these aren't built into the MCP

- **Server eval bridge**: The MCP's `execute_luau` runs on the client peer. Server access is a sibling capability that needs separate plumbing.
- **Client eval bridge**: The MCP's `execute_luau` is itself a kind of client eval, but it runs in a separate `require` cache from the LocalScripts — so probes can't see runtime module state. This bridge routes the eval through a real LocalScript's VM.
- **Log buffer**: `get_console_output` returns prints from both peers, but its Studio-plugin-side buffer is hard-capped at **10,000 characters with drop-newest semantics** — see [`plugin/src/Utils/ConsoleOutput.luau`](https://github.com/Roblox/studio-rust-mcp-server/blob/main/plugin/src/Utils/ConsoleOutput.luau) (`DEBUG_TOOL_MAX_OUTPUT = 10000`). Once full, new messages are silently dropped; old content stays. So after a busy boot you can't see what just happened, only what happened first. The buffer here is 64 KB with **drop-oldest-quarter** rolling. Side-by-side:

  | | `get_console_output` | `__ClientLogBuffer` |
  |---|---|---|
  | Cap | 10 KB | 64 KB |
  | Behavior at cap | Freeze; drop **new** | Roll; drop **oldest quarter** |
  | Read shape | Repeated tool calls with response-size truncation | Single `StringValue.Value` read |

## License

MIT. See [LICENSE](./LICENSE).
