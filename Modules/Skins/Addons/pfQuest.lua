local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local getn = table.getn
--WoW API / Variables
local HookScript = HookScript

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

local function LoadSkin()
	if not QuestLogFrame then return end

	SkinQuestLogButtons()
	HookScript(QuestLogFrame, "OnShow", SkinQuestLogButtons)
end

S:AddCallbackForAddon("pfQuest", "SkinPfQuest", LoadSkin)
