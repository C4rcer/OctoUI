local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack
local getn = table.getn
local pcall = pcall
local find = string.find
--WoW API / Variables
local HookScript = HookScript

--[[
	Skin for Atlas-CFM.

	Atlas-CFM already ships its own skinning layer, CFMAtlas/AtlaspfUI.lua, but it is
	gated behind `IsAddOnLoaded("pfUI") and pfUI`, so it lies dormant here and there is
	nothing to fight. It is still the best reference available: the frame lists below
	are largely the ones that file styles, which is the author saying what is safe to
	touch rather than us guessing from a name dump.

	Unlike AtlasLoot, this addon builds its frames in Lua rather than XML. The main
	window is created in a `do ... end` block at file scope so it exists by the time
	ADDON_LOADED fires, but the loot list and its rows are built on demand, hence the
	re-skin on show.

	Every lookup is guarded, for the reason set out in OctoShop.lua: one missing name
	or unexpected object type kills the rest of LoadSkin and silently leaves
	everything after it unskinned.

	Deliberately not touched:
	  * AtlasCFMMinimapButton -- the Maps module owns minimap button placement.
	  * AtlasCFMLootTooltip / ...2 -- GameTooltips, the Tooltip module's business.
	  * AtlasCFMScrollBar / AtlasCFMLootScrollBar -- named like scroll bars but created
	    as ScrollFrames. S:HandleScrollBar wants the slider, not the scroll frame, so
	    it would be handed the wrong object. Left until someone can look in game.
	  * AtlasCFMProfessionTab<n> -- CheckButtons used as tabs. Neither HandleCheckBox
	    nor HandleTab is obviously right and getting it wrong makes them unreadable.
]]

local windows = {
	"AtlasCFMFrame",
	"AtlasCFMOptionsFrame",
	"AtlasCFMLootItemsFrame",
	"AtlasCFMLootPanel",
	"AtlasCFMButtonFrame"
}

--The main window is drawn as four edge frames plus a body; stripping the body alone
--leaves the border art behind.
local edges = {
	"AtlasCFMFrameTop", "AtlasCFMFrameBottom", "AtlasCFMFrameBottom2",
	"AtlasCFMFrameLeft", "AtlasCFMFrameRight"
}

local closeButtons = {
	"AtlasCFMCloseButton",
	"AtlasCFMLootItemsFrame_CloseButton"
}

local buttons = {
	"AtlasCFMSwitchButton", "AtlasCFMLockButton", "AtlasCFMInstanceTypeButton",
	"AtlasCFMCraftCollapseAll", "AtlasCFMLootFilterButton", "AtlasCFMLootQuickLooksButton",
	--paging, spelled both ways in the addon's own sources
	"AtlasCFMLootItemsFrame_BACK", "AtlasCFMLootItemsFrame_Back",
	"AtlasCFMLootItemsFrame_NEXT", "AtlasCFMLootItemsFrame_PREV",
	--side panel
	"AtlasCFMLootPanel_WorldEvents", "AtlasCFMLootPanel_Sets",
	"AtlasCFMLootPanel_Reputation", "AtlasCFMLootPanel_PvP",
	"AtlasCFMLootPanel_Crafting", "AtlasCFMLootPanel_Dungeons",
	"AtlasCFMLootPanel_Instances"
}

local editBoxes = {
	"AtlasCFMSearchEditBox", "AtlasCFMLootSearchBox",
	"AtlasCFMCraftSearchBox", "AtlasCFMTradeSkillSearchBox"
}

local checkBoxes = {
	"AtlasCFMCraftCategories", "AtlasCFMCraftHaveMaterials", "AtlasCFMCraftImprovesSkill",
	"AtlasCFMCraftShowSkillLevels", "AtlasCFMTradeSkillHaveMaterials",
	"AtlasCFMTradeSkillImprovesSkill", "AtlasCFMTradeSkillShowLevels",
	"AtlasCFMOptionReagent"
}

local sliders = {
	"AtlasCFMOptionReagentRowsSlider"
}

--Every widget is skinned inside its own pcall. Guarding the lookups is not enough: the
--first version of this skin raised part way down the button list and everything after it
--went unskinned, which on screen reads as "the addon is half themed" and gives no clue
--which widget stopped it. One bad frame should cost that frame and nothing else.
--
--The S:Handle* helpers set `isSkinned`/`template`, so re-running is harmless, which
--matters because this is called again on every show of the loot list.
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
--calls E:StripTextures, which takes the icon with it and leaves an empty box. That is
--what AtlasCFMLockButton became. Give those a backdrop and keep their art.
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

