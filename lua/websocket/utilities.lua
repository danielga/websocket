websocket.state = {}
websocket.state.CONNECTING = 1
websocket.state.OPEN = 2
websocket.state.CLOSING = 3
websocket.state.CLOSED = 4

websocket.utilities = {}

local unpack = unpack
local tinsert, tconcat = table.insert, table.concat
local sbyte, schar = string.byte, string.char
local bxor = bit.bxor

include("sha1.lua")
websocket.utilities.sha1 = sha1
sha1 = nil

websocket.utilities.base64encode = util.Base64Encode

function websocket.utilities.xor_mask(data, mask)
	local payload = #data
	local transformed_arr = {}
	for p = 1, payload, 2000 do
		local transformed = {}
		local top = p + 1999
		local last = top > payload and payload or top
		local original = {sbyte(data, p, last)}
		for i = 1, #original do
			local j = (i - 1) % 4 + 1
			transformed[i] = bxor(original[i], mask[j])
		end

		local xored = schar(unpack(transformed))
		tinsert(transformed_arr, xored)
	end

	return tconcat(transformed_arr)
end

function websocket.utilities.http_headers(request)
	assert(type(request) == "table", "parameter #1 is not a table")
	assert(request[1] and request[1]:match(".*HTTP/1%.1"), "parameter #1 (table) doesn't contain data or doesn't contain a HTTP request on key 1")

	table.remove(request, 1)

	local headers = {}
	for i = 1, #request do
		local line = request[1]
		local name, val = line:match("([^%s]+)%s*:%s*([^\r\n]+)")
		if name and val then
			name = name:lower()
			if not name:match("sec%-websocket") then
				val = val:lower()
			end

			if not headers[name] then
				headers[name] = val
			else
				headers[name] = headers[name] .. "," .. val
			end
		elseif line == "" then
			break
		else
			assert(false, line .. "(" .. #line .. ")")
		end
	end

	return headers
end