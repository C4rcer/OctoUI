local E, L, V, P, G = unpack(ElvUI)
local mod = E:GetModule("NamePlates")
local LSM = LibStub("LibSharedMedia-3.0")

local unpack = unpack

local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local FAILED = FAILED
local INTERRUPTED = INTERRUPTED

function mod:UpdateElement_CastBarOnUpdate(elapsed)
	if self.casting then
		self.value = self.value + elapsed
		if self.value >= self.maxValue then
			self:SetValue(self.maxValue)
			self:Hide()
			return
		end
		self:SetValue(self.value)

		if self.castTimeFormat == "CURRENT" then
			self.Time:SetText(format("%.1f", self.value))
		elseif self.castTimeFormat == "CURRENT_MAX" then
			self.Time:SetText(format("%.1f / %.1f", self.value, self.maxValue))
		else --REMAINING
			self.Time:SetText(format("%.1f", (self.maxValue - self.value)))
		end

		if self.Spark then
			local sparkPosition = (self.value / self.maxValue) * self:GetWidth()
			self.Spark:SetPoint("CENTER", self, "LEFT", sparkPosition, 0)
		end
	elseif self.channeling then
		self.value = self.value - elapsed
		if self.value <= 0 then
			self:Hide()
			return
		end
		self:SetValue(self.value)

		if self.channelTimeFormat == "CURRENT" then
			self.Time:SetText(format("%.1f", (self.maxValue - self.value)))
		elseif self.channelTimeFormat == "CURRENT_MAX" then
			self.Time:SetText(format("%.1f / %.1f", (self.maxValue - self.value), self.maxValue))
		else --REMAINING
			self.Time:SetText(format("%.1f", self.value))
		end
	elseif self.holdTime > 0 then
		self.holdTime = self.holdTime - elapsed
	else
		self:Hide()
	end
end

function mod:UpdateElement_Cast(frame, event, unit, ...)
	if self.db.units[frame.UnitType].castbar.enable ~= true then return end
	if frame.unit ~= unit then return end

	if event == "UNIT_SPELLCAST_START" then
		local name, _, _, texture, startTime, endTime = UnitCastingInfo(unit)
		if not name then
			frame.CastBar:Hide()
			return
		end

		if frame.CastBar.Spark then
			frame.CastBar.Spark:Show()
		end
		frame.CastBar.Name:SetText(name)
		frame.CastBar.value = (GetTime() - (startTime / 1000))
		frame.CastBar.maxValue = (endTime - startTime) / 1000
		frame.CastBar:SetMinMaxValues(0, frame.CastBar.maxValue)
		frame.CastBar:SetValue(frame.CastBar.value)

		if frame.CastBar.Icon then
			frame.CastBar.Icon.texture:SetTexture(texture)
		end

		frame.CastBar.casting = true
		frame.CastBar.channeling = nil
		frame.CastBar.holdTime = 0

		frame.CastBar:Show()
	elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if not frame.CastBar:IsVisible() then
			frame.CastBar:Hide()
		end
		if (frame.CastBar.casting and event == "UNIT_SPELLCAST_STOP") or
		(frame.CastBar.channeling and event == "UNIT_SPELLCAST_CHANNEL_STOP") then
			if frame.CastBar.Spark then
				frame.CastBar.Spark:Hide()
			end

			frame.CastBar:SetValue(frame.CastBar.maxValue)
			if event == "UNIT_SPELLCAST_STOP" then
				frame.CastBar.casting = nil
			else
				frame.CastBar.channeling = nil
			end

			frame.CastBar:Hide()
		end
	elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
		if frame.CastBar:IsShown() then
			frame.CastBar:SetValue(frame.CastBar.maxValue)
			if frame.CastBar.Spark then
				frame.CastBar.Spark:Hide()
			end

			if event == "UNIT_SPELLCAST_FAILED" then
				frame.CastBar.Name:SetText(FAILED)
			else
				frame.CastBar.Name:SetText(INTERRUPTED)
			end
			frame.CastBar.casting = nil
			frame.CastBar.channeling = nil
			frame.CastBar.holdTime = self.db.units[frame.UnitType].castbar.timeToHold --How long the castbar should stay visible after being interrupted, in seconds
		end
	elseif event == "UNIT_SPELLCAST_DELAYED" then
		if frame:IsShown() then
			local name, _, _, _, startTime, endTime = UnitCastingInfo(unit)
			if not name then
				-- if there is no name, there is no bar
				frame.CastBar:Hide()
				return
			end

			frame.CastBar.Name:SetText(name)
			frame.CastBar.value = (GetTime() - (startTime / 1000))
			frame.CastBar.maxValue = (endTime - startTime) / 1000
			frame.CastBar:SetMinMaxValues(0, frame.CastBar.maxValue)

			if not frame.CastBar.casting then
				if frame.CastBar.Spark then
					frame.CastBar.Spark:Show()
				end

				frame.CastBar.casting = true
				frame.CastBar.channeling = nil
			end
		end
	elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
		local name, _, _, texture, startTime, endTime = UnitChannelInfo(unit)
		if not name then
			frame.CastBar:Hide()
			return
		end

		frame.CastBar.Name:SetText(name)
		frame.CastBar.value = (endTime / 1000) - GetTime()
		frame.CastBar.maxValue = (endTime - startTime) / 1000
		frame.CastBar:SetMinMaxValues(0, frame.CastBar.maxValue)
		frame.CastBar:SetValue(frame.CastBar.value)
		frame.CastBar.holdTime = 0

		if frame.CastBar.Icon then
			frame.CastBar.Icon.texture:SetTexture(texture)
		end
		if frame.CastBar.Spark then
			frame.CastBar.Spark:Hide()
		end

		frame.CastBar.casting = nil
		frame.CastBar.channeling = true

		frame.CastBar:Show()
	elseif event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
		if frame.CastBar:IsShown() then
			local name, _, _, _, startTime, endTime = UnitChannelInfo(unit)
			if not name then
				frame.CastBar:Hide()
				return
			end

			frame.CastBar.Name:SetText(name)
			frame.CastBar.value = ((endTime / 1000) - GetTime())
			frame.CastBar.maxValue = (endTime - startTime) / 1000
			frame.CastBar:SetMinMaxValues(0, frame.CastBar.maxValue)
			frame.CastBar:SetValue(frame.CastBar.value)
		end
	end
