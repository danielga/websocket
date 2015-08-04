websocket = websocket or {}

include("frame.lua")
include("utilities.lua")

local socket = require("luasocket")
if socket == true or socket == nil then
	socket = _G.socket
end

local random = math.random
local insert, remove = table.insert, table.remove
local format, char, match = string.format, string.char, string.match
local setmetatable, assert, unpack, print = setmetatable, assert, unpack, print
local hook_Add, hook_Remove = hook.Add, hook.Remove

local CONNECTION = {}
CONNECTION.__index = CONNECTION

function CONNECTION:SetReceiveCallback(func)
	self.recvcallback = func
end

function CONNECTION:Shutdown()
	if not self:IsValid() then
		return
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil
end

function CONNECTION:IsValid()
	return self.socket ~= nil
end

function CONNECTION:GetRemoteAddress()
	if not self:IsValid() then
		return "", 0
	end

	return self.socket:getsockname()
end

function CONNECTION:GetState()
	return self.state
end

function CONNECTION:Send(data, opcode, masked, fin)
	if not self:IsValid() then
		return false
	end

	local data = websocket.frame.Encode(data, opcode, masked, fin)
	return self.socket:send(data) == #data
end

function CONNECTION:Receive(pattern)
	if not self:IsValid() then
		return false
	end

	local data, err, part = self.socket:receive(pattern)
	if err == "closed" then
		self.socket = nil
		self.state = websocket.state.CLOSED
	end

	return err and part or data, err
end

function CONNECTION:Think()
	if not self:IsValid() then
		return
	end

	if self.state == websocket.state.CONNECTING then
		local headers = {}
		local data, err = self:Receive()
		while data and not err do
			if #data == 0 then
				insert(headers, "")
				break
			end

			insert(headers, data)

			data, err = self:Receive()
		end

		if not err then
			headers = websocket.utilities.HTTPHeaders(headers)
			if headers then
				local key = format(
					"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: %s\r\nSec-WebSocket-Accept: %s\r\n\r\n",
					headers["connection"],
					websocket.utilities.Base64Encode(
						websocket.utilities.SHA1(headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
					)
				)
				self.state = self.socket:send(key) == #key and websocket.state.OPEN or websocket.state.CLOSED
			end
		else
			print("websocket auth error: " .. err)
		end
	elseif self.state == websocket.state.OPEN then
		local header, err = self:Receive(2)
		if not err then
			local complete, length, opcode, masked, fin, mask = websocket.frame.DecodeHeader(header)
			local data, err = self:Receive(length - (complete and 0 or 2))
			if not err then
				if complete and self.recvcallback then
					self.recvcallback(self, data, opcode, masked, fin)
				elseif not complete then
					complete, length, opcode, masked, fin, mask = websocket.frame.DecodeHeader(header .. data)
					data, err = self:Receive(length)
					if not err then
						if complete then
							data = masked and websocket.utilities.XORMask(data, mask) or data
							self.recvcallback(self, data, opcode, masked, fin)
						else
							print("websocket completion error: something went terribly wrong")
						end
					else
						print("websocket real data error: " .. err)
					end
				end
			else
				print("websocket data error: " .. err)
			end
		end
	end
end

local SERVER = {}
SERVER.__index = SERVER

function SERVER:SetAcceptCallback(func)
	self.acceptcallback = func
end

function SERVER:Shutdown()
	if not self:IsValid() then
		return
	end

	for i = 1, self.numconnections do
		self.connections[i]:Shutdown()
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil

	hook_Remove("Think", self)
end

function SERVER:IsValid()
	return self.socket ~= nil
end

function SERVER:Think()
	if not self:IsValid() then
		return
	end

	local client = self.socket:accept()
	if client then
		client:settimeout(0)
		local connection = setmetatable({
			socket = client,
			server = self,
			state = websocket.state.CONNECTING
		}, CONNECTION)

		if not self.acceptcallback or self.acceptcallback(self, connection) == true then
			insert(self.connections, connection)
			self.numconnections = self.numconnections + 1
		end
	end

	for i = 1, self.numconnections do
		self.connections[i]:Think()
		if self.connections[i]:GetState() == websocket.state.CLOSED then
			remove(self.connections, i)
			self.numconnections = self.numconnections - 1
			i = i - 1
		end
	end
end

function websocket.CreateServer(addr, port, queue) -- non-blocking and max queue of 5 by default
	assert(addr ~= nil and port ~= nil, "address or port not provided to create websocket server")

	local server = setmetatable({
		socket = assert(socket.tcp(), "failed to create socket"),
		numconnections = 0,
		connections = {}
	}, SERVER)
	server.socket:settimeout(0)
	server.socket:bind(addr, port)
	server.socket:listen(queue or 5)

	hook_Add("Think", server, SERVER.Think)

	return server
end

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
	self.state = websocket.state.CLOSED

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

	local data = websocket.frame.Encode(data, opcode, true, fin)
	return self.socket:send(data) == #data
end

function CLIENT:Think()
	if not self:IsValid() then
		return
	end

	if self.state == websocket.state.CONNECTING then
		if not self.key then
			self.key = websocket.utilities.Base64Encode(char(
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
				self.state = websocket.state.CLOSED
			end
		else

		end

		return
	end

	if err == "closed" then
		self.socket = nil
		return false
	end

	if page then
		local headers = websocket.utilities.HTTPHeaders(page)
		if headers then
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
		state = websocket.state.CONNECTING
	}, CLIENT)
	client.socket:settimeout(0)
	client.socket:connect(addr, port)

	hook_Add("Think", client, CLIENT.Think)

	return client
end
