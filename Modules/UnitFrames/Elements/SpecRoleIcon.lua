local E, L, V, P, G = unpack(ElvUI)
local UF = E:GetModule("UnitFrames")

--Cache global variables
--Lua functions
local pairs, type = pairs, type
local format, lower = string.format, string.lower
local tinsert, getn = table.insert, table.getn
--WoW API / Variables
local CreateFrame = CreateFrame
local UnitName, UnitExists = UnitName, UnitExists

--[[
	Tank / healer / damage icon beside a group member's name.

	1.12 HAS NO ROLE API. UnitGroupRolesAssigned and GetPartyAssignment are later
	additions -- checked against all 1235 addon files installed here and used by
	none of them -- and talent inspection of another player does not arrive until
	TBC. So a role cannot be asked for, only told.

	It is told by the threat meter, which already computes the local player's
	dominant spec from talent point counts and broadcasts that spec's spellbook
	tab TEXTURE to the group as `TWTRoleTexture:`. Modules\Threat\TWThreat.lua has
	done this for its own bars all along; ThreatMeter:GetSpecTexture reads the
	same table.

	CONSEQUENCE: this only ever knows about group members running OctoUI. Everyone
	else broadcasts nothing and gets NO ICON -- deliberately, because the
	alternative is guessing from class, and a Shadow Priest drawn as a healer is
	the exact mistake that gets someone killed. Absence means "not known", so
	every icon that does appear can be trusted.

	The spec-to-role table below is the weak point: it maps textures that cannot
	be read off this client from outside the game. An unmapped texture draws
	nothing rather than guessing, and `/octoui-roles` lists every texture seen
	against what it resolved to, so a gap shows up as a missing row instead of a
	silent wrong icon.
]]

--Spellbook tab textures, lowercased basenames, as GetSpellTabInfo reports them.
--Only specs whose role is unambiguous are listed.
--
--FERAL DRUID IS DELIBERATELY ABSENT. Bear tank and cat damage are the same talent
--tab and therefore the same texture, so there is nothing here to tell them apart.
--It resolves to no icon rather than to a coin flip.
local SPEC_ROLE = {
	--Tanks
	["ability_warrior_defensivestance"] = "TANK",
	["spell_holy_devotionaura"] = "TANK",
	--Healers
	["spell_holy_holybolt"] = "HEALER",
	["spell_holy_wordfortitude"] = "HEALER",
	["spell_nature_magicimmunity"] = "HEALER",
	["spell_nature_healingtouch"] = "HEALER",
	--Damage
	["ability_warrior_savageblow"] = "DAMAGER",
	["ability_warrior_innerrage"] = "DAMAGER",
	["spell_holy_auraoflight"] = "DAMAGER",
	["ability_hunter_beasttaming"] = "DAMAGER",
	["ability_marksmanship"] = "DAMAGER",
	["ability_hunter_swiftstrike"] = "DAMAGER",
	["ability_rogue_eviscerate"] = "DAMAGER",
	["ability_backstab"] = "DAMAGER",
	["ability_stealth"] = "DAMAGER",
	["spell_shadow_shadowwordpain"] = "DAMAGER",
	["spell_nature_lightning"] = "DAMAGER",
	["spell_nature_lightningshield"] = "DAMAGER",
	["spell_holy_magicalsentry"] = "DAMAGER",
	["spell_fire_firebolt02"] = "DAMAGER",
	["spell_frost_frostbolt02"] = "DAMAGER",
	["spell_shadow_deathcoil"] = "DAMAGER",
	["spell_shadow_metamorphosis"] = "DAMAGER",
	["spell_shadow_rainoffire"] = "DAMAGER",
	["spell_nature_starfall"] = "DAMAGER"
}
UF.SPEC_ROLE = SPEC_ROLE

--Literal shapes rather than class art: a sword, a shield and a cross read at 12
--pixels, where a spec icon does not.
local ROLE_TEXTURE = {
	["TANK"] = "Interface\\Icons\\INV_Shield_06",
	["HEALER"] = "Interface\\Icons\\Spell_Holy_Renew",
	["DAMAGER"] = "Interface\\Icons\\INV_Sword_27"
}
UF.ROLE_TEXTURE = ROLE_TEXTURE

--Frames that own these icons. Kept here rather than walked out of oUF so the
--refresh touches exactly the frames that can draw one.
local tracked = {}

--[[
	ROLES ARE A SET, NOT A VALUE.

	A player queuing as both tank and damage has selected two roles, and showing
	one of them is showing the wrong one half the time. So everything below deals
	in an ordered list, even where the list has one entry.

	Two sources, best first:

	  DECLARED  what the player actually chose when queuing. Exact, covers dual
	            roles, and would work for anyone -- but nothing writes it yet.
	            SetDeclaredRoles is the seam for it; see /oprobe group, which
	            logs the role chat traffic this needs to be built from.

	  INFERRED  from the spec the threat meter broadcasts. Always a single role,
	            OctoUI users only, and blind to a Feral Druid's two.
]]
local declared = {}

