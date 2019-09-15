local websocket = websocket
local frame = websocket.frame
local utilities = websocket.utilities

local socket = require("socket") or socket

local random = math.random
local format, char, match = string.format, string.char, string.match
local setmetatable, assert = setmetatable, assert
local hook_Add, hook_Remove = hook.Add, hook.Remove

local Base64Encode = utilities.Base64Encode
local HTTPHeaders = utilities.HTTPHeaders
local Encode = frame.Encode

local state = websocket.state
local CONNECTING, CLOSED = state.CONNECTING, state.CLOSED

local CLIENT = {}
CLIENT.__index = CLIENT

function CLIENT:SetReceiveCallback(func)
	self.recvcallback = func
end

function CLIENT:Shutdown()
	if not self:IsValid() then
		return
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil
	self.state = CLOSED

	hook_Remove("Think", self)
end

function CLIENT:IsValid()
	return self.socket ~= nil
end

function CLIENT:GetRemoteAddress()
	if not self:IsValid() then
		return "", 0
	end

	return self.socket:getsockname()
end

function CLIENT:GetState()
	return self.state
end

function CLIENT:Send(data, opcode, fin)
	if not self:IsValid() then
		return false
	end

	local data = Encode(data, opcode, true, fin)
	return self.socket:send(data) == #data
end

function CLIENT:Think()
	if not self:IsValid() then
		return
	end

	if self.state == CONNECTING then
		if self.key == nil then
			self.key = Base64Encode(char(
				random(0, 255), random(0, 255), random(0, 255), random(0, 255),
				random(0, 255), random(0, 255), random(0, 255), random(0, 255),
				random(0, 255), random(0, 255), random(0, 255), random(0, 255),
				random(0, 255), random(0, 255), random(0, 255), random(0, 255)
			))
			local handshake = format(
				"GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
				self.path,
				self.host,
				self.key
			)
			if self.socket:send(handshake) ~= #handshake then
				self.state = CLOSED
			end
		else

		end

		return
	end

	if err == "closed" then
		self.socket = nil
		return false
	end

	if page ~= nil then
		local headers = HTTPHeaders(page)
		if headers ~= nil then
			self:Handshake(headers["connection"], headers["sec-websocket-key"])
		end
	end

	return true
end

function websocket.CreateClient(addr, port)
	assert(addr and port, "address or port not provided to create websocket client")

	local protocol, host, path = match(addr, "^(wss?)://([^/]+)/?(%a*)$")
	assert(protocol == "ws" and host ~= nil, "bad address or protocol") -- wss brings more complexity

	local client = setmetatable({
		socket = assert(socket.tcp(), "failed to create socket"),
		protocol = protocol,
		host = host,
		path = path,
		state = CONNECTING
	}, CLIENT)
	client.socket:settimeout(0)
	client.socket:connect(addr, port)

	hook_Add("Think", client, CLIENT.Think)

	return client
end
