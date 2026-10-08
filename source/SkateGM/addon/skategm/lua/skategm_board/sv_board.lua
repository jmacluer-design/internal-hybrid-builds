util.AddNetworkString(BOARD.NET_LOOK)
util.AddNetworkString(BOARD.NET_UP)
util.AddNetworkString(BOARD.NET_REQ)
util.AddNetworkString(BOARD.NET_IMG)

BOARD.images = BOARD.images or {}
BOARD.KEEP_SPARE = 64

local function Publish(ply)
	local t = ply.Sk8Look or {}
	ply:SetNW2String("skategm_look", BOARD.Encode({ d = t.d, w = t.w, i = t.i, r = t.r, x = t.x }))
end

function BOARD.Prune()
	local used = {}
	for _, p in ipairs(player.GetAll()) do if p.Sk8Look and p.Sk8Look.i then used[p.Sk8Look.i] = true end end
	local spare = {}
	for name, img in pairs(BOARD.images) do if not used[name] then spare[#spare + 1] = { name, img.at } end end
	table.sort(spare, function(a, b) return a[2] > b[2] end)
	for k = BOARD.KEEP_SPARE + 1, #spare do BOARD.images[spare[k][1]] = nil end
end

function BOARD.OnLook(ply, deck, wheels, imageBytes, now, rocket, extra)
	if now - (ply.Sk8LookAt or -100) < 0.4 then return false end
	ply.Sk8LookAt = now
	ply.Sk8Look = ply.Sk8Look or {}
	ply.Sk8Look.d = BOARD.ParseColor(deck) and deck or ""
	ply.Sk8Look.w = BOARD.ParseColor(wheels) and wheels or ""
	ply.Sk8Look.r = rocket == true
	ply.Sk8Look.x = BOARD.CleanExtra(extra)
	if imageBytes == 0 then
		ply.Sk8Look.i, ply.Sk8Up = "", nil
	elseif imageBytes and imageBytes > 0 and imageBytes <= BOARD.MAX_BYTES and now - (ply.Sk8UpAt or -100) >= 3 then
		ply.Sk8UpAt = now
		ply.Sk8Up = { size = imageBytes, parts = {}, got = 0 }
	end
	Publish(ply)
	return true
end

function BOARD.OnChunk(ply, index, data, now)
	local up = ply.Sk8Up
	if not up or type(data) ~= "string" or #data == 0 or #data > BOARD.CHUNK then return end
	local count = math.ceil(up.size / BOARD.CHUNK)
	if index < 1 or index > count or up.parts[index] then return end
	up.parts[index] = data
	up.got = up.got + #data
	if up.got > up.size then ply.Sk8Up = nil return end
	if up.got < up.size then return end
	ply.Sk8Up = nil
	for k = 1, count do if not up.parts[k] then return end end
	local whole = table.concat(up.parts)
	local kind = BOARD.ImageType(whole)
	if #whole ~= up.size or not kind then return end
	local name = BOARD.Hash(whole)
	BOARD.images[name] = { data = whole, kind = kind, at = now }
	ply.Sk8Look = ply.Sk8Look or {}
	ply.Sk8Look.i = name
	Publish(ply)
	BOARD.Prune()
	return name
end

function BOARD.Send(ply, name, now)
	local img = BOARD.ValidName(name) and BOARD.images[name]
	if not img then return false end
	ply.Sk8Sent = ply.Sk8Sent or {}
	if now - (ply.Sk8Sent[name] or -100) < 30 then return false end
	ply.Sk8Sent[name] = now
	local count = math.ceil(#img.data / BOARD.CHUNK)
	for k = 1, count do
		timer.Simple((k - 1) * 0.15, function()
			if not IsValid(ply) then return end
			local part = img.data:sub((k - 1) * BOARD.CHUNK + 1, k * BOARD.CHUNK)
			net.Start(BOARD.NET_IMG)
			net.WriteString(name)
			net.WriteString(img.kind)
			net.WriteUInt(k, 8)
			net.WriteUInt(count, 8)
			net.WriteUInt(#part, 16)
			net.WriteData(part, #part)
			net.Send(ply)
		end)
	end
	return true
end

net.Receive(BOARD.NET_LOOK, function(_, ply)
	local deck, wheels = net.ReadString(), net.ReadString()
	local bytes = net.ReadUInt(20)
	local rocket = net.ReadBool()
	local ok, extra = pcall(util.JSONToTable, net.ReadString())
	BOARD.OnLook(ply, deck, wheels, bytes, CurTime(), rocket, ok and extra or nil)
end)
net.Receive(BOARD.NET_UP, function(_, ply)
	local index = net.ReadUInt(8)
	local n = net.ReadUInt(16)
	if n == 0 or n > BOARD.CHUNK then return end
	BOARD.OnChunk(ply, index, net.ReadData(n), CurTime())
end)
net.Receive(BOARD.NET_REQ, function(_, ply)
	BOARD.Send(ply, net.ReadString(), CurTime())
end)
