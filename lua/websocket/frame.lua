websocket.frame = websocket.frame or {}

websocket.frame.CONTINUATION = 0
websocket.frame.TEXT = 1
websocket.frame.BINARY = 2
-- 3 to 7 reserved for more non-control frames
websocket.frame.CLOSE = 8
websocket.frame.PING = 9
websocket.frame.PONG = 10
-- 11 to 15 reserved for more control frames

local floor = math.floor
local byte, char = string.byte, string.char
local band, bor = bit.band, bit.bor
local assert = assert

function websocket.frame.EncodeHeader(length, opcode, mask, fin)
	local op = opcode or 1
	if fin == nil or fin == true then
		op = bor(op, 0x80)
	end

	local length = #data
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
			length % 0x100
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

function websocket.frame.DecodeHeader(header)
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
		-- complete, length, opcode, masked, fin, mask
		return complete, length, band(byte1, 0x10), masked, band(byte1, 0x80) ~= 0, mask
	end

	return complete, minlen
end

function websocket.frame.Encode(data, opcode, masked, fin)
	local mask
	if masked == true then
		mask = {random(0, 255), random(0, 255), random(0, 255), random(0, 255)}
		data = websocket.utilities.XORMask(data, mask)
	end

	return websocket.frame.EncodeHeader(#data, opcode, mask, fin) .. data
end

function websocket.frame.Decode(data)
	local complete, length, opcode, masked, fin, mask = websocket.frame.DecodeHeader(data)
	assert(complete, "received an incomplete websocket frame to decode")

	if masked then
		data = websocket.utilities.XORMask(data, mask)
	end

	return data, fin, opcode, extradata
end
