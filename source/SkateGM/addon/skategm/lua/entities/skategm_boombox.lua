AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Boombox"
ENT.Category = "SkateGM"
ENT.Spawnable = true
ENT.Editable = true
ENT.Information = "Plays internet radio to everyone nearby. Use it to change station; right-click > Edit Properties for your own stream."
ENT.Model = "models/props_lab/citizenradio.mdl"

local function Stations() return SKATEGM_STATIONS or {} end

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Station", { KeyName = "station", Edit = { type = "Int", order = 1, min = 0, max = 20, title = "Station (0 = off)" } })
	self:NetworkVar("String", 0, "StreamUrl", { KeyName = "url", Edit = { type = "Generic", order = 2, waitforenter = true, title = "Your own stream URL" } })
	self:NetworkVar("Float", 0, "Volume", { KeyName = "volume", Edit = { type = "Float", order = 3, min = 0, max = 1, title = "Volume" } })
	self:NetworkVar("Float", 1, "Range", { KeyName = "range", Edit = { type = "Float", order = 4, min = 200, max = 5000, title = "Range" } })
	self:NetworkVar("String", 1, "PlayingName")
	self:NetworkVar("String", 2, "PlayingUrl")
	if SERVER then
		self:NetworkVarNotify("Station", function(ent) timer.Simple(0, function() if IsValid(ent) then ent:Resolve() end end) end)
		self:NetworkVarNotify("StreamUrl", function(ent) timer.Simple(0, function() if IsValid(ent) then ent:Resolve() end end) end)
		self:SetStation(1)
		self:SetVolume(0.7)
		self:SetRange(1500)
	end
end

function ENT:Choices()
	local n = #Stations()
	if self:GetStreamUrl() ~= "" then n = n + 1 end
	return n
end

function ENT:Current()
	local st = self:GetStation()
	if st <= 0 then return nil end
	local list = Stations()
	if list[st] then return list[st][1], list[st][2] end
	local url = self:GetStreamUrl()
	if st == #list + 1 and url:match("^https?://%S+$") then return "Your stream", url end
	return nil
end

if SERVER then
	function ENT:Resolve()
		local name, url = self:Current()
		self:SetPlayingName(name or "")
		self:SetPlayingUrl(url or "")
	end

	function ENT:Initialize()
		self:SetModel(self.Model)
		self:PhysicsInit(SOLID_VPHYSICS)
		self:SetMoveType(MOVETYPE_VPHYSICS)
		self:SetSolid(SOLID_VPHYSICS)
		self:SetUseType(SIMPLE_USE)
		local phys = self:GetPhysicsObject()
		if IsValid(phys) then phys:Wake() end
		self:Resolve()
	end

	function ENT:Next()
		local st = self:GetStation() + 1
		if st > self:Choices() then st = 0 end
		self:SetStation(st)
		self:Resolve()
		return st
	end

	function ENT:Use(activator)
		if (self.nextUse or 0) > CurTime() then return end
		self.nextUse = CurTime() + 0.3
		self:Next()
		self:EmitSound("buttons/lightswitch2.wav", 60)
		if IsValid(activator) and activator:IsPlayer() then
			activator:ChatPrint("[SkateGM] Boombox: " .. (self:GetPlayingName() ~= "" and self:GetPlayingName() or "off"))
		end
	end

	function ENT:SpawnFunction(ply, tr, class)
		if not tr.Hit then return end
		local ent = ents.Create(class)
		ent:SetPos(tr.HitPos + tr.HitNormal * 12)
		ent:SetAngles(Angle(0, (IsValid(ply) and ply:EyeAngles().y or 0) + 180, 0))
		ent:Spawn()
		ent:Activate()
		return ent
	end
end

if CLIENT then
	local cvVolume = CreateClientConVar("skategm_boombox_volume", "1", true, false, "Boombox volume for you (0 = muted)", 0, 1)

	function ENT:StopStream()
		if IsValid(self.stream) then self.stream:Stop() end
		self.stream, self.streamUrl = nil, nil
	end

	function ENT:Think()
		local url = self:GetPlayingUrl()
		if url == "" or cvVolume:GetFloat() <= 0 then url = nil end
		if url ~= self.streamUrl then
			self:StopStream()
			self.streamUrl = url
			if url and sound and sound.PlayURL then
				local me = self
				sound.PlayURL(url, "3d noblock", function(ch)
					if not IsValid(ch) then return end
					if not IsValid(me) or me.streamUrl ~= url then ch:Stop() return end
					me.stream = ch
					ch:Play()
				end)
			end
		end
		local ch = self.stream
		if IsValid(ch) then
			local range = self:GetRange()
			ch:SetPos(self:GetPos())
			ch:Set3DFadeDistance(range * 0.2, range * 2)
			ch:SetVolume(self:GetVolume() * cvVolume:GetFloat())
		end
		self:SetNextClientThink(CurTime() + 0.1)
		return true
	end

	function ENT:OnRemove() self:StopStream() end

	function ENT:Draw()
		self:DrawModel()
		local name = self:GetPlayingName() ~= "" and self:GetPlayingName() or "Off"
		local eye = EyePos()
		if eye:DistToSqr(self:GetPos()) > 400 * 400 then return end
		local ang = (eye - self:GetPos()):Angle()
		ang = Angle(0, ang.y + 90, 90)
		cam.Start3D2D(self:GetPos() + Vector(0, 0, 22), ang, 0.12)
			draw.SimpleTextOutlined(name, "DermaLarge", 0, 0, Color(120, 220, 255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2, Color(0, 0, 0, 200))
		cam.End3D2D()
	end
end
