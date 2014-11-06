websocket.frame = {}

websocket.frame.CONTINUATION = 0
websocket.frame.TEXT = 1
websocket.frame.BINARY = 2
-- 3 to 7 reserved for more non-control frames
websocket.frame.CLOSE = 8
websocket.frame.PING = 9
websocket.frame.PONG = 10
-- 11 to 15 reserved for more control frames

local strwithstr = "%s%s"

function websocket.frame.encodeheader(length, opcode, mask, fin)
	local header = {opcode or 1}
	if fin == nil or fin == true then
		header[1] = bit.bor(header[1], 128)
	end

	local maskStart = 3
	local length = #data
	if length <= 125 then
		header[2] = length
	elseif length >= 126 and length <= 65535 then
		maskStart = 5
		header[2] = 126
		header[3] = bit.band(bit.rshift(length, 8), 255)
		header[4] = bit.band(length, 255)
	else
		maskStart = 11
		header[2] = 127
		header[3] = bit.band(bit.rshift(length, 56), 255)
		header[4] = bit.band(bit.rshift(length, 48), 255)
		header[5] = bit.band(bit.rshift(length, 40), 255)
		header[6] = bit.band(bit.rshift(length, 32), 255)
		header[7] = bit.band(bit.rshift(length, 24), 255)
		header[8] = bit.band(bit.rshift(length, 16), 255)
		header[9] = bit.band(bit.rshift(length, 8), 255)
		header[10] = bit.band(length, 255)
	end

	if mask then
		header[2] = bit.bor(header[2], 128) -- set bit 7

		header[maskStart + 0] = mask[1]
		header[maskStart + 1] = mask[2]
		header[maskStart + 2] = mask[3]
		header[maskStart + 3] = mask[4]
	end

	return string.char(unpack(header))
end

function websocket.frame.decodeheader(header)
	local headerlen = #header
	local minlen = 2
	assert(headerlen >= minlen, "websocket frame header needs to be at least 2 bytes long")

	local complete = true

	local byte1 = header:byte(1)
	local byte2 = header:byte(2)

	local length = bit.band(byte2, 127)
	if length == 126 then
		minlen = minlen + 2
		if headerlen >= minlen then
			length = {header:byte(minlen - 1, minlen)}
			length = bit.lshift(length[1], 8) + length[2]
		else
			complete = false
		end
	elseif length == 127 then
		minlen = minlen + 8
		if headerlen >= minlen then
			length = {header:byte(minlen - 7, minlen)}
			length =	bit.lshift(length[1], 56) +
						bit.lshift(length[2], 48) +
						bit.lshift(length[3], 40) +
						bit.lshift(length[4], 32) +
						bit.lshift(length[5], 24) +
						bit.lshift(length[6], 16) +
						bit.lshift(length[7], 8) +
						length[8]
		else
			complete = false
		end
	end

	local masked = bit.band(byte2, 128) ~= 0
	local mask
	if masked then
		minlen = minlen + 4
		if headerlen >= minlen then
			mask = {header:sub(minlen - 3, minlen):byte(1, 4)}
		else
			complete = false
		end
	end

	if complete then
		-- complete, length, opcode, masked, fin, mask
		return complete, length, bit.band(byte1, 16), masked, bit.band(byte1, 128) ~= 0, mask
	end

	return complete, minlen
end

function websocket.frame.encode(data, opcode, masked, fin)
	local mask
	if masked == true then
		mask = {math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255)}
		data = websocket.utilities.xor_mask(data, mask)
	end

	local header = websocket.frame.encodeheader(#data, opcode, mask, fin)

	return strwithstr:format(header, data)
end

function websocket.frame.decode(data)
	local complete, length, opcode, masked, fin, mask = websocket.frame.decodeheader(data)
	assert(complete, "received an incomplete websocket frame to decode")

	if masked then
		data = websocket.utilities.xor_mask(data, mask)
	end

	return data, fin, opcode, extradata
end