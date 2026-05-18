-- Studio-only unified log buffer (client side).
--
-- Captures every print/warn/error on this client, timestamps each message
-- locally, and flushes batches to the server every FLUSH_INTERVAL seconds
-- where they're appended to the shared __ClientLogBuffer.
--
-- Pair with LogBufferServer.server.luau on the server side. See that file
-- for the full design (buffer cap, format, why-not-just-print, etc.).
--
-- Studio-only — bails out in production so this never ships.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LogService = game:GetService("LogService")

if not RunService:IsStudio() then
	return
end

local REMOTE_NAME = "__ClientLogForward"
local FLUSH_INTERVAL = 0.25
local MAX_BATCH = 100

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

-- Numeric wall-clock seconds with millisecond precision via DateTime, so
-- the value is coherent with the server-side capture (each VM has its own
-- os.clock base, but DateTime is wall-clock anchored). The server formats
-- for display and uses these values for dedup + monotonic ordering.
local function nowSec(): number
	return DateTime.now().UnixTimestampMillis / 1000
end

-- Server peer may not be "in Studio" while the client is (team-test setups).
-- In that case the remote never appears and we silently stay quiet.
local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME) :: RemoteEvent?
if not remote then
	ReplicatedStorage.ChildAdded:Connect(function(newChild)
		if newChild.Name == REMOTE_NAME and newChild:IsA("RemoteEvent") then
			remote = newChild :: RemoteEvent
		end
	end)
end

local queue: { { ts: number, tag: string, msg: string } } = {}

LogService.MessageOut:Connect(function(msg, msgType)
	-- Drop-new only if there's no server-side remote to flush to (the brief
	-- window before the RemoteEvent appears). Once the remote is up, eagerly
	-- flush when full instead of dropping — a same-frame burst would otherwise
	-- lose every message past the first MAX_BATCH.
	if not remote and #queue >= MAX_BATCH then
		return
	end
	table.insert(queue, { ts = nowSec(), tag = messageTypeTag(msgType), msg = msg })
	if remote and #queue >= MAX_BATCH then
		local toSend = queue
		queue = {}
		remote:FireServer(toSend)
	end
end)

task.spawn(function()
	while not remote do
		task.wait(1)
	end

	while true do
		task.wait(FLUSH_INTERVAL)
		if #queue == 0 then
			continue
		end
		local toSend = queue
		queue = {}
		remote:FireServer(toSend)
	end
end)

print(`[LogBufferClient] ready — forwarding to ReplicatedStorage.{REMOTE_NAME}`)