end

function mod:ConfigureElement_CastBar(frame)
	local castBar = frame.CastBar

	castBar:ClearAllPoints()
	--anchored to the power bar, not the health bar: the power bar sits between them
	--and stays anchored while hidden, so this lands correctly either way
	castBar:SetPoint("TOPLEFT", frame.PowerBar, "BOTTOMLEFT", 0, -self.db.units[frame.UnitType].castbar.offset)
	castBar:SetPoint("TOPRIGHT", frame.PowerBar, "BOTTOMRIGHT", 0, -self.db.units[frame.UnitType].castbar.offset)
	castBar:SetHeight(self.db.units[frame.UnitType].castbar.height)

	castBar.Icon:SetPoint("TOPLEFT", frame.HealthBar, "TOPRIGHT", self.db.units[frame.UnitType].castbar.offset, 0);
	castBar.Icon:SetPoint("BOTTOMLEFT", castBar, "BOTTOMRIGHT", self.db.units[frame.UnitType].castbar.offset, 0);
	castBar.Icon:SetWidth(self.db.units[frame.UnitType].castbar.height + self.db.units[frame.UnitType].healthbar.height + self.db.units[frame.UnitType].castbar.offset)

	castBar.Time:SetPoint("TOPRIGHT", castBar, "BOTTOMRIGHT", 0, -E.Border*3)
	castBar.Name:SetPoint("TOPLEFT", castBar, "BOTTOMLEFT", 0, -E.Border*3)
	castBar.Name:SetPoint("TOPRIGHT", castBar.Time, "TOPLEFT")

	castBar.Name:SetJustifyH("LEFT")
	castBar.Name:SetJustifyV("TOP")
	castBar.Name:SetFont(LSM:Fetch("font", self.db.font), self.db.fontSize, self.db.fontOutline)
	castBar.Time:SetJustifyH("RIGHT")
	castBar.Time:SetJustifyV("TOP")
	castBar.Time:SetFont(LSM:Fetch("font", self.db.font), self.db.fontSize, self.db.fontOutline)

	if self.db.units[frame.UnitType].castbar.hideSpellName then
		castBar.Name:Hide()
	else
		castBar.Name:Show()
	end
	if self.db.units[frame.UnitType].castbar.hideTime then
		castBar.Time:Hide()
	else
		castBar.Time:Show()
	end

	castBar:SetStatusBarTexture(LSM:Fetch("statusbar", self.db.statusbar))
	castBar:SetStatusBarColor(self.db.castColor.r, self.db.castColor.g, self.db.castColor.b)

	castBar.castTimeFormat = self.db.units[frame.UnitType].castbar.castTimeFormat
	castBar.channelTimeFormat = self.db.units[frame.UnitType].castbar.channelTimeFormat
end

function mod:ConstructElement_CastBar(parent)
	local frame = CreateFrame("StatusBar", "$parentCastBar", parent)
	self:StyleFrame(frame)

	--Wrapped, not passed directly: a 1.12 script handler receives no self and no
	--elapsed, only the globals `this` and `arg1`. Handing over the method raw is why
	--this sat commented out -- it would have errored on the first frame.
	frame:SetScript("OnUpdate", function()
		mod.UpdateElement_CastBarOnUpdate(this, arg1)
	end)

	frame.Icon = CreateFrame("Frame", nil, frame)
	frame.Icon.texture = frame.Icon:CreateTexture(nil, "BORDER")
	frame.Icon.texture:SetAllPoints()
	frame.Icon.texture:SetTexCoord(unpack(E.TexCoords))
	self:StyleFrame(frame.Icon)

	--Given a font here and not only in ConfigureElement_CastBar, because that step is
	--skipped for any unit type whose health bar is disabled -- and friendly players
	--and friendly NPCs ship disabled. StartCast still runs for them, so the first
	--friendly cast in range raises "Font not set" on SetText: a paladin summoning a
	--mount in a city is enough to do it. A font string that can be given text should
	--never be without a font, the same way the aura icons do it.
	local font = LSM:Fetch("font", self.db.font)

	frame.Name = frame:CreateFontString(nil, "OVERLAY")
	frame.Name:SetFont(font, self.db.fontSize, self.db.fontOutline)
	frame.Time = frame:CreateFontString(nil, "OVERLAY")
	frame.Time:SetFont(font, self.db.fontSize, self.db.fontOutline)
	frame.Spark = frame:CreateTexture(nil, "OVERLAY")
	frame.Spark:SetTexture([[Interface\CastingBar\UI-CastingBar-Spark]])
	frame.Spark:SetBlendMode("ADD")
	--SetSize is 3.0; this client wants the two calls
	frame.Spark:SetWidth(15)
	frame.Spark:SetHeight(15)
	frame:Hide()
	return frame
