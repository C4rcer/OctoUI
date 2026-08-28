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

--[[
	TRAVEL COMES FROM THE BAR'S EDGES, NOT FROM GetWidth.

	GetWidth on a frame stretched between two anchors reports HALF its real width on
	this client. That is the trap HANDOFF.md records against the auction listing, where
	a page anchored inside a 780-wide window measured 382 -- and `tick:SetAllPoints(bar)`
	is exactly that shape. The spark was told the bar was half as wide as it is and
	duly stopped in the middle of every tick, which reads as the tick never completing.

	GetLeft and GetRight are not affected, because they are positions rather than a
	derived size. They can be nil before a frame's rect has resolved, so GetWidth stays
	as a fallback and the LARGEST answer wins: a short reading can then never win, and
	all three describe the same rectangle so the largest cannot overshoot the bar.

	Nothing here is per-frame. It is measured once per tick, because a power bar only
	changes width when the unitframe is resized.
]]
local function BarWidth(frame)
	local width = frame:GetWidth() or 0

	local left, right = frame:GetLeft(), frame:GetRight()
	if left and right and (right - left) > width then
		width = right - left
	end

	--The parent IS the bar, since the tick is anchored to all four of its sides, so
	--this is the same rectangle read a third way rather than a wider one.
	local parent = frame:GetParent()
	if parent and parent.GetWidth then
		local parentWidth = parent:GetWidth() or 0
		if parentWidth > width then width = parentWidth end
	end

	return width
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
		--Re-measure once a tick, so resizing the unitframe corrects itself within two
		--seconds without costing anything on the frames in between.
		this.barWidth = nil
	end

	local width = this.barWidth
	if not width or width <= 0 then
		width = BarWidth(this)
		this.barWidth = width
	end
	if width <= 0 then return end

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
