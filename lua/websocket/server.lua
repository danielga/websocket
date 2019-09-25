local websocket = websocket
local frame = websocket.frame
local utilities = websocket.utilities

local socket = require("socket") or socket

local insert, remove, concat = table.insert, table.remove, table.concat
local format = string.format
local setmetatable, assert = setmetatable, assert
local hook_Add, hook_Remove = hook.Add, hook.Remove

local Base64Encode, SHA1 = utilities.Base64Encode, utilities.SHA1
local HTTPHeaders, XORMask = utilities.HTTPHeaders, utilities.XORMask
local Encode, DecodeHeader, EncodeClose, DecodeClose = frame.Encode, frame.DecodeHeader, frame.EncodeClose, frame.DecodeClose

local state = websocket.state
local CONNECTING, OPEN, CLOSED = state.CONNECTING, state.OPEN, state.CLOSED

local CONNECTION = {}
CONNECTION.__index = CONNECTION

function CONNECTION:SetReceiveCallback(func)
	self.recvcallback = func
end

function CONNECTION:SetCloseCallback(func)
	self.closecallback = func
end

function CONNECTION:SetErrorCallback(func)
	self.errorcallback = func
end

function CONNECTION:Shutdown(code, reason)
	if self.is_closing then
		return true
	end

	code = code or 1000
	self:ShutdownInternal(code, reason)

	if self.socket == nil then
		return true
	end

	local closeFrame = EncodeClose(code, reason)
	local fullCloseFrame = Encode(closeFrame, frame.CLOSE, false, true)
	local sentLen, err = self.socket:send(fullCloseFrame)
	if sentLen == nil then
		return false, err
	elseif sentLen ~= #fullCloseFrame then
		return false, "incomplete send"
	else
		return true
	end
end

function CONNECTION:ShutdownInternal(code, reason)
	if not self:IsValid() or self.is_closing then
		return
	end

	self.is_closing = true

	if self.closecallback ~= nil then
		self.closecallback(self, code, reason)
	end

	self.state = CLOSED

	-- self:IsValid() must return true if this block is executed
	-- therefore self.socket still is non-nil
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

function CONNECTION:Send(data, opcode)
	if not self:IsValid() then
		return false
	end

	local encodedData = Encode(data, opcode, false, true)
	return self.socket:send(encodedData) == #encodedData
end

