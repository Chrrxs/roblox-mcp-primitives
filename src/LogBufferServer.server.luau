-- Studio-only unified log buffer (server side).
--
-- Writes every print/warn/error from server AND all clients into a single
-- StringValue the MCP can read via execute_luau:
--   ReplicatedStorage.__ClientLogBuffer.Value
--
-- Why a StringValue and not just rely on get_console_output:
--   The Studio MCP plugin caps its outputMessage at 10,000 characters with
--   DROP-NEWEST semantics — once full, new MessageOut events are silently
--   discarded and old content stays put. See:
--     https://github.com/Roblox/studio-rust-mcp-server/blob/main/plugin/src/Utils/ConsoleOutput.luau
--   So after a busy boot, get_console_output is frozen on boot-time prints
--   and can't see what just happened. This buffer is 64 KB with drop-oldest-
--   quarter rolling instead, so the recent tail is always available.
--
-- Format (one line per message):
--   [HH:MM:SS.mmm] [TAG] message
-- TAG ∈ { OUT, INFO, WARN, ERR }
--
-- Timestamps are captured on the peer that produced the log, so batched
-- client messages keep their real ordering even though they arrive at the
-- server in a delayed flush.
--
-- Oldest quarter is dropped when the buffer exceeds MAX_BUFFER_SIZE.
--
-- Pair with LogBufferClient.client.luau on the client side.
--
-- Studio-only — bails out in production so this never ships.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")

if not RunService:IsStudio() then
	return
end

local REMOTE_NAME = "__ClientLogForward"
local BUFFER_NAME = "__ClientLogBuffer"

-- Roblox's engine cap on StringValue.Value is 200,000 characters. Any
-- assignment to a longer string fails AND the resulting "Unable to assign
-- property Value..." error is logged via LogService.MessageOut — which
-- would bounce right back into the listener below and produce a self-
-- sustaining error loop that hangs the main thread.
--
-- Clamp the user-configurable cap below the engine limit (Fix 1) AND
-- hard-clamp `next` immediately before assignment (Fix 2). Belt + suspenders.
local ENGINE_STRING_VALUE_MAX = 200_000
local MAX_BUFFER_SIZE = math.min(64 * 1024, ENGINE_STRING_VALUE_MAX - 1)

local function messageTypeTag(msgType: Enum.MessageType): string
	if msgType == Enum.MessageType.MessageWarning then
		return "WARN"
	elseif msgType == Enum.MessageType.MessageError then
		return "ERR "
	elseif msgType == Enum.MessageType.MessageInfo then
		return "INFO"
	end
	return "OUT "
end

