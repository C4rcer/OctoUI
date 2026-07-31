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
--instead.
--
--The fourth field is now a *fallback* rather than a verdict: if LibStats finds an API
--behind the same key, its number is the real total and the row prints it plainly with
--no marker, deciding that per session in E.Stats:IsComplete. Crit is the case that
--matters -- GetCritChance may well be on this client, and if it is, the row upgrades
--itself with nothing here changing. Deleting the field outright is still what to do
--once a stat has a real formula rather than a borrowed API.
--
--Label and attribute are locale keys, looked up when a row is drawn rather than
--here, so a translation loaded after this file still lands.
local ROWS = {
	{"Spell Power", "spellPower", "%d"},
	{"Healing Power", "healingPower", "%d"},

	--School-specific spell power. LibStats has always computed these -- gear that reads
	--"Increases damage done by Shadow spells and effects by up to 17" is filed under the
	--school rather than the total, because a fire spell gets nothing from it -- but until
	--now nothing displayed them, so a warlock in shadow gear saw only the generic number
	--and equipping a shadow piece appeared to do nothing at all.
	--
	--`onlyAbove` hides the row while it merely repeats the generic figure. Six rows that
	--all say the same thing as Spell Power would bury the one that does not, and a school
	--with no gear behind it has nothing to report that the row above has not said already.
	--This is not the same as hiding a zero: the value is shown whenever it is *news*.
	{"Arcane Damage", "spellPowerArcane", "%d", onlyAbove = "spellPower"},
	{"Fire Damage", "spellPowerFire", "%d", onlyAbove = "spellPower"},
	{"Frost Damage", "spellPowerFrost", "%d", onlyAbove = "spellPower"},
	{"Holy Damage", "spellPowerHoly", "%d", onlyAbove = "spellPower"},
	{"Nature Damage", "spellPowerNature", "%d", onlyAbove = "spellPower"},
	{"Shadow Damage", "spellPowerShadow", "%d", onlyAbove = "spellPower"},
	{"Spell Hit", "spellHit", "%d%%"},
	{"Spell Crit", "spellCrit", "%.2f%%", "Intellect"},
	{"Haste", "haste", "%d%%"},
	{"Casting Speed", "castingSpeed", "%d%%"},
	{"Mana Regen", "mp5", "%d", "Spirit"},
	{"Mana While Casting", "manaWhileCasting", "%d%%"},
	{"Spell Penetration", "spellPen", "%d"},
	{"Armor Penetration", "armorPen", "%d"},
	{"Melee Hit", "meleeHit", "%d%%"},
	{"Melee Crit", "meleeCrit", "%.2f%%", "Agility"},

	--API-sourced. No fourth field: the client hands over the whole number, base
	--included, so there is nothing about these to apologise for. A row whose function
	--is not on this client renders "--" with a tooltip saying so, which is decided at
	--runtime rather than here.
	{"Attack Power", "attackPower", "%d"},
	{"Ranged Attack Power", "rangedAttackPower", "%d"},
	{"Defense", "defense", "%d"},
	{"Dodge", "dodge", "%.2f%%"},
	{"Parry", "parry", "%.2f%%"},
	{"Block", "block", "%.2f%%"},
	{"Block Value", "blockValue", "%d"},

	--Off by default in Settings/Profile.lua: the 1.12 paperdoll already shows these
	--beside the character model, so they are here to be switched on, not to duplicate
	--what is on screen.
	{"Arcane Resistance", "resistArcane", "%d"},
	{"Fire Resistance", "resistFire", "%d"},
	{"Frost Resistance", "resistFrost", "%d"},
	{"Holy Resistance", "resistHoly", "%d"},
	{"Nature Resistance", "resistNature", "%d"},
	{"Shadow Resistance", "resistShadow", "%d"},
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

--Whether a row is switched on. An explicit entry in the profile always wins; a key the
--profile has never heard of falls back to what the row ships as, so a stat added to ROWS
--after a profile was written appears exactly as intended rather than always on. That
--distinction is what keeps the resistance rows -- which ship off, because the 1.12
--paperdoll already shows them -- from turning up uninvited on an existing profile.
--
--Public because the options checkbox has to answer the same question the same way. When
--it had its own `rows[key] ~= false` test the two disagreed about exactly these keys: a
--row would draw hidden while its box showed ticked.
function B:CharacterStatRowEnabled(statKey)
	local rows = DB().rows
	local set = rows and rows[statKey]
	if set ~= nil then return set ~= false end

	local defaults = P.general.characterStats.rows
	return not (defaults and defaults[statKey] == false)
end

local function RowHidden(statKey)
	return not B:CharacterStatRowEnabled(statKey)
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

	--Rescan before reading rather than trusting the dirty flag. LibStats marks itself
	--stale from its own frame, and this module is told about the same events through
	--AceEvent on a different one -- nothing decides which of the two frames the client
	--calls first. Lose that race and the panel draws the values from before the item came
	--off, then sits on them until the next event. Only reached with the panel actually on
	--screen, so a hidden character sheet still costs nothing.
	E.Stats:Invalidate()

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
		local value = E.Stats:Get(def[2]) or 0

		--A school row that only echoes the generic total is not worth a line; see the
		--note on onlyAbove in ROWS. Distinct from RowHidden, which is the user's choice.
		local redundant = def.onlyAbove and value <= (E.Stats:Get(def.onlyAbove) or 0)

		if RowHidden(def[2]) or redundant then
			row:Hide()
		else
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

			if not E.Stats:Available(def[2]) then
				--The stat has no scan patterns and its API is not on this client, so
				--there is no number to be had. Say nothing rather than print a zero
				--that would read as a real measurement of none.
				row.value:SetText("--")
				row.tipTitle = L[def[1]]
				row.tip = L["STATS_NO_API"]
			elseif def[4] and not E.Stats:IsComplete(def[2]) then
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

				--Spell crit is calculated from a server-core formula rather than read
				--from an API, so it shows its working: the rate actually measured from
				--your own casts, and the Intellect-per-crit that rate implies. If the two
				--percentages keep disagreeing over a few hundred casts, the formula is
				--wrong for this server and the implied figure is the correction.
				if def[2] == "spellCrit" then
					local measured, samples = E.Stats:ObservedSpellCrit()
					if measured then
						local implied = E.Stats:ImpliedIntPerCrit()
						row.tipTitle = L[def[1]]
						row.tip = format(L["STATS_CRIT_MEASURED"], measured, samples)
						if implied then
							row.tip = row.tip.."\n"..format(L["STATS_CRIT_IMPLIED"], implied)
						end
					end
				end
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
