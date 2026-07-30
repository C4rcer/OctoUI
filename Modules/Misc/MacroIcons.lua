local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local find, gfind = string.find, string.gfind
local pairs, tonumber = pairs, tonumber
--WoW API / Variables
local CreateFrame = CreateFrame
local GetActionText = GetActionText
local GetActionTexture = GetActionTexture
local GetMacroInfo = GetMacroInfo
local GetNumSpellTabs = GetNumSpellTabs
local GetSpellName = GetSpellName
local GetSpellTabInfo = GetSpellTabInfo
local GetSpellTexture = GetSpellTexture

--[[
	Ported from ShaguTweaks-extras, mods/macro-icons.lua, with the spellbook
	lookup taken from ShaguTweaks libs/libspell.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Reads #showtooltip / cast lines out of macros and puts the spell's icon on
	the action button. ElvUI's bars reuse the Blizzard action buttons
	(ActionButton1.., MultiBarRightButton1.. and so on), so the scan works on
	the same button names as upstream; only the bar-visibility gate changed,
	because ElvUI hides the Blizzard bar frames and reparents the buttons.

	Upstream called GetActionTexture with the 1-12 button index; that only
	matches the action slot on page one of the main bar, so the paged action
	id is used here instead.
]]

--spell name/rank -> spellbook index, cached (from libspell)
local spellmaxrank = {}
local function GetSpellMaxRank(name)
	local cache = spellmaxrank[name]
	if cache then return cache[1], cache[2] end

	local rank = { 0, nil }
	for i = 1, GetNumSpellTabs() do
		local _, _, offset, num = GetSpellTabInfo(i)
		for id = offset + 1, offset + num do
			local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
			if spellName == name then
				if not rank[2] then rank[2] = spellRank end

				local _, _, numRank = find(spellRank, " (%d+)$")
				if numRank and tonumber(numRank) > rank[1] then
					rank = { tonumber(numRank), spellRank }
				end
			end
		end
	end

	spellmaxrank[name] = { rank[2], rank[1] }
	return rank[2], rank[1]
end

local spellindex = {}
local function GetSpellIndex(name, rank)
	if not name then return end
	local cache = spellindex[name..(rank or "")]
	if cache then return cache[1], cache[2] end

	if not rank then rank = GetSpellMaxRank(name) end

	for i = 1, GetNumSpellTabs() do
		local _, _, offset, num = GetSpellTabInfo(i)
		for id = offset + 1, offset + num do
			local spellName, spellRank = GetSpellName(id, BOOKTYPE_SPELL)
			if rank and rank == spellRank and name == spellName then
				spellindex[name..rank] = { id, BOOKTYPE_SPELL }
				return id, BOOKTYPE_SPELL
			elseif not rank and name == spellName then
				spellindex[name] = { id, BOOKTYPE_SPELL }
				return id, BOOKTYPE_SPELL
			end
		end
	end
	spellindex[name..(rank or "")] = { nil }
	return nil
end

local prefixes = {
	"Action", "BonusAction", "MultiBarRight", "MultiBarLeft",
	"MultiBarBottomRight", "MultiBarBottomLeft"
}

--buttons whose icon we replaced, so disabling the option can restore them
local overridden = {}

local function ButtonMacroScan()
	local enabled = E.db.general.macroIcons

	for _, prefix in pairs(prefixes) do
		for i = 1, 12 do
			local button = _G[prefix.."Button"..i]
			local icon = _G[prefix.."Button"..i.."Icon"]

			if not button then break end

			local actionSlot = ActionButton_GetPagedID(button)
			local macro = actionSlot and GetActionText(actionSlot)
			local handled = false

			if macro and enabled then
				local name, body, _
				for slot = 1, 36 do -- 36 macro slots
					name, _, body = GetMacroInfo(slot)
					if name == macro then break end
				end

				if name and body then
					local match

					for line in gfind(body, "[^%\n]+") do
						_, _, match = find(line, "^#showtooltip (.+)")

						if not match then
							--custom tooltips can be specified via:
							--  /run --showtooltip SPELLNAME
							_, _, match = find(line, "%-%-showtooltip (.+)")
						end

						if not match then
							_, _, match = find(line, "^/cast (.+)")
						end

						if not match then
							_, _, match = find(line, "CastSpellByName%(%\"(.+)%\"%)")
						end

						if match then
							local _, _, spell, rank = find(match, "(.+)%((.+)%)")
							spell = spell or match
							button.spellslot, button.booktype = GetSpellIndex(spell, rank)

							--overwrite with the spell's texture where possible
							local texture = GetActionTexture(actionSlot)
							if button.spellslot and button.booktype then
								texture = GetSpellTexture(button.spellslot, button.booktype)
							end

							if texture and texture ~= icon:GetTexture() then
								icon:SetTexture(texture)
							end
							overridden[button] = icon
							handled = true
						end
					end
				end
			end

			--restore the real action texture once the option is off or the
			--macro no longer resolves to a spell
			if not handled and overridden[button] then
				if actionSlot and GetActionTexture(actionSlot) then
					overridden[button]:SetTexture(GetActionTexture(actionSlot))
				end
				overridden[button] = nil
				button.spellslot, button.booktype = nil, nil
			end
		end
	end
end

function M:LoadMacroIcons()
	local macroicons = CreateFrame("Frame", "ElvUI_MacroIcons", UIParent)
	macroicons:RegisterEvent("PLAYER_ENTERING_WORLD")
	macroicons:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	macroicons:RegisterEvent("ACTIONBAR_PAGE_CHANGED")
	macroicons:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
	macroicons:RegisterEvent("ACTIONBAR_SHOWGRID")
	macroicons:RegisterEvent("UPDATE_MACROS")
	macroicons:SetScript("OnEvent", ButtonMacroScan)

	M.MacroIconsFrame = macroicons
end
