websocket.state = websocket.state or {}
websocket.state.CONNECTING = 1
websocket.state.OPEN = 2
websocket.state.CLOSING = 3
websocket.state.CLOSED = 4

websocket.utilities = websocket.utilities or {}

local unpack, assert, type, error = unpack, assert, type, error
local insert, concat, remove = table.insert, table.concat, table.remove
local byte, char, match, lower = string.byte, string.char, string.match, string.lower
local bxor = bit.bxor

include("sha1.lua")

websocket.utilities.Base64Encode = util.Base64Encode

function websocket.utilities.XORMask(data, mask)
	local payload = #data
	local transformed_arr = {}
	for p = 1, payload, 2000 do
		local transformed = {}
		local top = p + 1999
		local last = top > payload and payload or top
		local original = {byte(data, p, last)}
		for i = 1, #original do
			local j = (i - 1) % 4 + 1
			transformed[i] = bxor(original[i], mask[j])
		end

		local xored = char(unpack(transformed))
		insert(transformed_arr, xored)
	end

	return concat(transformed_arr)
end

function websocket.utilities.HTTPHeaders(request)
	assert(type(request) == "table", "parameter #1 is not a table")
	assert(request[1] and match(request[1], ".*HTTP/1%.1"), "parameter #1 (table) doesn't contain data or doesn't contain a HTTP request on key 1")

	remove(request, 1)

	local headers = {}
	for i = 1, #request do
		local line = request[1]
		local name, val = match(line, "([^%s]+)%s*:%s*([^\r\n]+)")
		if name and val then
			name = lower(name)
			if not match(name, "sec%-websocket") then
				val = lower(val)
			end

			if not headers[name] then
				headers[name] = val
			else
				headers[name] = headers[name] .. "," .. val
			end
		elseif line == "" then
			break
		else
			error(line .. "(" .. #line .. ")")
		end
	end

	return headers
end
