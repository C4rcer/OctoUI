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
local GameTooltip = GameTooltip

--{ label, stat key, formatter, attribute the uncomputed base comes from }.
--
--A fourth field marks a stat this panel can only partly account for. Spell crit,
--melee crit and mana regen are not gear sums: every character has a base from an
--attribute (Intellect, Agility, Spirit) before a single item is worn, and that
--needs per-class, per-level coefficients we do not have yet. Until then the scan
--only sees the gear, buff and talent part, so those rows must not print a bare
--number -- a lone "0" reads as the panel being broken rather than as an honest
--"you have no crit gear". See the note in UpdateCharacterStats for what is shown
--instead. Delete the fourth field the moment a row gets a real formula.
--Label and attribute are locale keys, looked up when a row is drawn rather than
--here, so a translation loaded after this file still lands.
local ROWS = {
	{"Spell Power", "spellPower", "%d"},
	{"Healing Power", "healingPower", "%d"},
	{"Spell Hit", "spellHit", "%d%%"},
	{"Spell Crit", "spellCrit", "%d%%", "Intellect"},
	{"Haste", "haste", "%d%%"},
	{"Casting Speed", "castingSpeed", "%d%%"},
	{"Mana Regen", "mp5", "%d", "Spirit"},
	{"Mana While Casting", "manaWhileCasting", "%d%%"},
	{"Spell Penetration", "spellPen", "%d"},
	{"Armor Penetration", "armorPen", "%d"},
	{"Melee Hit", "meleeHit", "%d%%"},
	{"Melee Crit", "meleeCrit", "%d%%", "Agility"},
}

local panel

--Which side of CharacterFrame the panel hangs off. { own point, frame point, x, y }.
local ANCHORS = {
	["RIGHT"] = {"TOPLEFT", "TOPRIGHT", 2, -12},
	["LEFT"] = {"TOPRIGHT", "TOPLEFT", -2, -12},
}

--Read through a nil-safe path: a profile written before these settings existed has
--no characterStats table at all, and the panel has to keep working on one.
local function DB()
	return E.db.general.characterStats or P.general.characterStats
end

local function Enabled()
	return DB().enable ~= false
end

--A row the user has switched off. Unknown keys count as on, so a stat added to ROWS
--shows up for existing profiles instead of silently never appearing.
local function RowHidden(statKey)
	local rows = DB().rows
	return rows and rows[statKey] == false
end

local function CreateRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetHeight(14)
	row:SetWidth(180)

	row.label = row:CreateFontString(nil, "OVERLAY")
	row.label:SetPoint("LEFT", row, "LEFT", 4, 0)
	row.label:SetJustifyH("LEFT")

	row.value = row:CreateFontString(nil, "OVERLAY")
	row.value:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.value:SetJustifyH("RIGHT")

	--A partial row says so on hover. UpdateCharacterStats sets row.tip and clears it
	--again for complete rows, so a row that gains a formula stops explaining itself
	--without anything here changing. Handlers get `this`, never self.
	row:EnableMouse(true)
	row:SetScript("OnEnter", function()
		if not this.tip then return end

		GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
		GameTooltip:AddLine(this.tipTitle, 1, 1, 1)
		GameTooltip:AddLine(this.tip, nil, nil, nil, 1)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)

	return row
end

--Stat key -> localised label, for the row picker in the options. Built from ROWS so
--the options never hold a second copy of the list.
function B:GetCharacterStatRows()
	local rows = {}

	for i = 1, getn(ROWS) do
		rows[ROWS[i][2]] = L[ROWS[i][1]]
	end

	return rows
end

--Called on creation and whenever the side is changed in the options.
function B:PositionCharacterStats()
	if not panel then return end

	local anchor = ANCHORS[DB().position] or ANCHORS.RIGHT
	panel:ClearAllPoints()
	panel:SetPoint(anchor[1], CharacterFrame, anchor[2], anchor[3], anchor[4])
end

