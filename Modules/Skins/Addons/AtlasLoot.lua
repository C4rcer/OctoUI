local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack
local getn = table.getn
local pcall = pcall
--WoW API / Variables
local HookScript = HookScript

--[[
	Skin for AtlasLoot (TW Edition).

	Names were read out of AtlasLoot/Core/AtlasLoot.xml rather than guessed. Note the
	addon mixes two conventions -- `$parent_Thing` gives AtlasLootDefaultFrame_Thing,
	while several widgets are declared with an explicit full name and a `parent=`
	attribute instead -- so the search widgets are AtlasLootDefaultFrameSearchBox with
	no underscore while the menu buttons are AtlasLootDefaultFrame_Menu with one.

	A handful are declared `$Parent` with a capital P, which the 1.12 XML parser does
	not substitute. Both spellings are listed; a name that does not resolve costs
	nothing here.

	Every lookup is guarded, for the reason set out in OctoShop.lua: one missing name
	or unexpected object type kills the rest of LoadSkin and silently leaves
	everything after it unskinned.

	ITEM ROWS ARE DELIBERATELY LEFT MOSTLY ALONE. S:HandleItemButton finds an icon by
	looking for `<name>IconTexture` or `<name>Icon`; AtlasLoot's is `<name>_Icon`, so
	it would stop, strip the row's textures and never restore the icon it could not
	find. The rows are text with a small icon and clash far less than the window art
	does, so they get a texcoord trim and nothing more.
]]

--Top level windows: strip the Blizzard art, apply the addon's own backdrop.
local windows = {
	"AtlasLootDefaultFrame",
	"AtlasLootItemsFrame",
	"AtlasLootOptionsFrame",
	"AtlasLootPanel",
	"AtlasLootInfo"
}

local closeButtons = {
	"AtlasLootDefaultFrame_CloseButton",
	"AtlasLootItemsFrame_CloseButton"
}

local buttons = {
	--main window
	"AtlasLootDefaultFrame_Atlas", "AtlasLootDefaultFrame_Options",
	"AtlasLootDefaultFrame_Menu", "AtlasLootDefaultFrame_SubMenu",
	"AtlasLootDefaultFrame_Preset1", "AtlasLootDefaultFrame_Preset2",
	"AtlasLootDefaultFrame_Preset3", "AtlasLootDefaultFrame_Preset4",
	--search cluster, declared with explicit names
	"AtlasLootDefaultFrameSearchButton", "AtlasLootDefaultFrameSearchClearButton",
	"AtlasLootDefaultFrameSearchOptionsButton", "AtlasLootDefaultFrameLastResultButton",
	"AtlasLootDefaultFrameWishListButton",
	--loot window
	"AtlasLootItemsFrame_BACK", "AtlasLootItemsFrame_NEXT", "AtlasLootItemsFrame_PREV",
	"AtlasLootServerQueryButton", "AtlasLootQuickLooksButton",
	--side panel
	"AtlasLootPanel_WorldEvents", "AtlasLootPanel_Sets", "AtlasLootPanel_Reputation",
	"AtlasLootPanel_PvP", "AtlasLootPanel_Crafting", "AtlasLootPanel_Options",
	"AtlasLootPanel_AtlasLoot",
	"AtlasLootInfoHidePanel",
	--options window, including the unsubstituted $Parent spellings
	"AtlasLootOptionsFrameDone",
	"AtlasLootOptionsFrameResetPosition", "$ParentResetPosition",
	"AtlasLootOptionsFrameDefaultSettings", "$ParentDefaultSettings"
}

local editBoxes = {
	"AtlasLootDefaultFrameSearchBox",
	"AtlasLootSearchBox"
}

local checkBoxes = {
	"AtlasLootOptionsFrameSafeLinks", "AtlasLootOptionsFrameAllLinks",
	"AtlasLootOptionsFrameDefaultTT", "AtlasLootOptionsFrameLootlinkTT",
	"AtlasLootOptionsFrameItemSyncTT", "AtlasLootOptionsFrameEquipCompare",
	"AtlasLootOptionsFrameItemID", "AtlasLootOptionsFrameMinimap",
	"AtlasLootOptionsFrameHidePanel", "AtlasLootOptionsFrameOpaque",
	"AtlasLootOptionsFrameItemSpam"
}

local sliders = {
	"AtlasLootOptionsFrameSliderButtonRad", "$ParentSliderButtonRad",
	"AtlasLootOptionsFrameSliderButtonPos", "$ParentSliderButtonPos"
}

--Every widget is skinned inside its own pcall. Guarding the lookups is not enough -- the
--Atlas-CFM skin raised part way down its button list and left everything after it
--unskinned, which on screen reads as "the addon is half themed" and names no culprit.
--One bad frame should cost that frame and nothing else.
--
--`isSkinned`/`template` are set by the S:Handle* helpers, so re-running is harmless --
--which matters because the loot window is skinned again every time it is shown.
local failures
local function Apply(names, handler)
	for i = 1, getn(names) do
		local name = names[i]
		local frame = _G[name]

		if frame and frame.GetObjectType then
			local ok = pcall(handler, frame)
			if not ok then
				failures = failures and (failures..", "..name) or name
			end
		end
	end
end

--A button carrying a texture instead of a label must not be stripped: S:HandleButton
--calls E:StripTextures, which takes the icon with it and leaves an empty box.
local function SkinButton(frame)
	if frame:GetObjectType() ~= "Button" or frame.template or frame.isSkinned then return end

	local text = frame.GetText and frame:GetText()
	if text and text ~= "" then
		S:HandleButton(frame)
		return
	end

	local normal = frame.GetNormalTexture and frame:GetNormalTexture()
	if normal and normal.SetTexCoord then
		normal:SetTexCoord(unpack(E.TexCoords))
	end

	E:CreateBackdrop(frame, "Default", true)
	E:StyleButton(frame)
	frame.isSkinned = true
end

local function SkinItemRows()
	local i = 1
	while true do
		local icon = _G["AtlasLootItem_"..i.."_Icon"]
		if not icon then break end

		if icon.SetTexCoord then
			icon:SetTexCoord(unpack(E.TexCoords))
		end

		i = i + 1
		if i > 100 then break end --never loop forever on a live client
	end
end

local function LoadSkin()
	Apply(windows, function(frame)
		if frame:GetObjectType() ~= "Frame" or frame.template then return end

		E:StripTextures(frame)
		E:SetTemplate(frame, "Transparent")
	end)

	Apply(closeButtons, function(frame) S:HandleCloseButton(frame) end)

	Apply(buttons, SkinButton)

	Apply(editBoxes, function(frame) S:HandleEditBox(frame) end)
	Apply(checkBoxes, function(frame) S:HandleCheckBox(frame) end)
	Apply(sliders, function(frame) S:HandleSliderFrame(frame) end)

	SkinItemRows()

	--Rows are created as loot tables are browsed, not up front, so a single pass at
	--load catches only what already exists.
	--HasScript is not a frame method on this client -- MinimapButtons.lua carries its own
	--helper for exactly that reason -- and the compat HookScript already copes with there
	--being no original handler, so there is nothing to test for first.
	local items = _G["AtlasLootItemsFrame"]
	if items then
		HookScript(items, "OnShow", SkinItemRows)
	end

	if failures then
		E:Print("|cffff9900AtlasLoot skin|r could not skin: "..failures)
		failures = nil
	end
end

S:AddCallbackForAddon("AtlasLoot", "SkinAtlasLoot", LoadSkin)