--Entry point for a declared role. `roles` is an array of "TANK"/"HEALER"/
--"DAMAGER", or nil to forget the player.
function UF:SetDeclaredRoles(name, roles)
	if not name then return end
	declared[name] = roles
	UF:RefreshSpecRoleIcons()
end

function UF:DeclaredRoles(name)
	return name and declared[name] or nil
end

--Ordered roles for a unit: declared if anyone has told us, else inferred from
--the broadcast spec, else nothing at all.
function UF:SpecRolesFor(unit)
	if not unit or not UnitExists(unit) then return nil end

	local name = UnitName(unit)
	local given = name and declared[name]
	if given and getn(given) > 0 then return given, nil, true end

	local TM = E.GetModule and E:GetModule("ThreatMeter", true)
	if not (TM and TM.GetSpecTexture) then return nil end

	local texture = name and TM:GetSpecTexture(name)
	if not texture or texture == "" then return nil end

	local role = SPEC_ROLE[lower(texture)]
	if not role then return nil, texture end

	return {role}, texture
end

function UF:Construct_SpecRoleIcon(frame)
	--A holder with two textures rather than one: a dual-role player needs both,
	--and a frame that can only draw one would have to pick.
	local holder = CreateFrame("Frame", nil, frame.RaisedElementParent)
	E:Size(holder, 26, 12)
	holder.icons = {}

	for i = 1, 2 do
		local icon = holder:CreateTexture(nil, "OVERLAY")
		E:Size(icon, 12)
		--Trimmed: the 1.12 icon border is baked into the texture, not a region.
		icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
		icon:Hide()
		holder.icons[i] = icon
	end

	frame.SpecRoleIcon = holder
	tinsert(tracked, frame)

	return holder
end

function UF:Configure_SpecRoleIcon(frame)
	local holder = frame.SpecRoleIcon
	if not holder then return end

	local db = frame.db and frame.db.specRoleIcon
	if not db or not db.enable then
		holder:Hide()
		return
	end

	local size = db.size or 12
	local point = db.anchorPoint or "TOPLEFT"

	E:Size(holder, size * 2 + 2, size)
	holder:ClearAllPoints()
	E:Point(holder, point, frame.Health or frame, point, db.xOffset or 0, db.yOffset or 0)
	holder:Show()

	for i = 1, 2 do
		local icon = holder.icons[i]
		E:Size(icon, size)
		icon:ClearAllPoints()
		if i == 1 then
			E:Point(icon, "LEFT", holder, "LEFT", 0, 0)
		else
			E:Point(icon, "LEFT", holder.icons[1], "RIGHT", 2, 0)
		end
	end

	UF:UpdateSpecRoleIcon(frame)
end

function UF:UpdateSpecRoleIcon(frame)
	local holder = frame and frame.SpecRoleIcon
	if not holder then return end

	local db = frame.db and frame.db.specRoleIcon
	if not db or not db.enable then
		holder:Hide()
		return
	end

	local roles = UF:SpecRolesFor(frame.unit)

	for i = 1, 2 do
		local icon = holder.icons[i]
		local role = roles and roles[i]
		local texture = role and ROLE_TEXTURE[role]

		if texture then
			icon:SetTexture(texture)
			icon:Show()
		else
			icon:Hide()
		end
	end
end

--Called when a role broadcast lands, which is on no schedule this element controls.
function UF:RefreshSpecRoleIcons()
	for i = 1, getn(tracked) do
		UF:UpdateSpecRoleIcon(tracked[i])
	end
end

--Roster changes move people between units, so an icon left alone would keep
--showing the previous occupant's role.
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PARTY_MEMBERS_CHANGED")
watcher:RegisterEvent("RAID_ROSTER_UPDATE")
watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
watcher:SetScript("OnEvent", function()
	UF:RefreshSpecRoleIcons()
end)

--Report: who is known, what they broadcast, and what it resolved to. The spec
--texture table cannot be verified from outside the game, so this is how an
--unmapped spec is found -- it shows up as a row with no role.
function UF:SpecRoleReport()
	local TM = E.GetModule and E:GetModule("ThreatMeter", true)
	if not (TM and TM.AllSpecTextures) then
		E:Print(L["Role icons: the threat meter is not loaded, so no roles are known."])
		return
	end

	local any
	E:Print(L["Role icons - broadcast specs seen this session:"])

	for name, texture in pairs(TM:AllSpecTextures()) do
		any = true
		local role = type(texture) == "string" and SPEC_ROLE[lower(texture)]
		E:Print(format("  %s = %s |cff9d9d9d(%s)|r", name,
			role or "|cffff8000"..L["unmapped"].."|r", tostring(texture)))
	end

	for name, roles in pairs(declared) do
		any = true
		local text = ""
		for i = 1, getn(roles) do
			text = text..((i > 1) and "+" or "")..roles[i]
		end
		E:Print(format("  %s = %s |cff9d9d9d(%s)|r", name, text, L["declared"]))
	end

	if not any then
		E:Print("  "..L["Nobody in range is broadcasting a spec."])
	end
end
