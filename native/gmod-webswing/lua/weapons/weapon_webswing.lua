-- Web Shooters.
--
-- This weapon is deliberately thin: the web, zip and dive logic runs in the predicted
-- SetupMove hook (lua/webswing/sh_core.lua), which reads this weapon's buttons from the
-- usercmd. The weapon only has to BE the active weapon (WebSwing.HoldingSwep looks for
-- SWEP.IsWebSwing), hide its crosshair for the HUD module's, and let go of the web when it
-- is put away or removed.
--
--   PRIMARY   (hold)  attach a web where you aim; sky or out of reach: assist picks a surface
--                     up and ahead. Let go to release with a slingshot boost.
--   SECONDARY         zip to the web (or to a ledge/roof you aim at) and vault over it
--   RELOAD    (hold)  dive, in the air
--   JUMP while attached: release and hop. CROUCH while attached: reel in.
--   FORWARD / A / D while attached: pump and steer.

AddCSLuaFile()

SWEP.PrintName = "Web Shooters"
SWEP.Author = "internal-hybrid-builds"
SWEP.Category = "Web Swing"
SWEP.Instructions = "Hold PRIMARY: web-swing. SECONDARY: zip. RELOAD (air): dive. JUMP: let go and hop. CROUCH: reel in. W/A/D: pump and steer."
SWEP.Purpose = "Swing between buildings and props."
SWEP.Spawnable = true
SWEP.AdminOnly = false

SWEP.Slot = 0
SWEP.SlotPos = 6
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = false
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false
SWEP.BounceWeaponIcon = false

-- stock hands-only view model (as the stock Fists weapon uses) and no world model
SWEP.UseHands = true
SWEP.ViewModel = "models/weapons/c_arms.mdl"
SWEP.ViewModelFOV = 54
SWEP.WorldModel = ""
SWEP.HoldType = "magic"

SWEP.IsWebSwing = true -- WebSwing.HoldingSwep() looks for this

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = true
SWEP.Primary.Ammo = "none"
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = true
SWEP.Secondary.Ammo = "none"

function SWEP:Initialize()
	self:SetHoldType(self.HoldType)
end

local function Play(self, name)
	local owner = self:GetOwner()
	if not IsValid(owner) then return end
	local vm = owner:GetViewModel()
	if not IsValid(vm) then return end
	local seq = vm:LookupSequence(name)
	if seq and seq >= 0 then vm:SendViewModelMatchingSequence(seq) end
end

function SWEP:Deploy()
	Play(self, "fists_draw")
	return true
end

-- the actual work is in SetupMove; these only have to exist and not do the engine's default
function SWEP:PrimaryAttack() self:SetNextPrimaryFire(CurTime() + 0.05) end
function SWEP:SecondaryAttack() self:SetNextSecondaryFire(CurTime() + 0.05) end
function SWEP:Reload() end
function SWEP:CanPrimaryAttack() return true end

-- put away mid-swing (another weapon, SkateGM's Skater mode, noclip...): let go of the web
function SWEP:Holster()
	local owner = self:GetOwner()
	if WebSwing and WebSwing.ForceClear and IsValid(owner) then
		WebSwing.ForceClear(owner, "holster")
	end
	return true
end

function SWEP:OnRemove()
	local owner = self:GetOwner()
	if WebSwing and WebSwing.ForceClear and IsValid(owner) then
		WebSwing.ForceClear(owner, "removed")
	end
end

function SWEP:OnDrop()
	local owner = self:GetOwner()
	if WebSwing and WebSwing.ForceClear and IsValid(owner) then
		WebSwing.ForceClear(owner, "dropped")
	end
end

function SWEP:ShouldDropOnDie() return false end
function SWEP:CanBePickedUpByNPCs() return false end

if CLIENT then
	-- WebSwing's own crosshair (cl_hud.lua) replaces the default one
	function SWEP:DoDrawCrosshair() return true end
	function SWEP:DrawWorldModel() end
	function SWEP:DrawWorldModelTranslucent() end
	function SWEP:PrintWeaponInfo() end
end
