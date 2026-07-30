local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local find, lower, strfind = string.find, string.lower, strfind
--WoW API / Variables
local GetContainerItemLink = GetContainerItemLink
local GetContainerNumSlots = GetContainerNumSlots
local GetItemInfo = GetItemInfo
local UseContainerItem = UseContainerItem
local UseInventoryItem = UseInventoryItem

--[[
	Ported from ShaguTweaks-extras, mods/macro-tweaks.lua
	MIT licence, Copyright (c) 2021 Eric Mauser (shagu)

	Adds /equip and /use to the macro api, keeps #showtooltip lines from being
	sent to chat, and keeps macro commands out of the chat input history.
]]

local function FindItem(item)
	for bag = 4, 0, -1 do
		for slot = 1, GetContainerNumSlots(bag) do
			local itemLink = GetContainerItemLink(bag, slot)
			if itemLink then
				local _, _, parse = strfind(itemLink, "(%d+):")
				local query = GetItemInfo(parse)
				if query and query ~= "" and lower(query) == lower(item) then
					return bag, slot
				end
			end
		end
	end

	return nil
end

function M:LoadMacroTweaks()
	--make sure #showtooltip inside macros won't be sent to chat
	local origSendChatMessage = SendChatMessage
	SendChatMessage = function(msg, chatType, language, channel)
		if E.db.general.macroTweaks and msg and find(msg, "^#showtooltip ") then return end
		origSendChatMessage(msg, chatType, language, channel)
	end

	--do not write macro calls into the chat input history
	if not ChatFrameEditBox._AddHistoryLine then
		local userinput

		ChatFrameEditBox._AddHistoryLine = ChatFrameEditBox.AddHistoryLine
		ChatFrameEditBox.AddHistoryLine = function(self, text)
			if E.db.general.macroTweaks and not userinput and text then
				if find(text, "^/run(.+)") then return end
				if find(text, "^/script(.+)") then return end
				if find(text, "^/cast(.+)") then return end
			end
			ChatFrameEditBox._AddHistoryLine(self, text)
		end

		local OnEnter = ChatFrameEditBox:GetScript("OnEnterPressed")
		ChatFrameEditBox:SetScript("OnEnterPressed", function(a1, a2, a3, a4)
			userinput = true
			OnEnter(a1, a2, a3, a4)
			userinput = nil
		end)
	end

	--add /use and /equip to the macro api:
	--https://wowwiki.fandom.com/wiki/Making_a_macro
	--supported arguments:
	--  /use <itemname>
	--  /use <inventory slot>
	--  /use <bag> <slot>
	SLASH_EQUIP1 = "/equip"
	SLASH_EQUIP2 = "/use"
	SlashCmdList.EQUIP = function(msg)
		if not E.db.general.macroTweaks then return end
		if not msg or msg == "" then return end
		local bag, slot, _
		if find(msg, "%d+%s+%d+") then
			_, _, bag, slot = find(msg, "(%d+)%s+(%d+)")
		elseif find(msg, "%d+") then
			_, _, slot = find(msg, "(%d+)")
		else
			bag, slot = FindItem(msg)
		end

		if bag and slot then
			UseContainerItem(bag, slot)
		elseif not bag and slot then
			UseInventoryItem(slot)
		end
	end
end
