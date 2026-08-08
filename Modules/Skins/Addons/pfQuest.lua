local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local getn = table.getn
--WoW API / Variables
local HookScript = HookScript
local hooksecurefunc = hooksecurefunc

--[[
	Skin for pfQuest's quest log additions.

	pfQuest bolts six buttons onto the Blizzard quest log, all built from
	UIPanelButtonTemplate, so next to a skinned quest log they keep the gold
	Blizzard look:

		pfQuestShow  pfQuestHide  pfQuestClean  pfQuestReset
		pfQuestOnline  pfQuestLanguage

	They are created lazily in pfQuest:AddQuestLogIntegration rather than at
	load, so skinning on ADDON_LOADED would find nothing. Skin on quest log
	show instead, which is the first moment they can exist, and keep it
	idempotent via .template (set by E:SetTemplate inside S:HandleButton) so
	repeated opens do not stack hover hooks.

	pfQuest is a fine addon to run alongside OctoUI; only the styling clashes.
]]

local buttons = {
	"pfQuestShow",
	"pfQuestHide",
	"pfQuestClean",
	"pfQuestReset",
	"pfQuestOnline",
	"pfQuestLanguage"
}

local function SkinQuestLogButtons()
	for i = 1, getn(buttons) do
		local button = _G[buttons[i]]
		--Online and Language are plain Buttons carrying their own coloured
		--FontString rather than a template, so only touch what is a real
		--button and not already handled.
		if button and not button.template and button.GetObjectType
		and button:GetObjectType() == "Button" then
			S:HandleButton(button)
		end
	end
end

--Move the Translate/? pair OUT of the scrolling quest text and up beside the quest count.
--
--pfQuest anchors both to QuestLogDetailScrollChildFrame -- the scroll CHILD, not the scroll
--frame -- so they ride the quest description as it scrolls and sit on top of the quest
--title. `/oprobe mouse` on 2026-08-08:
--
--    pfQuestOnline   TOPRIGHT to QuestLogDetailScrollChildFrame TOPRIGHT at -12, -10
--    pfQuestLanguage RIGHT to pfQuestOnline LEFT
--
--Reparenting to QuestLogFrame is the part that matters: re-anchoring alone would leave them
--children of the scroll child, still clipped by the scroll frame and still moving with it.
--
--Only pfQuestOnline is given a position. Language keeps pfQuest's own "sit to my left"
--anchor, so the pair stays together and the gap between them stays whatever pfQuest wanted.
local function PlaceTranslateButtons()
	local online, language = _G["pfQuestOnline"], _G["pfQuestLanguage"]
	if not (online and language and QuestLogQuestCount) then return end

	online:SetParent(QuestLogFrame)
	language:SetParent(QuestLogFrame)

	--The x nudge is not slop. QuestLogQuestCount is a 69 wide FontString whose rendered text
	--does not fill it, so its TOPRIGHT is not where "Quests: 11/20" visually ends -- aligning
	--to the box left the pair sitting short of the text. Measured against the text, not the
	--box it lives in.
	online:ClearAllPoints()
	E:Point(online, "BOTTOMRIGHT", QuestLogQuestCount, "TOPRIGHT", 10, 6)

	language:ClearAllPoints()
	E:Point(language, "RIGHT", online, "LEFT", -4, 0)

	--Above the frame's backdrop, which is a child of QuestLogFrame and would otherwise draw
	--over them now that they are siblings of it rather than living in the scroll frame.
	local level = QuestLogFrame:GetFrameLevel() + 5
	online:SetFrameLevel(level)
	language:SetFrameLevel(level)
end

local function LoadSkin()
	if not QuestLogFrame then return end

	SkinQuestLogButtons()
	PlaceTranslateButtons()

	HookScript(QuestLogFrame, "OnShow", function()
		SkinQuestLogButtons()
		PlaceTranslateButtons()
	end)

	--pfQuest rebuilds its integration when the selected quest changes, and anything it
	--re-anchors there would snap straight back into the scroll child. Re-applied after its
	--own update rather than only on open -- the same lesson as the Atlas profession tabs.
	if _G.QuestLog_Update then
		hooksecurefunc("QuestLog_Update", PlaceTranslateButtons)
	end
end

S:AddCallbackForAddon("pfQuest", "SkinPfQuest", LoadSkin)
