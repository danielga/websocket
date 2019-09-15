local websocket = websocket
local frame = websocket.frame
local utilities = websocket.utilities

local socket = require("socket") or socket

local insert, remove = table.insert, table.remove
local format = string.format
local setmetatable, assert, print = setmetatable, assert, print
local hook_Add, hook_Remove = hook.Add, hook.Remove

local Base64Encode, SHA1 = utilities.Base64Encode, utilities.SHA1
local HTTPHeaders, XORMask = utilities.HTTPHeaders, utilities.XORMask
local Encode, DecodeHeader = frame.Encode, frame.DecodeHeader

local state = websocket.state
local CONNECTING, OPEN, CLOSED = state.CONNECTING, state.OPEN, state.CLOSED

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

	local data = Encode(data, opcode, masked, fin)
	return self.socket:send(data) == #data
end

function CONNECTION:Receive(pattern)
	if not self:IsValid() then
		return false
	end

	local data, err, part = self.socket:receive(pattern)
	if err == "closed" then
		self.socket = nil
		self.state = CLOSED
	end

	return err and part or data, err
end

function CONNECTION:Think()
	if not self:IsValid() then
		return
	end

	if self.state == CONNECTING then
		local headers = {}
		local data, err = self:Receive()
		while data ~= nil and err == nil do
			insert(headers, data)

			if #data == 0 then
				break
			end

			data, err = self:Receive()
		end

		if err == nil then
			headers = HTTPHeaders(headers)
			if headers ~= nil then
				local key = format(
					"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: %s\r\nSec-WebSocket-Accept: %s\r\n\r\n",
					headers["connection"],
					Base64Encode(SHA1(
						headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
					))
				)
				self.state = self.socket:send(key) == #key and OPEN or CLOSED
			end
		else
			print("websocket auth error: " .. err)
		end
	elseif self.state == OPEN then
		local header, err = self:Receive(2)
		if err == nil then
			local complete, length, opcode, masked, fin, mask = DecodeHeader(header)
			local data, err = self:Receive(length - (complete and 0 or 2))
			if err == nil then
				if complete and self.recvcallback then
					self.recvcallback(self, data, opcode, masked, fin)
				elseif not complete then
					complete, length, opcode, masked, fin, mask = DecodeHeader(header .. data)
					data, err = self:Receive(length)
					if err == nil then
						if complete then
							data = masked and XORMask(data, mask) or data
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
	while client ~= nil do
		client:settimeout(0)
		local connection = setmetatable({
			socket = client,
			server = self,
			state = CONNECTING
		}, CONNECTION)

		if self.acceptcallback == nil or self.acceptcallback(self, connection) == true then
			insert(self.connections, connection)
			self.numconnections = self.numconnections + 1
		end

		client = self.socket:accept()
	end

	for i = 1, self.numconnections do
		self.connections[i]:Think()
		if self.connections[i]:GetState() == CLOSED then
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
