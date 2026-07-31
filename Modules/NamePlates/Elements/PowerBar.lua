local E, L, V, P, G = unpack(ElvUI)
local mod = E:GetModule("NamePlates")
local LSM = LibStub("LibSharedMedia-3.0")

--[[
	Power bar for nameplates.

	Vanilla nameplates carry a health bar and nothing else -- there is no power
	information on the plate itself at any point. SuperWoW's GUID is what makes this
	possible: UnitMana and UnitPowerType accept it, so any visible plate can be asked
	about its power, not just the target.

	Mostly this matters for casters. Knowing a mob still has mana is the difference
	between draining it and wasting a global, and the target frame at the bottom of
	the screen only ever tells you about one of them.

	Sits between the health bar and the cast bar. It stays anchored even while hidden,
	collapsed to a hairline, so the cast bar below keeps its position without either
	element needing to know whether the other is shown.
]]

local unpack = unpack

local CreateFrame = CreateFrame
local UnitMana, UnitManaMax = UnitMana, UnitManaMax
local UnitPowerType = UnitPowerType

--Used when a profile predates this element, so it works without a settings migration
local DEFAULTS = {enable = true, height = 4}

--Standard vanilla power colours. Indexed by the number UnitPowerType returns.
local POWER_COLORS = {
	[0] = {0.31, 0.45, 0.63}, --mana
	[1] = {0.69, 0.31, 0.31}, --rage
	[2] = {0.65, 0.63, 0.35}, --focus
	[3] = {0.65, 0.63, 0.35}, --energy
}

local function GetDB(frame)
	local unitDB = mod.db.units[frame.UnitType]
	return (unitDB and unitDB.powerbar) or DEFAULTS
end

function mod:UpdateElement_Power(frame)
	if not frame.UnitType then return end

	local powerBar = frame.PowerBar
	if not powerBar then return end

	local db = GetDB(frame)
	if not (db.enable and frame.HealthBar:IsShown()) then
		powerBar:Hide()
		powerBar:SetHeight(0.01)
		return
	end

	--the same token the auras use: a GUID where SuperWoW gives one, else target or
	--mouseover, else nothing we can ask about
	local unit = self:GetPlateUnit(frame)
	if not unit then
		powerBar:Hide()
		powerBar:SetHeight(0.01)
		return
	end

	local max = UnitManaMax(unit)
	if not max or max <= 0 then
		--rage and energy sit at 0/100 on most mobs and say nothing useful; only show
		--a bar for units that actually have a pool
		powerBar:Hide()
		powerBar:SetHeight(0.01)
		return
	end

	local current = UnitMana(unit) or 0
	local powerType = UnitPowerType(unit) or 0

	powerBar:SetHeight(db.height or DEFAULTS.height)
	powerBar:SetMinMaxValues(0, max)
	powerBar:SetValue(current)

	if powerBar.powerType ~= powerType then
		powerBar.powerType = powerType
		local color = POWER_COLORS[powerType] or POWER_COLORS[0]
		powerBar:SetStatusBarColor(color[1], color[2], color[3])
	end

	powerBar:Show()
end

function mod:ConfigureElement_PowerBar(frame)
	local powerBar = frame.PowerBar
	local db = GetDB(frame)
	local offset = mod.db.units[frame.UnitType].castbar.offset or 1

	powerBar:ClearAllPoints()
	powerBar:SetPoint("TOPLEFT", frame.HealthBar, "BOTTOMLEFT", 0, -offset)
	powerBar:SetPoint("TOPRIGHT", frame.HealthBar, "BOTTOMRIGHT", 0, -offset)
	powerBar:SetHeight(db.height or DEFAULTS.height)

	powerBar:SetStatusBarTexture(LSM:Fetch("statusbar", mod.db.statusbar))
	powerBar.powerType = nil --force the colour to be reapplied on the next update
end

function mod:ConstructElement_PowerBar(parent)
	local frame = CreateFrame("StatusBar", "$parentPowerBar", parent)
	self:StyleFrame(frame)
	frame:SetHeight(0.01)
	frame:Hide()

	return frame
end
