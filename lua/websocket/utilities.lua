local websocket = websocket

websocket.state = websocket.state or {}

local state = websocket.state

state.CONNECTING = 1
state.OPEN = 2
state.CLOSING = 3
state.CLOSED = 4

websocket.utilities = websocket.utilities or {}

local utilities = websocket.utilities

local assert, type, error = assert, type, error
local concat = table.concat
local char, byte, find, match, lower = string.char, string.byte, string.find, string.match, string.lower
local bxor = bit.bxor

utilities.Base64Encode = util.Base64Encode

require("crypt")

local hasher = crypt.SHA1()
function utilities.SHA1(data)
	return hasher:CalculateDigest(data)
end

function utilities.XORMask(data, mask)
	local transformed = {}
	for i = 1, #data do
		transformed[i] = char(bxor(byte(data, i), mask[(i - 1) % 4 + 1]))
	end

	return concat(transformed)
end

function utilities.HTTPHeaders(request)
	assert(type(request) == "table" and #request ~= 0, "parameter #1 is not a table or is empty")

	local httpOperation, url, httpVersion = match(request[1], "^[ ]*([A-Za-z]+)[ ]+(%S-)%s+HTTP/([%d%.]+)[\r\n ]*")
	assert(httpVersion == "1.1", "Unsupported HTTP Version: only 1.1 is supported.")

	local headers = {}
	for i = 2, #request do
		local line = request[i]
		local name, val = match(line, "([^%s]+)%s*:%s*([^\r\n]+)")
		if name ~= nil and val ~= nil then
			name = lower(name)

			if headers[name] == nil then
				headers[name] = val
			else
				headers[name] = headers[name] .. "," .. val
			end
		elseif #line == 0 then
			break
		else
			error(line .. "(" .. #line .. ")")
		end
	end

	return {
		httpOperation = httpOperation,
		url = url,
		headers = headers
	}
end