-- Wall-clock seconds with millisecond precision. DateTime is used (rather
-- than os.time + os.clock%1) so the value is coherent across peers — each
-- VM has its own os.clock base, but DateTime is wall-clock anchored.
local function nowSec(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

local function formatTs(sec: number): string
	local s = math.floor(sec)
	local ms = math.floor((sec - s) * 1000)
	return string.format("%s.%03d", os.date("%H:%M:%S", s), ms)
end

-- Dedup ring. In Studio Play, Roblox reflects each print to BOTH peers'
-- LogServices, so the same message is captured twice — once by the server
-- listener directly, once by a client batch ~250ms+ later. We keep recent
-- (msg, ts) commits in a TIME-BOUNDED ring; new appends scan back from
-- newest until either a match (drop) or a ts gap exceeding DEDUP_WINDOW_SEC.
-- 2s comfortably covers the 0.25s client batch + any peer-listener startup
-- skew (observed up to ~700ms when the client peer's listener attaches
-- later than the server's).
--
-- Eviction is time-based, not count-based — a same-frame burst of N prints
-- would overflow a count-capped ring before the client batch arrives,
-- letting duplicates slip through. Hard upper-bound on entry count is a
-- safety net against pathological print rates, not the primary mechanism.
local DEDUP_WINDOW_SEC = 2.0
local DEDUP_HARD_CAP = 50_000 -- runaway safety; never expected to hit
local dedupRing: { { msg: string, ts: number } } = {}

local function isRecentDuplicate(msg: string, ts: number): boolean
	for i = #dedupRing, 1, -1 do
		local e = dedupRing[i]
		if (ts - e.ts) > DEDUP_WINDOW_SEC then
			return false
		end
		if e.msg == msg then
			return true
		end
	end
	return false
end

local function rememberInDedup(msg: string, ts: number)
	table.insert(dedupRing, { msg = msg, ts = ts })
	-- Evict from the front while the oldest entry is past the dedup window.
	while #dedupRing > 0 and (ts - dedupRing[1].ts) > DEDUP_WINDOW_SEC do
		table.remove(dedupRing, 1)
	end
	-- Hard cap as runaway protection.
	while #dedupRing > DEDUP_HARD_CAP do
		table.remove(dedupRing, 1)
	end
end

-- Monotonic-timestamp clamp. Client batches arrive late with their own
-- captured timestamps, which may be older than recent server-direct
-- appends; clamping each commit's effective ts to >= lastTs keeps the
-- buffer non-decreasing for chronological reading.
local lastTs = 0

-- Replace any leftover instances from a prior session.
local existingRemote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
if existingRemote then
	existingRemote:Destroy()
end
local existingBuffer = ReplicatedStorage:FindFirstChild(BUFFER_NAME)
if existingBuffer then
	existingBuffer:Destroy()
end

local remote = Instance.new("RemoteEvent")
remote.Name = REMOTE_NAME
remote.Parent = ReplicatedStorage

local buffer = Instance.new("StringValue")
buffer.Name = BUFFER_NAME
buffer.Value = ""
buffer.Parent = ReplicatedStorage

local function append(line: string)
	local next = buffer.Value .. line .. "\n"
	if #next > MAX_BUFFER_SIZE then
		-- Drop the oldest quarter so we're not rewriting the property on
		-- every line once we hit the cap.
		local cutFrom = #next - (MAX_BUFFER_SIZE * 3 // 4)
		local newlineIdx = string.find(next, "\n", cutFrom, true) or cutFrom
		next = "...[truncated]...\n" .. string.sub(next, newlineIdx + 1)
	end
	-- Fix 2: defensive tail-clamp. Catches any path that lets `next` slip past
	-- the engine cap — e.g. a single line longer than MAX_BUFFER_SIZE, or a
	-- future bug in the truncation block above. Without this, a failed
	-- assignment would re-enter this function via the MessageOut loop.
	if #next >= ENGINE_STRING_VALUE_MAX then
		next = "...[truncated]...\n" .. string.sub(next, -(ENGINE_STRING_VALUE_MAX - 100))
	end
	buffer.Value = next
end

-- Single commit site: applies dedup + monotonic clamp before formatting
-- and appending. All buffer writes go through this.
local function commit(srcTs: number, tag: string, msg: string)
	if isRecentDuplicate(msg, srcTs) then
		return
	end
	local effectiveTs = if srcTs > lastTs then srcTs else lastTs
	lastTs = effectiveTs
	rememberInDedup(msg, srcTs)
	append(`[{formatTs(effectiveTs)}] [{tag}] {msg}`)
end

LogService.MessageOut:Connect(function(msg, msgType)
	commit(nowSec(), messageTypeTag(msgType), msg)
end)

-- Client batches arrive here with per-message timestamps captured at the
-- moment the client peer's LogService fired (sent as numeric seconds).
remote.OnServerEvent:Connect(function(_player, batch)
	if type(batch) ~= "table" then
		return
	end
	for _, entry in batch do
		if type(entry) ~= "table" then
			continue
		end
		local ts = if type(entry.ts) == "number" then entry.ts else nowSec()
		local tag = if type(entry.tag) == "string" then entry.tag else "OUT "
		local msg = if type(entry.msg) == "string" then entry.msg else tostring(entry.msg)
		commit(ts, tag, msg)
	end
end)

print(`[LogBufferServer] ready — buffer at ReplicatedStorage.{BUFFER_NAME}`)