function CONNECTION:SendEx(data, opcode)
	if not self:IsValid() then
		return false
	end

	local encodedData = Encode(data, opcode, false, true)
	self.sendBuffer[#self.sendBuffer + 1] = encodedData
	return true
end

function CONNECTION:Receive(pattern)
	if not self:IsValid() then
		return nil, "invalid"
	end

	local data, err, part = self.socket:receive(pattern)
	if err == "closed" then
		self.socket = nil
		self.state = CLOSED
	end

	return err ~= nil and part or data, err
end

function CONNECTION:ReceiveEx(len)
	local out = ""
	while len > 0 do
		local buf, err = self:Receive(len)
		if buf ~= nil then
			out = out .. buf
			len = len - #buf
		elseif err ~= "timeout" then
			return nil, err
		end

		if len > 0 then
			coroutine.yield(false, "read block")
		end
	end

	return out
end

function CONNECTION:ThinkFactory()
	if not self:IsValid() then
		return false, "closed"
	end

	if self.state == CONNECTING then
		local httpData = {}
		local data, err = self:Receive()
		while data ~= nil and err == nil do
			insert(httpData, data)

			if #data == 0 then
				break
			end

			data, err = self:Receive()
		end

		if err == nil then
			httpData = HTTPHeaders(httpData)
			if httpData ~= nil then
				local wsKey = httpData.headers["sec-websocket-key"]
				if wsKey ~= nil then
					local key = format(
						"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: %s\r\nSec-WebSocket-Accept: %s\r\n\r\n",
						httpData.headers["connection"],
						Base64Encode(SHA1(
							httpData.headers["sec-websocket-key"] .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
						))
					)
					self.state = self.socket:send(key) == #key and OPEN or CLOSED

					return true
				else
					-- could do a callback to allow the user to customise the response
					-- but this is a **websocket** server library, not a http server library
					-- so I believe this is out of scope.
					self.socket:send(format(
						"HTTP/1.1 200 OK\r\nConnection: %s\r\n\r\nHello, you have reached gm_websocket :)\r\n\r\n",
						httpData.headers["connection"]
					))

					self.socket:shutdown("both")
					self.socket:close()
					self.socket = nil
				end
			end

			return false
		else
			if self.errorcallback ~= nil then
				self.errorcallback(self, "websocket auth error: " .. err)
			end
		end
	elseif self.state == OPEN then
		local suc, messages = self:ReadFrame()
		if suc then
			if self.recvcallback ~= nil then
				for i = 1, #messages do
					local msg = messages[i]
					self.recvcallback(self, msg.decoded, msg.opcode, msg.masked, msg.fin)
				end
			end

			return true
		else
			-- `messages` is error string on failure cases
			return false, messages
		end
	end
end

local SERVER = {}
SERVER.__index = SERVER

function SERVER:SetAcceptCallback(func)
	self.acceptcallback = func
end

function SERVER:Shutdown(code, reason)
	if not self:IsValid() then
		return
	end

	for i = 1, self.numconnections do
		self.connections[i]:ShutdownInternal(code, reason)
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

	for i = 1, self.numconnections do
		local connection = self.connections[i]
		while IsValid(connection) and (connection.state ~= CLOSED) and (#connection.sendBuffer > 0) do
			local toSend = connection.sendBuffer[1]
			local sentLen, err = connection.socket:send(toSend)

			if sentLen == nil then
				if connection.errorcallback ~= nil then
					connection.errorcallback(connection, "websocket auth error: " .. err)
				end
				
				if err == "closed" then
					connection.state = CLOSED
					if connection.closecallback ~= nil then
						connection.closecallback(connection, 1006, "socket closed")
					end
					break
				end
			elseif #toSend == sentLen then
				table.remove(connection.sendBuffer, 1)
			else
				connection.sendBuffer[1] = toSend:sub(sentLen + 1, -1)
			end
		end
	end

	local client = self.socket:accept()
	while client ~= nil do
		client:settimeout(0)
		local connection = setmetatable({
			socket = client,
			server = self,
			state = CONNECTING,
			sendBuffer = {}
		}, CONNECTION)

		connection.Think = coroutine.wrap(function(...)
			while true do
				local suc, ret, _ = xpcall(connection.ThinkFactory, debug.traceback, ...)
				if not suc then
					ErrorNoHalt(ret .. "\n")
				elseif not ret or not connection.socket or not connection.socket:dirty() then
					-- we were not able to read anymore! yield!
					coroutine.yield()
				end
			end
		end)

		if self.acceptcallback == nil or self.acceptcallback(self, connection) == true then
			insert(self.connections, connection)
			self.numconnections = self.numconnections + 1
		end

		client = self.socket:accept()
	end

	for i = 1, self.numconnections do
		local connection = self.connections[i]
		if connection ~= nil then
			connection:Think()
			if IsValid(connection) and connection:GetState() == CLOSED then
				remove(self.connections, i)
				self.numconnections = self.numconnections - 1
				i = i - 1
			end
		else
			self.numconnections = self.numconnections - 1
		end
	end
end

local function clean(self, wasCleanExit, code, reason)
	if not wasCleanExit and self.errorcallback ~= nil then
		if self.state ~= CLOSED then
			self.errorcallback(self, "websocket close error: " .. tostring(reason))
		end
	end

	self:ShutdownInternal(code, reason)

	return false, reason or "closed", wasCleanExit, code
end

function CONNECTION:ReadFrame()
	-- https://github.com/lipp/lua-websockets/blob/cafb5874473ab9f54e734c123b18fb059801e4d5/src/websocket/sync.lua#L8-L75
	--[[
		Copyright (c) 2012 by Gerhard Lipp <gelipp@gmail.com>

		Permission is hereby granted, free of charge, to any person obtaining a copy
		of this software and associated documentation files (the "Software"), to deal
		in the Software without restriction, including without limitation the rights
		to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
		copies of the Software, and to permit persons to whom the Software is
		furnished to do so, subject to the following conditions:

		The above copyright notice and this permission notice shall be included in
		all copies or substantial portions of the Software.

		THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
		IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
		FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
		AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
		LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
		OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
		THE SOFTWARE.
	]]

	if self.is_closing then
		return false, "closing"
	end

	local messages = {}

	local startOpcode
	local readFrames
	local bytesToRead = 2
	local encodedMsg = ""

	while true do
		local chunk, recErr = self:ReceiveEx(bytesToRead - #encodedMsg)
		if chunk == nil then
			return clean(self, false, 1006, recErr)
		end

		encodedMsg = encodedMsg .. chunk

		local decoded, length, opcode, masked, fin, mask, headerLen = DecodeHeader(encodedMsg)
		if decoded then
			chunk, recErr = self:ReceiveEx(length - (#encodedMsg - headerLen))

			if #encodedMsg > headerLen then
				chunk = encodedMsg:sub(headerLen + 1, -1) .. chunk
			end

			if masked then
				chunk = XORMask(chunk, mask)
			end

			assert(not recErr, "ReadFrame() -> ReceiveEx() error")

			local messageBody = chunk
			if opcode == frame.CLOSE then
				if not self.is_closing then
					local code, reason = DecodeClose(messageBody)
					local closeFrame = EncodeClose(code, reason)
					local fullCloseFrame = Encode(closeFrame, frame.CLOSE, false, true)

					local sentLen, sendErr = self.socket:send(fullCloseFrame)
					if sendErr or sentLen ~= #fullCloseFrame then
						return clean(self, false, code, sendErr)
					else
						return clean(self, true, code, reason)
					end
				else
					return false, "closed"
				end
			elseif opcode == frame.PING then
				local pongFrame = Encode(messageBody, frame.PONG, false, true)

				local sentLen, sendErr = self.socket:send(pongFrame)
				if sendErr or sentLen ~= #pongFrame then
					return clean(self, false, code, sendErr)
				end

				messages[#messages + 1] = {
					decoded = messageBody,
					opcode = opcode,
					masked = masked,
					fin = fin,
				}
			elseif opcode == frame.PONG then
				messages[#messages + 1] = {
					decoded = messageBody,
					opcode = opcode,
					masked = masked,
					fin = fin,
				}
			end

			if not startOpcode then
				startOpcode = opcode
			end

			if not fin then
				if not readFrames then
					readFrames = {}
				elseif opcode ~= frame.CONTINUATION then
					return clean(self, false, 1002, "protocol error")
				end

				bytesToRead = 3
				encodedMsg = ""
				insert(readFrames, messageBody)
			elseif not readFrames then
				messages[#messages + 1] = {
					decoded = messageBody,
					opcode = startOpcode,
					masked = masked,
					fin = fin,
				}
				return true, messages
			else
				insert(readFrames, messageBody)
				messages[#messages + 1] = {
					decoded = concat(readFrames),
					opcode = startOpcode,
					masked = masked,
					fin = fin,
				}
				return true, messages
			end
		else
			assert(type(length) == "number" and length > 0)
			bytesToRead = length
		end
	end

	error("should never be reached")
end

function websocket.CreateServer(addr, port, queue) -- non-blocking and max queue of 5 by default
	assert(addr ~= nil and port ~= nil, "address or port not provided to create websocket server")

	local server = setmetatable({
		socket = assert(socket.tcp(), "failed to create socket"),
		numconnections = 0,
		connections = {}
	}, SERVER)
	server.socket:settimeout(0)
	assert(server.socket:bind(addr, port) == 1, "failed to bind address/port")
	server.socket:listen(queue or 5)

	hook_Add("Think", server, SERVER.Think)

	return server
end
