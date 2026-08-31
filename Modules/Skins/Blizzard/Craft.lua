local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack
local tostring = tostring
local find, match, format = string.find, string.match, string.format
local tinsert, getn, sort = table.insert, table.getn, table.sort
--WoW API / Variables
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetItemInfo = GetItemInfo
local GetItemQualityColor = GetItemQualityColor
local GetCraftItemLink = GetCraftItemLink
local GetCraftReagentInfo = GetCraftReagentInfo
local GetCraftReagentItemLink = GetCraftReagentItemLink
local hooksecurefunc = hooksecurefunc

local function LoadSkin()
	if E.private.skins.blizzard.enable ~= true or not E.private.skins.blizzard.craft ~= true then return end

	CRAFTS_DISPLAYED = 25

	UIPanelWindows["CraftFrame"] = {area = "doublewide", pushable = 0, whileDead = 1}

	E:StripTextures(CraftFrame, true)
	E:CreateBackdrop(CraftFrame, "Transparent")
	CraftFrame.backdrop:SetPoint("TOPLEFT", 10, -12)
	CraftFrame.backdrop:SetPoint("BOTTOMRIGHT", -34, 0)
	E:Size(CraftFrame, 720, 508)

	CraftFrame.bg1 = CreateFrame("Frame", nil, CraftFrame)
	E:SetTemplate(CraftFrame.bg1, "Transparent")
	CraftFrame.bg1:SetPoint("TOPLEFT", 14, -92)
	CraftFrame.bg1:SetPoint("BOTTOMRIGHT", -367, 4)
	CraftFrame.bg1:SetFrameLevel(CraftFrame.bg1:GetFrameLevel() - 1)

	CraftFrame.bg2 = CreateFrame("Frame", nil, CraftFrame)
	E:SetTemplate(CraftFrame.bg2, "Transparent")
	CraftFrame.bg2:SetPoint("TOPLEFT", CraftFrame.bg1, "TOPRIGHT", 3, 0)
	CraftFrame.bg2:SetPoint("BOTTOMRIGHT", CraftFrame, "BOTTOMRIGHT", -38, 4)
	CraftFrame.bg2:SetFrameLevel(CraftFrame.bg2:GetFrameLevel() - 1)

	E:StripTextures(CraftRankFrameBorder)

	E:StripTextures(CraftRankFrame)
	E:CreateBackdrop(CraftRankFrame)
	E:Size(CraftRankFrame, 420, 18)
	CraftRankFrame:ClearAllPoints()
	CraftRankFrame:SetPoint("TOP", -10, -38)
	CraftRankFrame:SetStatusBarTexture(E.media.normTex)
	E:RegisterStatusBar(CraftRankFrame)

	CraftRankFrameSkillName:Hide()
	CraftRankFrameSkillRank:ClearAllPoints()
	CraftRankFrameSkillRank:SetParent(CraftRankFrame)
	CraftRankFrameSkillRank:SetPoint("CENTER", CraftRankFrame, "CENTER", 58, 0)

	E:StripTextures(CraftListScrollFrame)
	E:Size(CraftListScrollFrame, 310, 405)
	CraftListScrollFrame:ClearAllPoints()
	CraftListScrollFrame:SetPoint("TOPLEFT", 17, -95)

	E:StripTextures(CraftDetailScrollFrame)
	E:Size(CraftDetailScrollFrame, 300, 381)
	CraftDetailScrollFrame:ClearAllPoints()
	CraftDetailScrollFrame:SetPoint("TOPRIGHT", CraftFrame, -60, -95)

	E:StripTextures(CraftDetailScrollChildFrame)
	E:Size(CraftDetailScrollChildFrame, 300, 150)

	S:HandleScrollBar(CraftListScrollFrameScrollBar)
	S:HandleScrollBar(CraftDetailScrollFrameScrollBar)

	CraftCancelButton:ClearAllPoints()
	CraftCancelButton:SetPoint("TOPRIGHT", CraftDetailScrollFrame, "BOTTOMRIGHT", 19, -3)
	S:HandleButton(CraftCancelButton)

	CraftCreateButton:ClearAllPoints()
	CraftCreateButton:SetPoint("TOPRIGHT", CraftCancelButton, "TOPLEFT", -3, 0)
	S:HandleButton(CraftCreateButton)

	E:StripTextures(CraftIcon)
	E:SetTemplate(CraftIcon, "Default")
	E:StyleButton(CraftIcon, nil, true)
	E:Size(CraftIcon, 47)
	CraftIcon:SetPoint("TOPLEFT", 1, -3)

	CraftName:SetPoint("TOPLEFT", 55, -3)

	CraftRequirements:SetTextColor(1, 0.80, 0.10)

	S:HandleCloseButton(CraftFrameCloseButton, CraftFrame.backdrop)

	E:StripTextures(CraftExpandButtonFrame)

	--Same treatment as the TradeSkill window -- see the note there for why the header row
	--and not under the list. The name is NOT confirmed here the way TradeSkillSearchBox
	--was: that one was read off GetMouseFocus in game, this is the symmetric guess plus
	--the two names Atlas-OctoUI probes for in ProfessionHooks.lua:1308. If Enchanting
	--still shows a floating search box, none of these matched and the real name wants
	--reading with GetMouseFocus on its clear button.
	local SEARCH_WIDTH, SEARCH_GAP = 150, 8
	local craftSearchBox = _G["CraftSearchBox"] or _G["CraftFrameSearchBox"] or _G["CraftFrameEditBox"]
	if craftSearchBox then
		CraftRankFrame:ClearAllPoints()
		CraftRankFrame:SetPoint("TOP", ((SEARCH_WIDTH + SEARCH_GAP) / 2) - 10, -38)

		craftSearchBox:ClearAllPoints()
		craftSearchBox:SetWidth(SEARCH_WIDTH)
		craftSearchBox:SetPoint("TOPRIGHT", CraftRankFrame, "TOPLEFT", -SEARCH_GAP, 0)
		craftSearchBox:SetPoint("BOTTOMRIGHT", CraftRankFrame, "BOTTOMLEFT", -SEARCH_GAP, 0)

		if S.HandleEditBox then S:HandleEditBox(craftSearchBox) end

		--[[
			BREAK THE LIST DOWN BY SLOT.

			Enchanting is a Craft, not a TradeSkill, and the Craft API has no equivalent of
			TradeSkillInvSlotDropDown -- so where a blacksmith can narrow to Bracers, an
			enchanter gets one flat list of everything they know. At 300 skill that is
			around a hundred rows, and the only way to find "the bracer enchants" is to
			read all of them.

			THE SLOTS ARE DERIVED FROM THE RECIPE NAMES, not from a table. A table would go
			stale the moment this server adds an enchant, and it already carries entries a
			table would not predict. Every enchant here is named "Enchant <slot> - <effect>",
			so the slot is the text between the two; anything not of that shape (Runed
			Arcanite Rod, Smoking Heart of the Mountain) is simply never offered as a slot,
			which is correct rather than a gap.

			THE FILTERING IS THE CLIENT'S OWN SEARCH BOX, driven rather than reimplemented.
			Re-ordering or hiding the craft buttons would mean maintaining a display-index
			to craft-index map, and CraftFrame_SetSelection and DoCraft both take that
			index -- getting it wrong enchants the wrong thing with someone's materials.
			Setting the text the box already filters on cannot have that failure.
		]]
		local SLOT_WIDTH = 104

		--Room for the new control. The header row is search + skill bar; without this the
		--three of them together are wider than the frame's usable width.
		E:Size(CraftRankFrame, 340, 18)
		CraftRankFrame:ClearAllPoints()
		CraftRankFrame:SetPoint("TOP",
			((SEARCH_WIDTH + SEARCH_GAP + SLOT_WIDTH + SEARCH_GAP) / 2) - 10, -38)

		local slotMenu = CreateFrame("Frame", "OctoUI_CraftSlotMenu", E.UIParent)
		E:SetTemplate(slotMenu, "Transparent")
		slotMenu:Hide()

		local slotButton = CreateFrame("Button", "OctoUI_CraftSlotButton", CraftFrame)
		E:SetTemplate(slotButton, "Transparent")
		E:Width(slotButton, SLOT_WIDTH)
		E:Point(slotButton, "TOPRIGHT", craftSearchBox, "TOPLEFT", -SEARCH_GAP, 0)
		E:Point(slotButton, "BOTTOMRIGHT", craftSearchBox, "BOTTOMLEFT", -SEARCH_GAP, 0)

		slotButton.text = slotButton:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(slotButton.text, nil, 11, "NONE")
		slotButton.text:SetAllPoints()
		slotButton:SetScript("OnEnter", function() this:SetBackdropBorderColor(1, 1, 1) end)
		slotButton:SetScript("OnLeave", function() E:SetTemplate(this, "Transparent") end)

		local function SetLabel(slot)
			if slot then
				slotButton.text:SetText(slot)
				slotButton.text:SetTextColor(unpack(E.media.rgbvaluecolor))
			else
				slotButton.text:SetText(L["All Slots"])
				slotButton.text:SetTextColor(0.7, 0.7, 0.7)
			end
		end
		SetLabel(nil)

		--Read fresh every time the menu opens. The craft list only exists while the window
		--is open, and a recipe learned this session should appear without a reload.
		--[[
			Read out of _G at call time, never cached at file scope.

			Blizzard_CraftUI is load on demand, and this file runs during addon load. A
			`local GetNumCrafts = GetNumCrafts` at the top of the file therefore captures
			whatever the name meant BEFORE the craft UI existed, and keeps it forever --
			the same trap Modules/Auction documents against AuctionFrame. Cheap to avoid
			and impossible to notice once it bites, because the loop simply never runs.
		]]
		local function SlotList()
			local seen, slots = {}, {}
			local numCrafts = _G["GetNumCrafts"]
			local craftInfo = _G["GetCraftInfo"]
			if not (numCrafts and craftInfo) then return slots end

			for i = 1, (numCrafts() or 0) do
				local name = craftInfo(i)
				if name then
					local slot = match(name, "^Enchant%s+(.-)%s+%-")
					if slot and slot ~= "" and not seen[slot] then
						seen[slot] = true
						tinsert(slots, slot)
					end
				end
			end

			sort(slots)
			return slots
		end

		--[[
			WHAT THIS CONTROL ACTUALLY SEES, printed by /octoui-craft.

			The filter has two halves that fail identically from the outside: the menu can
			come up empty because the craft list was not readable, or it can come up
			correct and the search box can decline to filter on it. Both look like
			"nothing happened", and guessing between them has already cost a round trip.
		]]
		function S:CraftSlotReport()
			local numCrafts = _G["GetNumCrafts"]
			local craftInfo = _G["GetCraftInfo"]

			E:Print(format("GetNumCrafts=%s GetCraftInfo=%s",
				tostring(numCrafts ~= nil), tostring(craftInfo ~= nil)))

			if not (numCrafts and craftInfo) then
				E:Print("The craft API is not readable - open the Enchanting window first.")
				return
			end

			local total = numCrafts() or 0
			E:Print(format("crafts listed: %d", total))

			for i = 1, (total > 3 and 3 or total) do
				local name, _, craftType = craftInfo(i)
				E:Print(format("  %d. %s  (%s)", i, tostring(name), tostring(craftType)))
			end

			local slots = SlotList()
			E:Print(format("slots derived: %d", getn(slots)))
			for i = 1, getn(slots) do
				E:Print("  "..slots[i])
			end

			--Which widget the skin found, what is in it, and whether anything is listening
			--to it. A box with no OnTextChanged cannot be what filters the list.
			local boxName = "none"
			if _G["CraftSearchBox"] then boxName = "CraftSearchBox"
			elseif _G["CraftFrameSearchBox"] then boxName = "CraftFrameSearchBox"
			elseif _G["CraftFrameEditBox"] then boxName = "CraftFrameEditBox" end

			--Whether E:DropDown ever built the menu. Zero buttons means the left-click path
			--never ran or never got as far as filling it, which is a different fault from
			--the filter declining the text.
			local menu = _G["OctoUI_CraftSlotMenu"]
			if menu then
				E:Print(format("menu: built=%s shown=%s entries=%d",
					tostring(menu.buttons ~= nil), tostring(menu:IsShown() and true or false),
					menu.buttons and getn(menu.buttons) or 0))
			else
				E:Print("menu: not created")
			end

			E:Print(format("search box: %s", boxName))
			if craftSearchBox then
				E:Print(format("  text now: '%s'", tostring(craftSearchBox:GetText())))
				E:Print(format("  OnTextChanged=%s OnEnterPressed=%s",
					tostring(craftSearchBox:GetScript("OnTextChanged") ~= nil),
					tostring(craftSearchBox:GetScript("OnEnterPressed") ~= nil)))
			end
		end

		--SetText fires OnTextChanged on this client, which is what the client's own filter
		--hangs off, so setting the text IS applying the filter.
		--[[
			SetText alone is an assumption. It does fire OnTextChanged on this client, but
			only if that is where the client hangs its filtering -- a search box that
			filters on Enter, or through a separate handler, would take the text and do
			nothing with it, which is indistinguishable from the menu being broken.

			So drive both scripts the box declares. `this` is how a handler on this client
			reads the widget it fired on, so it has to be set around the call; it is a
			plain global and is restored immediately.
		]]
		local function Fire(script)
			local handler = craftSearchBox:GetScript(script)
			if not handler then return end

			local previous = this
			this = craftSearchBox
			pcall(handler)
			this = previous
		end

		local function Apply(slot)
			SetLabel(slot)
			craftSearchBox:SetText(slot or "")
			Fire("OnTextChanged")
			Fire("OnEnterPressed")
			craftSearchBox:ClearFocus()
		end

		--A function call per entry rather than a closure written inside the loop: a
		--closure made in a loop has been measured on this client reading the loop's own
		--variable as nil when it later runs.
		local function SlotEntry(label, value)
			return {text = label, func = function() Apply(value) end}
		end

		--[[
			TWO WAYS IN, and the second one is not a convenience.

			Left click opens the menu. Right click steps to the next slot directly, with no
			menu involved at all -- and that matters because E:DropDown is shared code whose
			only other user in this addon is a menu nobody had confirmed working either. If
			the menu turns out not to open on this client, right click still delivers the
			whole feature, and the difference between the two says exactly where the fault
			is without another round trip.

			The button reports its own state: the label changes the instant a slot is
			applied, so a click that lands is visible whether or not the list moves.
		]]
		slotButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		--Where the cycle currently sits. Zero is "All Slots", which is why it is an index
		--into the list plus one rather than a slot name.
		local cycleIndex = 0

		slotButton:SetScript("OnClick", function()
			local slots = SlotList()

			if arg1 == "RightButton" then
				cycleIndex = cycleIndex + 1
				if cycleIndex > getn(slots) then cycleIndex = 0 end

				Apply(cycleIndex > 0 and slots[cycleIndex] or nil)
				return
			end

			local list = {SlotEntry(L["All Slots"], nil)}
			for i = 1, getn(slots) do
				tinsert(list, SlotEntry(slots[i], slots[i]))
			end

			if slotMenu:IsShown() then slotMenu:Hide() end
			E:DropDown(list, slotMenu, 0, 0)
		end)

		slotButton:SetScript("OnEnter", function()
			this:SetBackdropBorderColor(1, 1, 1)
			GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
			GameTooltip:AddLine(L["All Slots"])
			GameTooltip:AddLine(L["CRAFT_SLOT_TIP"], 1, 1, 1, 1)
			GameTooltip:Show()
		end)
		slotButton:SetScript("OnLeave", function()
			E:SetTemplate(this, "Transparent")
			GameTooltip:Hide()
		end)
	end

	CraftCollapseAllButton:SetPoint("LEFT", CraftExpandTabLeft, "RIGHT", -8, 5)
	CraftCollapseAllButton:SetNormalTexture("Interface\\AddOns\\OctoUI\\media\\textures\\PlusMinusButton")
	CraftCollapseAllButton.SetNormalTexture = E.noop
	CraftCollapseAllButton:GetNormalTexture():SetPoint("LEFT", 3, 2)
	E:Size(CraftCollapseAllButton:GetNormalTexture(), 15)

	CraftCollapseAllButton:SetHighlightTexture("")
	CraftCollapseAllButton.SetHighlightTexture = E.noop

	CraftCollapseAllButton:SetDisabledTexture("Interface\\AddOns\\OctoUI\\media\\textures\\PlusMinusButton")
	CraftCollapseAllButton.SetDisabledTexture = E.noop
	CraftCollapseAllButton:GetDisabledTexture():SetPoint("LEFT", 3, 2)
	E:Size(CraftCollapseAllButton:GetDisabledTexture(), 15)
	CraftCollapseAllButton:GetDisabledTexture():SetTexCoord(0.045, 0.475, 0.085, 0.925)
	CraftCollapseAllButton:GetDisabledTexture():SetDesaturated(true)

	hooksecurefunc(CraftCollapseAllButton, "SetNormalTexture", function(self, texture)
		if find(texture, "MinusButton") then
			self:GetNormalTexture():SetTexCoord(0.545, 0.975, 0.085, 0.925)
		else
			self:GetNormalTexture():SetTexCoord(0.045, 0.475, 0.085, 0.925)
		end
	end)

	--Only create what the client has not already made -- see the long note on the same
	--loop in Modules/Skins/Blizzard/TradeSkill.lua. CreateFrame with a name that is
	--already taken silently makes a second frame and rebinds the global, orphaning the
	--client's original as a permanently-shown button nothing can reach by name.
	local previous = Craft8
	for i = 9, 25 do
		local button = _G["Craft"..i]
		if not button then
			button = CreateFrame("Button", "Craft"..i, CraftFrame, "CraftButtonTemplate")
			button:SetPoint("TOPLEFT", previous, "BOTTOMLEFT")
		end
		previous = button
	end

	for i = 1, CRAFTS_DISPLAYED do
		local button = _G["Craft"..i]
		local highlight = _G["Craft"..i.."Highlight"]

		button:SetNormalTexture("Interface\\AddOns\\OctoUI\\media\\textures\\PlusMinusButton")
		button.SetNormalTexture = E.noop
		E:Size(button:GetNormalTexture(), 14)
		button:GetNormalTexture():SetPoint("LEFT", 4, 1)

		highlight:SetTexture("")
		highlight.SetTexture = E.noop

		hooksecurefunc(button, "SetNormalTexture", function(self, texture)
			if find(texture, "MinusButton") then
				self:GetNormalTexture():SetTexCoord(0.545, 0.975, 0.085, 0.925)
			elseif find(texture, "PlusButton") then
				self:GetNormalTexture():SetTexCoord(0.045, 0.475, 0.085, 0.925)
			else
				self:GetNormalTexture():SetTexCoord(0, 0, 0, 0)
			end
		end)
	end

	for i = 1, MAX_CRAFT_REAGENTS do
		local reagent = _G["CraftReagent"..i]
		local icon = _G["CraftReagent"..i.."IconTexture"]
		local count = _G["CraftReagent"..i.."Count"]
		local name = _G["CraftReagent"..i.."Name"]
		local nameFrame = _G["CraftReagent"..i.."NameFrame"]

		E:SetTemplate(reagent, "Default")
		E:StyleButton(reagent, nil, true)
		E:Size(reagent, 143, 40)

		icon.backdrop = CreateFrame("Frame", nil, reagent)
		E:SetTemplate(icon.backdrop, "Default")
		icon.backdrop:SetPoint("TOPLEFT", icon, -1, 1)
		icon.backdrop:SetPoint("BOTTOMRIGHT", icon, 1, -1)

		icon:SetTexCoord(unpack(E.TexCoords))
		icon:SetDrawLayer("OVERLAY")
		E:Size(icon, E.PixelMode and 38 or 32)
		icon:SetPoint("TOPLEFT", E.PixelMode and 1 or 4, -(E.PixelMode and 1 or 4))
		icon:SetParent(icon.backdrop)

		count:SetParent(icon.backdrop)
		count:SetDrawLayer("OVERLAY")

		name:SetPoint("LEFT", nameFrame, "LEFT", 20, 0)

		E:Kill(nameFrame)
	end

	CraftReagent1:SetPoint("TOPLEFT", CraftReagentLabel, "BOTTOMLEFT", -3, -3)
	CraftReagent2:SetPoint("LEFT", CraftReagent1, "RIGHT", 3, 0)
	CraftReagent4:SetPoint("LEFT", CraftReagent3, "RIGHT", 3, 0)
	CraftReagent6:SetPoint("LEFT", CraftReagent5, "RIGHT", 3, 0)
	CraftReagent8:SetPoint("LEFT", CraftReagent7, "RIGHT", 3, 0)

	hooksecurefunc("CraftFrame_Update", function()
		CraftRankFrame:SetStatusBarColor(0.13, 0.28, 0.85)
	end)

	hooksecurefunc("CraftFrame_SetSelection", function(id)
		CraftReagentLabel:SetPoint("TOPLEFT", CraftDescription, "BOTTOMLEFT", 0, -10)

		if CraftIcon:GetNormalTexture() then
			CraftReagentLabel:SetAlpha(1)
			CraftIcon:SetAlpha(1)
			CraftIcon:GetNormalTexture():SetTexCoord(unpack(E.TexCoords))
			E:SetInside(CraftIcon:GetNormalTexture())
		else
			CraftReagentLabel:SetAlpha(0)
			CraftIcon:SetAlpha(0)
		end

		local skillLink = GetCraftItemLink(id)
		if skillLink then
			local _, _, quality = GetItemInfo(match(skillLink, "enchant:(%d+)"))
			if quality then
				CraftIcon:SetBackdropBorderColor(GetItemQualityColor(quality))
				CraftName:SetTextColor(GetItemQualityColor(quality))
			else
				CraftIcon:SetBackdropBorderColor(unpack(E.media.bordercolor))
				CraftName:SetTextColor(1, 1, 1)
			end
		end

		local numReagents = GetCraftNumReagents(id)
		for i = 1, numReagents, 1 do
			local _, _, reagentCount, playerReagentCount = GetCraftReagentInfo(id, i)
			local reagentLink = GetCraftReagentItemLink(id, i)
			local reagent = _G["CraftReagent"..i]
			local icon = _G["CraftReagent"..i.."IconTexture"]
			local name = _G["CraftReagent"..i.."Name"]

			if reagentLink then
				local _, _, quality = GetItemInfo(match(reagentLink, "item:(%d+)"))
				if quality then
					icon.backdrop:SetBackdropBorderColor(GetItemQualityColor(quality))
					reagent:SetBackdropBorderColor(GetItemQualityColor(quality))
					if playerReagentCount < reagentCount then
						name:SetTextColor(0.5, 0.5, 0.5)
					else
						name:SetTextColor(GetItemQualityColor(quality))
					end
				else
					reagent:SetBackdropBorderColor(unpack(E.media.bordercolor))
					icon.backdrop:SetBackdropBorderColor(unpack(E.media.bordercolor))
				end
			end
		end
	end)
end

S:AddCallbackForAddon("Blizzard_CraftUI", "Craft", LoadSkin)