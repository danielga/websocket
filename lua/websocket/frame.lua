local websocket = websocket

websocket.frame = websocket.frame or {}

local frame = websocket.frame

frame.CONTINUATION = 0
frame.TEXT = 1
frame.BINARY = 2
-- 3 to 7 reserved for more non-control frames
frame.CLOSE = 8
frame.PING = 9
frame.PONG = 10
-- 11 to 15 reserved for more control frames

local floor = math.floor
local byte, char = string.byte, string.char
local band, bor = bit.band, bit.bor
local rshift, lshift = bit.rshift, bit.lshift
local assert = assert

function frame.EncodeHeader(length, opcode, mask, fin)
	local op = opcode or 1
	if fin == nil or fin == true then
		op = bor(op, 0x80)
	end

	if length <= 0x7D then
		if mask == nil then
			return char(op, length)
		end

		return char(
			op,
			bor(length, 0x80),
			mask[1],
			mask[2],
			mask[3],
			mask[4]
		)
	elseif length <= 0xFFFF then
		if mask == nil then
			return char(
				op,
				0x7E,
				floor(length / 0x100) % 0x100,
				length % 0x100
			)
		end

		return char(
			op,
			0xFE,
			floor(length / 0x100) % 0x100,
			length % 0x100,
			mask[1],
			mask[2],
			mask[3],
			mask[4]
		)
	end

	if mask == nil then
		return char(
			op,
			0x7F,
			0xFF,
			floor(length / 0x1000000000000) % 0x100,
			floor(length / 0x10000000000) % 0x100,
			floor(length / 0x100000000) % 0x100,
			floor(length / 0x1000000) % 0x100,
			floor(length / 0x10000) % 0x100,
			floor(length / 0x100) % 0x100,
			length % 0x100
		)
	end

	return char(
		op,
		0xFF,
		0xFF,
		floor(length / 0x1000000000000) % 0x100,
		floor(length / 0x10000000000) % 0x100,
		floor(length / 0x100000000) % 0x100,
		floor(length / 0x1000000) % 0x100,
		floor(length / 0x10000) % 0x100,
		floor(length / 0x100) % 0x100,
		length % 0x100,
		mask[1],
		mask[2],
		mask[3],
		mask[4]
	)
end

function frame.DecodeHeader(header)
	local headerlen = #header
	local minlen = 2
	assert(headerlen >= minlen, "websocket frame header needs to be at least 2 bytes long")

	local complete = true

	local byte1 = byte(header, 1)
	local byte2 = byte(header, 2)

	local length = band(byte2, 0x7F)
	if length == 0x7E then
		minlen = minlen + 2
		if headerlen >= minlen then
			local l1, l2 = byte(header, minlen - 1, minlen)
			length = l1 * 0x100 + l2
		else
			complete = false
		end
	elseif length == 0x7F then
		minlen = minlen + 8
		if headerlen >= minlen then
			local m = 0x100
			local l1, l2, l3, l4, l5, l6, l7, l8 = byte(header, minlen - 7, minlen)
			length = ((((((l1 * m + l2) * m + l3) * m + l4) * m + l5) * m + l6) * m + l7) * m + l8
		else
			complete = false
		end
	end

	local masked = band(byte2, 0x80) ~= 0
	local mask
	if masked then
		minlen = minlen + 4
		if headerlen >= minlen then
			mask = {byte(header, minlen - 3, minlen)}
		else
			complete = false
		end
	end

	if complete then
		-- complete, length, opcode, masked, fin, mask, headerLen
		return complete, length, band(byte1, 0x10), masked, band(byte1, 0x80) ~= 0, mask, minlen
	end

	return complete, minlen
end

function frame.Encode(data, opcode, masked, fin)
	local mask
	if masked == true then
		mask = {random(0, 255), random(0, 255), random(0, 255), random(0, 255)}
		data = websocket.utilities.XORMask(data, mask)
	end

	return frame.EncodeHeader(#data, opcode, mask, fin) .. data
end

function frame.EncodeClose(code, reason)
	local out = char(
		band(rshift(code, 8), 0xFF),
		band(code, 0xFF)
	)

	if reason then
		out = out .. tostring(reason)
	end

	return out
end

function frame.DecodeClose(data)
	assert(#data >= 2, "websocket close frame needs to be at least 2 bytes long")

	local byte1 = byte(data, 1)
	local byte2 = byte(data, 2)

	return lshift(byte1, 8) + byte2, #data > 2 and header:sub(3, -1) or false
end