--Most of this addon's buttons are created with `nil` for a name --
--`CreateFrame("Button", nil, searchBox, "OptionsButtonTemplate")` -- so Search, Clear,
--Last Result, WishList and the category tabs have no global name and a name list can
--never reach them. That, not an error, is why the bottom bar stayed Blizzard-grey.
--Walk the children instead and skin by object type.
--
--Anything whose name matches one of these is left alone: loot rows carry their own icon
--and text and look wrong in a button backdrop, the minimap button belongs to the Maps
--module, tooltips belong to the Tooltip module, and the profession tabs are CheckButtons
--used as tabs where guessing wrong makes them unreadable.
local skipNames = {
	"AtlasCFMLootItem", "AtlasCFMLootMenuItem", "AtlasCFMLootContainerItem",
	"AtlasCFMMinimapButton", "AtlasCFMLootTooltip", "AtlasCFMProfessionTab",
	"AtlasCFMTooltipIcon",
	--The "report it at" URL box. Skinning it moves the box out from under its own label
	--and the two overlap.
	"AtlasCFMNoticeBox"
}

--Walked for anonymous children. NOT the same list as `windows`, and the difference
--matters: AtlasCFMFrame holds the map, which is a BACKGROUND texture on the frame
--itself, so anything given a backdrop inside it draws over the map and dims it.
--AtlasCFMButtonFrame is parented to Minimap and is the minimap button holder, not a
--bottom bar. Both get the window backdrop above; neither gets walked.
local walkTargets = {
	"AtlasCFMLootPanel",
	"AtlasCFMLootItemsFrame",
	"AtlasCFMOptionsFrame"
}

local function Skippable(name)
	if not name then return false end

	for i = 1, getn(skipNames) do
		if find(name, skipNames[i], 1, true) then return true end
	end

	return false
end

local function SkinChildren(parent, depth)
	if not (parent and parent.GetChildren) then return end

	local children = {parent:GetChildren()}
	for i = 1, getn(children) do
		local child = children[i]

		if child and child.GetObjectType then
			local name = child.GetName and child:GetName()

			if not Skippable(name) then
				local kind = child:GetObjectType()

				--Each on its own pcall for the same reason as Apply: one widget that
				--cannot take a skin must not cost every widget after it.
				if kind == "Button" then
					pcall(SkinButton, child)
				elseif kind == "EditBox" then
					pcall(S.HandleEditBox, S, child)
				elseif kind == "CheckButton" then
					pcall(S.HandleCheckBox, S, child)
				elseif kind == "Slider" then
					pcall(S.HandleSliderFrame, S, child)
				end

				if depth > 0 then
					SkinChildren(child, depth - 1)
				end
			end
		end
	end
end

--Rows are created as loot tables are browsed, so this has to run again on show rather
--than once at load. Only the icon is touched: as with AtlasLoot, S:HandleItemButton
--looks for `<name>IconTexture` or `<name>Icon` and would find neither, stripping the
--row and leaving nothing behind.
local function SkinRows(prefix, suffix)
	local i = 1
	while true do
		local frame = _G[prefix..i..(suffix or "")]
		if not frame then break end

		if frame.SetTexCoord then
			frame:SetTexCoord(unpack(E.TexCoords))
		end

		i = i + 1
		if i > 100 then break end --never loop forever on a live client
	end
end

local function SkinDynamic()
	Apply(windows, function(frame)
		if frame:GetObjectType() ~= "Frame" or frame.template then return end

		E:StripTextures(frame)
		E:SetTemplate(frame, "Transparent")
	end)

	Apply(closeButtons, function(frame) S:HandleCloseButton(frame) end)
	Apply(buttons, SkinButton)

	SkinRows("AtlasCFMLootItem", "_Icon")
	SkinRows("AtlasCFMLootMenuItem", "_Icon")
	SkinRows("AtlasCFMLootContainerItem", "_Icon")

	--Two levels: the bottom bar's buttons sit inside a bar frame, and the search cluster
	--sits inside the search box. Deeper than that reaches item rows and artwork, which
	--are excluded by name anyway but cost time to walk.
	for i = 1, getn(walkTargets) do
		SkinChildren(_G[walkTargets[i]], 2)
	end
end

local function LoadSkin()
	--The window edges are art, not containers, so they are stripped rather than given
	--a template of their own -- the body below carries the backdrop for all of them.
	Apply(edges, function(frame) E:StripTextures(frame) end)

	SkinDynamic()

	Apply(editBoxes, function(frame) S:HandleEditBox(frame) end)
	Apply(checkBoxes, function(frame) S:HandleCheckBox(frame) end)
	Apply(sliders, function(frame) S:HandleSliderFrame(frame) end)

	local main = _G["AtlasCFMFrame"]
	if main then
		HookScript(main, "OnShow", SkinDynamic)
	end

	--Said once, not per widget. Without it a widget that cannot be skinned is invisible
	--as a cause: it simply looks like the skin does not cover that part of the window.
	if failures then
		E:Print("|cffff9900Atlas-CFM skin|r could not skin: "..failures)
		failures = nil
	end
end

S:AddCallbackForAddon("Atlas-CFM", "SkinAtlasCFM", LoadSkin)
