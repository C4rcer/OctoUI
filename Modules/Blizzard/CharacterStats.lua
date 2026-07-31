local E, L, V, P, G = unpack(ElvUI)
local B = E:GetModule("Blizzard")
local LSM = LibStub("LibSharedMedia-3.0")

--[[
	The stats the 1.12 character sheet does not show.

	Displayed in a panel attached to the side of CharacterFrame rather than inside it.
	The 1.12 paperdoll has no room to spare and its layout is driven by Blizzard code
	we would have to fight for every row; an attached panel costs nothing and cannot
	break the frame it sits next to.

	Values come from Core\LibStats.lua, which scans gear, buffs and talents once. See
	the note there on which stats have an API and which exist only as tooltip text --
	anything the client will simply tell us is read, never scanned for.

	Rows are data. A new stat is an entry in ROWS plus, if it needs scanning, a pattern
	in LibStats -- not new code here.
]]

local pairs, type = pairs, type
local format = string.format

local CreateFrame = CreateFrame

--{ label, stat key or function, formatter }. A row whose value is 0 and which is not
--marked persistent is hidden, so a character with no spell power is not shown a
--column of zeroes.
--Labels are literal rather than L[] on purpose: this engine's AceLocale is created
--non-silent, so a key with no entry raises instead of falling back to itself. These
--want proper locale entries before anyone translates OctoUI, not a crash today.
local ROWS = {
	{"Spell Power", "spellPower", "%d"},
	{"Healing Power", "healingPower", "%d"},
	{"Spell Hit", "spellHit", "%d%%"},
	{"Spell Crit", "spellCrit", "%d%%"},
	{"Haste", "haste", "%d%%"},
	{"Casting Speed", "castingSpeed", "%d%%"},
	{"Mana Regen", "mp5", "%d"},
	{"Mana While Casting", "manaWhileCasting", "%d%%"},
	{"Spell Penetration", "spellPen", "%d"},
	{"Armor Penetration", "armorPen", "%d"},
	{"Melee Hit", "meleeHit", "%d%%"},
	{"Melee Crit", "meleeCrit", "%d%%"},
}

local panel

local function CreateRow(parent, index)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(14)
	row:SetWidth(180)

	row.label = row:CreateFontString(nil, "OVERLAY")
	row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.label:SetJustifyH("LEFT")

	row.value = row:CreateFontString(nil, "OVERLAY")
	row.value:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.value:SetJustifyH("RIGHT")

	if index == 1 then
		row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -8)
	else
		row:SetPoint("TOPLEFT", parent.rows[index - 1], "BOTTOMLEFT", 0, -2)
	end

	return row
end

function B:UpdateCharacterStats()
	if not panel or not panel:IsShown() then return end

	local font = LSM:Fetch("font", E.db.general.font)
	local size = E.db.general.fontSize
	local outline = E.db.general.fontStyle

	--Every row, always, including zeroes. Hiding empty rows made the whole panel
	--vanish for a character wearing no spell gear -- which reads as the feature being
	--broken rather than as an honest report of having none of that stat.
	for i = 1, getn(ROWS) do
		local def = ROWS[i]
		local row = panel.rows[i]
		local value = E.Stats:Get(def[2]) or 0

		row.label:SetFont(font, size, outline)
		row.value:SetFont(font, size, outline)
		row.label:SetText(def[1])
		row.value:SetText(format(def[3], value))
		row:Show()
	end

	panel:SetHeight((getn(ROWS) * 16) + 16)
end

function B:CreateCharacterStats()
	if panel then return end
	if not CharacterFrame then return end

	panel = CreateFrame("Frame", "OctoUI_CharacterStats", CharacterFrame)
	panel:SetWidth(180)
	panel:SetHeight(1)
	panel:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", 2, -12)
	E:CreateBackdrop(panel, "Transparent")

	panel.rows = {}
	panel.lastShown = 1
	for i = 1, getn(ROWS) do
		panel.rows[i] = CreateRow(panel, i)
	end

	--shown alongside the paperdoll only: the reputation and skill tabs share
	--CharacterFrame and have nothing to do with these numbers
	panel:SetScript("OnShow", function() B:UpdateCharacterStats() end)

	--HookScript on this client is a global taking the frame, not a frame method
	HookScript(CharacterFrame, "OnHide", function() panel:Hide() end)

	if PaperDollFrame then
		HookScript(PaperDollFrame, "OnShow", function()
			panel:Show()
			B:UpdateCharacterStats()
		end)
		HookScript(PaperDollFrame, "OnHide", function() panel:Hide() end)
	end

	panel:Hide()
end

function B:InitializeCharacterStats()
	if E.private.general.characterStats == false then return end

	self:CreateCharacterStats()

	--the scanner invalidates itself on these; we only need to redraw what is visible
	self:RegisterEvent("UNIT_INVENTORY_CHANGED", "UpdateCharacterStats")
	self:RegisterEvent("PLAYER_AURAS_CHANGED", "UpdateCharacterStats")
	self:RegisterEvent("CHARACTER_POINTS_CHANGED", "UpdateCharacterStats")
end
