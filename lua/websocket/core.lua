websocket = {}

include("frame.lua")
include("utilities.lua")

local socket = require("luasocket")
if socket == true or socket == nil then socket = _G.socket end

local WSSERVERCONNECTION = {}
WSSERVERCONNECTION.__index = WSSERVERCONNECTION

function WSSERVERCONNECTION:SetReceiveCallback(func)
	self.recvcallback = func
end

function WSSERVERCONNECTION:Shutdown()
	if not self:IsValid() then
		return
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil
end

function WSSERVERCONNECTION:IsValid()
	return self.socket ~= nil
end

function WSSERVERCONNECTION:GetRemoteAddress()
	if not self:IsValid() then
		return "", 0
	end

	return self.socket:getsockname()
end

function WSSERVERCONNECTION:GetState()
	return self.state
end

function WSSERVERCONNECTION:Send(data, opcode, masked, fin)
	if not self:IsValid() then
		return false
	end

	local data = websocket.frame.encode(data, opcode, masked, fin)
	return self.socket:send(data) == #data
end

function WSSERVERCONNECTION:__Receive(pattern)
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

local strwithstr = "%s%s"
local magickey = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local wsaccept = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: %s\r\nSec-WebSocket-Accept: %s\r\n\r\n"

function WSSERVERCONNECTION:__Think()
	if not self:IsValid() then
		return
	end

	if self.state == websocket.state.CONNECTING then
		local headers = {}
		local data, err = self:__Receive()
		while data and not err do
			if #data == 0 then
				table.insert(headers, "")
				break
			end

			table.insert(headers, data)

			data, err = self:__Receive()
		end

		if not err then
			headers = websocket.utilities.http_headers(headers)
			if headers then
				local key = headers["sec-websocket-key"]
				key = strwithstr:format(key, magickey)
				key = websocket.utilities.sha1(key, true)
				key = websocket.utilities.base64encode(key)
				key = wsaccept:format(headers["connection"], key)
				self.state = self.socket:send(key) == #key and websocket.state.OPEN or websocket.state.CLOSED
			end
		else
			print("websocket auth error: " .. err)
		end
	elseif self.state == websocket.state.OPEN then
		local header, err = self:__Receive(2)
		if not err then
			local complete, length, opcode, masked, fin, mask = websocket.frame.decodeheader(header)
			local data, err = self:__Receive(length - (complete and 0 or 2))
			if not err then
				if complete and self.recvcallback then
					self.recvcallback(self, data, opcode, masked, fin)
				elseif not complete then
					complete, length, opcode, masked, fin, mask = websocket.frame.decodeheader(header .. data)
					data, err = self:__Receive(length)
					if not err then
						if complete then
							data = masked and websocket.utilities.xor_mask(data, mask) or data
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

local WSSERVER = {}
WSSERVER.__index = WSSERVER

function WSSERVER:SetAcceptCallback(func)
	self.acceptcallback = func
end

function WSSERVER:Shutdown()
	if not self:IsValid() then
		return
	end

	for i = 1, self.numconnections do
		self.connections[i]:Shutdown()
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil

	hook.Remove("Think", self)
end

function WSSERVER:IsValid()
	return self.socket ~= nil
end

function WSSERVER:__Think()
	if not self:IsValid() then
		return
	end

	local client = self.socket:accept()
	if client then
		client:settimeout(0)
		local connection = setmetatable({}, WSSERVERCONNECTION)
		connection.socket = client
		connection.server = self
		connection.state = websocket.state.CONNECTING
		if not self.acceptcallback or self.acceptcallback(self, connection) == true then
			table.insert(self.connections, connection)
			self.numconnections = self.numconnections + 1
		end
	end

	local r = 0
	for i = 1, self.numconnections do
		if i > self.numconnections - r then
			break
		end

		self.connections[i - r]:__Think()
		if self.connections[i - r]:GetState() == websocket.state.CLOSED then
			table.remove(self.connections, i - r)
			self.numconnections = self.numconnections - 1
			r = r + 1
		end
	end
end

function websocket.CreateServer(addr, port, queue) -- non-blocking and max queue of 5 by default
	assert(addr and port, "address or port not provided to create websocket server")

	local wsserver = setmetatable({}, WSSERVER)
	wsserver.socket = assert(socket.tcp(), "failed to create socket")
	wsserver.socket:settimeout(0)
	wsserver.socket:bind(addr, port)
	wsserver.socket:listen(queue or 5)

	wsserver.numconnections = 0
	wsserver.connections = {}

	hook.Add("Think", wsserver, WSSERVER.__Think)

	return wsserver
end

local WSCLIENT = {}
WSCLIENT.__index = WSCLIENT

function WSCLIENT:SetReceiveCallback(func)
	self.recvcallback = func
end

function WSCLIENT:Shutdown()
	if not self:IsValid() then
		return
	end

	self.socket:shutdown("both")
	self.socket:close()
	self.socket = nil
	self.state = websocket.state.CLOSED
end

function WSCLIENT:IsValid()
	return self.socket ~= nil
end

function WSCLIENT:GetRemoteAddress()
	if not self:IsValid() then
		return "", 0
	end

	return self.socket:getsockname()
end

function WSCLIENT:GetState()
	return self.state
end

function WSCLIENT:Send(data, opcode, fin)
	if not self:IsValid() then
		return false
	end

	local data = websocket.frame.encode(data, opcode, true, fin)
	return self.socket:send(data) == #data
end

local wsclient = "GET /%s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n"

function WSCLIENT:__Think()
	if not self:IsValid() then
		return
	end

	if self.state == websocket.state.CONNECTING then
		if not self.key then
			self.key = {}
			for i = 1, 16 do
				self.key[i] = math.random(0, 255)
			end
			self.key = string.char(unpack(self.key))
			self.key = websocket.utilities.base64encode(self.key)
			local handshake = wsclient:format(path, host, self.key)
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
		local headers = websocket.utilities.http_headers(page)
		if headers then
			self:Handshake(headers["connection"], headers["sec-websocket-key"])
		end
	end

	return true
end

function websocket.CreateClient(addr, port)
	error("websocket client implementation not complete")
	assert(addr and port, "address or port not provided to create websocket client")

	local protocol, host, path = addr:match("^(wss?)://([^/]+)/?(%a*)$")
	assert(protocol == "ws" and host, "bad address or protocol") -- wss brings more complexity

	local wsclient = setmetatable({}, WSCLIENT)
	wsclient.socket = assert(socket.tcp(), "failed to create socket")
	wsclient.socket:settimeout(0)
	wsclient.socket:connect(addr, port)
	wsclient.state = websocket.state.CONNECTING

	hook.Add("Think", wsclient, WSCLIENT.__Think)

	return wsclient
end