function B:UpdateCharacterStats()
	if not panel then return end

	if not Enabled() then
		panel:Hide()
		return
	end

	--Switched back on while the character sheet is open: the toggle hid the panel, so
	--show it again here rather than making the user close and reopen the sheet.
	if PaperDollFrame and PaperDollFrame:IsShown() then
		panel:Show()
	end

	if not panel:IsShown() then return end

	local font = LSM:Fetch("font", E.db.general.font)
	local size = E.db.general.fontSize
	local outline = E.db.general.fontStyle
	local shown, previous = 0, nil

	--Every row the user has left on, always, including zeroes. Hiding empty rows made
	--the whole panel vanish for a character wearing no spell gear -- which reads as the
	--feature being broken rather than as an honest report of having none of that stat.
	--A row switched off in the options is a different thing and does get hidden.
	for i = 1, getn(ROWS) do
		local def = ROWS[i]
		local row = panel.rows[i]

		if RowHidden(def[2]) then
			row:Hide()
		else
			local value = E.Stats:Get(def[2]) or 0

			--Each visible row hangs off the previous *visible* one, so a row switched
			--off closes the gap rather than leaving a hole in the middle of the panel.
			shown = shown + 1
			row:ClearAllPoints()
			if previous then
				row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
			else
				row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -8)
			end
			previous = row

			row.label:SetFont(font, size, outline)
			row.value:SetFont(font, size, outline)
			row.label:SetText(L[def[1]])

			if def[4] then
				--Partial stat: what we have is a bonus on top of a base we cannot compute.
				--"--" when there is no bonus to report, so "we do not calculate this" never
				--looks like "you have none of it", and an explicit "+" when there is, so the
				--number is never mistaken for the total. Never a bare figure either way.
				row.value:SetText(value > 0 and ("+"..format(def[3], value)) or "--")
				row.tipTitle = L[def[1]]
				row.tip = format(L["STATS_INCOMPLETE"], L[def[4]])
			else
				row.value:SetText(format(def[3], value))
				row.tipTitle = nil
				row.tip = nil
			end

			row:Show()
		end
	end

	--every row switched off is an empty box, which looks like a bug rather than a choice
	if shown == 0 then
		panel:Hide()
		return
	end

	panel:SetHeight((shown * 16) + 16)
end

function B:CreateCharacterStats()
	if panel then return end
	if not CharacterFrame then return end

	panel = CreateFrame("Frame", "OctoUI_CharacterStats", CharacterFrame)
	panel:SetWidth(180)
	panel:SetHeight(1)
	E:CreateBackdrop(panel, "Transparent")
	self:PositionCharacterStats()

	panel.rows = {}
	for i = 1, getn(ROWS) do
		panel.rows[i] = CreateRow(panel)
	end

	--shown alongside the paperdoll only: the reputation and skill tabs share
	--CharacterFrame and have nothing to do with these numbers
	panel:SetScript("OnShow", function() B:UpdateCharacterStats() end)

	--HookScript on this client is a global taking the frame, not a frame method
	HookScript(CharacterFrame, "OnHide", function() panel:Hide() end)

	if PaperDollFrame then
		HookScript(PaperDollFrame, "OnShow", function()
			if not Enabled() then return end

			panel:Show()
			B:UpdateCharacterStats()
		end)
		HookScript(PaperDollFrame, "OnHide", function() panel:Hide() end)
	end

	panel:Hide()
end

function B:InitializeCharacterStats()
	--Built even when disabled: the option then costs nothing to flip, no reload, and
	--the frame is a dozen font strings. UpdateCharacterStats does the hiding.
	self:CreateCharacterStats()

	--the scanner invalidates itself on these; we only need to redraw what is visible
	self:RegisterEvent("UNIT_INVENTORY_CHANGED", "UpdateCharacterStats")
	self:RegisterEvent("PLAYER_AURAS_CHANGED", "UpdateCharacterStats")
	self:RegisterEvent("CHARACTER_POINTS_CHANGED", "UpdateCharacterStats")
end