end
--[[
	Cast bars, driven by SuperWoW.

	The UNIT_SPELLCAST_* events the upstream element wants arrived in 2.0 and do not
	exist here, which is why their registration sits commented out in NamePlates.lua
	OnShow -- registering them would have been harmless and equally useless. Nothing
	ever drove the bar, so it never appeared.

	SuperWoW's UNIT_CASTEVENT is the replacement, and it is better suited than the
	events it stands in for: it reports the *caster's GUID* directly, so a cast maps to
	one specific nameplate with no name matching involved.

		arg1  caster GUID
		arg2  target GUID
		arg3  "START" | "CAST" | "CHANNEL" | "FAIL"
		arg4  spell ID
		arg5  cast time

	Without SuperWoW there is no cast information on this client at all, short of
	parsing the combat log for spell names, and the bar simply stays hidden.
]]

local castEvents = CreateFrame("Frame", "OctoUI_NamePlateCastEvents")

--Straight off the plate's parent frame rather than frame.guid, which is only stamped
--when the aura poll last ran and would lag a cast that starts the instant a plate does.
function mod:PlateByGUID(guid)
	if not guid or guid == "" then return end

	for frame in pairs(mod.VisiblePlates) do
		local parent = frame:GetParent()
		if parent and parent:GetName(1) == guid then
			return frame
		end
	end
end

function mod:StopCast(frame, failed)
	local castBar = frame and frame.CastBar
	if not castBar then return end

	castBar.casting = nil
	castBar.channeling = nil

	local hold = self.db.units[frame.UnitType] and self.db.units[frame.UnitType].castbar.timeToHold or 0
	if failed and hold > 0 then
		castBar.holdTime = hold
		castBar.Name:SetText(FAILED)
		castBar.Time:SetText("")
	else
		castBar.holdTime = 0
		castBar:Hide()
	end
end

function mod:StartCast(frame, spellID, castTime, channel)
	if not frame.UnitType then return end

	local db = self.db.units[frame.UnitType]
	if not (db and db.castbar.enable) then return end

	--This bar is anchored to the power bar, which is anchored to the health bar, and
	--none of the three are configured for a unit type whose health bar is off. Showing
	--one regardless means showing a bar that was never given an anchor or a height.
	--If friendly cast bars are ever wanted on their own, the configure step in
	--NamePlates.lua has to stop being gated on healthbar.enable first.
	if not db.healthbar.enable then return end

	local castBar = frame.CastBar
	if not castBar then return end

	--SpellInfo is SuperWoW's. Guarded because a spell it does not know still deserves
	--a bar; only the name and icon are lost.
	local name, _, icon
	if SpellInfo then name, _, icon = SpellInfo(spellID) end

	--reported in milliseconds
	castTime = tonumber(castTime) or 0
	if castTime > 100 then castTime = castTime / 1000 end
	if castTime <= 0 then return end

	castBar.casting = not channel
	castBar.channeling = channel
	castBar.value = channel and castTime or 0
	castBar.maxValue = castTime
	castBar.holdTime = 0

	castBar:SetMinMaxValues(0, castTime)
	castBar:SetValue(castBar.value)
	castBar:SetStatusBarColor(self.db.castColor.r, self.db.castColor.g, self.db.castColor.b)

	castBar.Name:SetText(name or "")
	--Icon is a Frame holding a texture, not a texture itself
	if castBar.Icon and castBar.Icon.texture then
		castBar.Icon.texture:SetTexture(icon or [[Interface\Icons\INV_Misc_QuestionMark]])
	end

	castBar:Show()
end

castEvents:SetScript("OnEvent", function()
	local caster, _, castType, spellID, castTime = arg1, arg2, arg3, arg4, arg5

	local frame = mod:PlateByGUID(caster)
	if not frame then return end

	if castType == "START" or castType == "CAST" then
		mod:StartCast(frame, spellID, castTime, false)
	elseif castType == "CHANNEL" then
		mod:StartCast(frame, spellID, castTime, true)
	elseif castType == "FAIL" then
		mod:StopCast(frame, true)
	end
end)

--Only if SuperWoW is loaded; the event does not exist otherwise and registering a
--name this client does not know throws.
if SUPERWOW_VERSION then
	castEvents:RegisterEvent("UNIT_CASTEVENT")
end
