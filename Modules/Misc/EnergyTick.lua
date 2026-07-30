local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--WoW API / Variables
local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitMana = UnitMana
local UnitPowerType = UnitPowerType

--[[
	Ported from ShaguTweaks-extras, mods/unitframe-energytick.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Upstream parents the spark to PlayerFrameManaBar and hardcodes a 120px travel
	distance with an 8.5px half-spark offset, which are Blizzard's player frame
	dimensions. Here it attaches to ElvUI's player power bar and derives both from
	the bar's actual width, so it tracks whatever size the unitframe is set to.

	The bar does not exist when Misc initialises, so attachment is deferred to
	PLAYER_ENTERING_WORLD.
]]

local SPARK_WIDTH = 17
local SPARK_HEIGHT = 27

local function OnEvent()
	local powerType = UnitPowerType("player")

	if powerType == 0 then
		this.mode = "MANA"
		this:Show()
	elseif powerType == 3 then
		this.mode = "ENERGY"
		this:Show()
	else
		this:Hide()
	end

	if event == "PLAYER_ENTERING_WORLD" then
		this.lastMana = UnitMana("player")
	end

	if (event == "UNIT_MANA" or event == "UNIT_ENERGY") and arg1 == "player" then
		this.currentMana = UnitMana("player")

		local diff = 0
		if this.lastMana then
			diff = this.currentMana - this.lastMana
		end

		if this.mode == "MANA" and diff < 0 then
			--Spending mana restarts the 5 second rule
			this.target = 5
		elseif this.mode == "MANA" and diff > 0 then
			--A regen tick well above the trickle means the 5 second rule expired
			if this.max ~= 5 and diff > (this.badtick and this.badtick * 1.2 or 5) then
				this.target = 2
			else
				this.badtick = diff
			end
		elseif this.mode == "ENERGY" and diff > 0 then
			this.target = 2
		end

		this.lastMana = this.currentMana
	end
end

local function OnUpdate()
	if this.target then
		this.start, this.max = GetTime(), this.target
		this.target = nil
	end

	if not this.start then return end

	this.current = GetTime() - this.start

	if this.current > this.max then
		this.start, this.max, this.current = GetTime(), 2, 0
	end

	--Derive travel from the live bar width rather than a fixed 120
	local width = this:GetWidth()
	if not width or width <= 0 then return end

	local pos = width * (this.current / this.max)
	this.spark:SetPoint("LEFT", pos - (SPARK_WIDTH / 2), 0)
end

function M:AttachEnergyTick()
	if self.EnergyTickFrame then return end

	local player = _G["ElvUF_Player"]
	local bar = player and player.Power
	if not bar then return end

	local tick = CreateFrame("Frame", "ElvUI_EnergyTick", bar)
	tick:SetAllPoints(bar)

	tick.spark = tick:CreateTexture(nil, "OVERLAY")
	tick.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
	tick.spark:SetWidth(SPARK_WIDTH)
	tick.spark:SetHeight(SPARK_HEIGHT)
	tick.spark:SetBlendMode("ADD")

	tick:RegisterEvent("PLAYER_ENTERING_WORLD")
	tick:RegisterEvent("UNIT_DISPLAYPOWER")
	tick:RegisterEvent("UNIT_ENERGY")
	tick:RegisterEvent("UNIT_MANA")
	tick:SetScript("OnEvent", OnEvent)
	tick:SetScript("OnUpdate", OnUpdate)

	self.EnergyTickFrame = tick
end

function M:UpdateEnergyTick()
	local tick = self.EnergyTickFrame
	if not tick then return end

	if E.db.general.energyTick then
		tick:Show()
	else
		tick:Hide()
	end
end

function M:LoadEnergyTick()
	local loader = CreateFrame("Frame")
	loader:RegisterEvent("PLAYER_ENTERING_WORLD")
	loader:SetScript("OnEvent", function()
		if not E.db.general.energyTick then return end

		M:AttachEnergyTick()
		M:UpdateEnergyTick()
	end)
end
