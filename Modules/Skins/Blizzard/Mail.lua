local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local ipairs, unpack = ipairs, unpack
local getn = table.getn
--WoW API / Variables
local GetInboxHeaderInfo = GetInboxHeaderInfo
local GetInboxItem = GetInboxItem
local GetInboxNumItems = GetInboxNumItems
local GetItemInfoByName = GetItemInfoByName
local GetItemQualityColor = GetItemQualityColor
local GetSendMailItem = GetSendMailItem
local hooksecurefunc = hooksecurefunc

local INBOXITEMS_TO_DISPLAY = INBOXITEMS_TO_DISPLAY

--Where the skinned backdrop sits inside MailFrame. Named because the asymmetry between
--them -- 10 in on the left, 30 on the right -- is what makes MailFrame's own centre useless
--as a reference for anything meant to look centred on the panel. The title below and
--Modules/Misc/MailTools.lua both lost rounds to it. Nothing derives a constant from these
--any more; both now centre on the backdrop object itself, which cannot drift out of step
--with them.
local BACKDROP_LEFT, BACKDROP_RIGHT = 10, -30

local function LoadSkin()
	if E.private.skins.blizzard.enable ~= true or E.private.skins.blizzard.mail ~= true then return end

	-- Inbox Frame
	E:StripTextures(MailFrame, true)
	E:CreateBackdrop(MailFrame, "Transparent")
	E:Point(MailFrame.backdrop, "TOPLEFT", BACKDROP_LEFT, -12)
	E:Point(MailFrame.backdrop, "BOTTOMRIGHT", BACKDROP_RIGHT, 74)

	--The title reads right of centre because the backdrop is inset 10 on the left and 30 on
	--the right, so the panel the player sees is centred 10px left of MailFrame itself --
	--and once E:StripTextures has taken the frame's own artwork away, that backdrop is the
	--only thing there is to look centred against.
	--
	--MEASURED with `/oprobe kids MailFrame` after two failed attempts at this:
	--**MailFrame has no font string regions at all.** Its regions are five textures, all
	--hidden by the strip above, plus the mail icon. `MailFrameTitleText` is not on it and
	--neither is anything else -- the title belongs to a CHILD, `InboxFrame`, which the same
	--listing shows is 384x512 at +0,+0. A walk over MailFrame:GetRegions() therefore found
	--nothing and returned silently, which looked exactly like the fix not working.
	--
	--"Topmost visible font string with text" was tried and it is WRONG: it grabbed the close
	--button's "x". `InboxCloseButton` sits at +323,-9, higher than the title, and
	--S:HandleCloseButton gives that button a font string of its own -- so the search found
	--it first and centred the x on the panel. A heuristic that walks everything will find
	--whatever is nearest the top, and on a skinned frame that is rarely the title.
	--
	--So the search is restricted to the two TAB PANES and to their OWN regions. The title
	--belongs to a pane; it is not on MailFrame (measured: no font strings at all), it is not
	--on a button, and it is not on a letter row. Walking exactly those two frames' regions
	--cannot reach the close button, the tabs, the Take All button or the mail rows, because
	--none of them are regions of either pane.
	local TITLE_PANES = {"InboxFrame", "SendMailFrame"}

	local function FindTitle()
		local best

		for i = 1, getn(TITLE_PANES) do
			local pane = _G[TITLE_PANES[i]]
			--Only the tab actually up. The hidden one has no rect and its title would
			--otherwise compete with the one being looked at.
			if pane and pane.IsVisible and pane:IsVisible() then
				local regions = {pane:GetRegions()}
				for r = 1, getn(regions) do
					local region = regions[r]
					if region and region.GetObjectType and region:GetObjectType() == "FontString"
						and region:IsVisible() then
						local text = region:GetText()
						local top = region:GetTop()
						if text and text ~= "" and top and (not best or top > best:GetTop()) then
							best = region
						end
					end
				end
			end
		end

		return best
	end

	--Centred on the backdrop rather than nudged by a derived constant, and the vertical is
	--carried across measured so it does not move a pixel. GetCenter answers screen
	--coordinates for both, so the two are in the same space -- mixing GetCenter with
	--GetWidth is how the numbers stopped adding up the first time round.
	--
	--Idempotent: only x changes, so a re-run measures the same y and lands in the same
	--place. Re-applied on OnShow because the tabs swap which title is showing.
	local function FixTitlePosition()
		local backdrop = MailFrame.backdrop
		if not backdrop then return end

		local title = FindTitle()
		if not title then return end

		local _, titleY = title:GetCenter()
		local backdropX, backdropY = backdrop:GetCenter()
		if not (titleY and backdropX and backdropY) then return end

		title:ClearAllPoints()
		title:SetPoint("CENTER", backdrop, "CENTER", 0, titleY - backdropY)
	end

	FixTitlePosition()
	HookScript(MailFrame, "OnShow", FixTitlePosition)

	MailFrame:EnableMouseWheel(true)
	MailFrame:SetScript("OnMouseWheel", function()
		if arg1 > 0 then
			if InboxPrevPageButton:IsEnabled() == 1 then
				InboxPrevPage()
			end
		else
			if InboxNextPageButton:IsEnabled() == 1 then
				InboxNextPage()
			end
		end
	end)

	for i = 1, INBOXITEMS_TO_DISPLAY do
		local mail = _G["MailItem"..i]
		local button = _G["MailItem"..i.."Button"]
		local icon = _G["MailItem"..i.."ButtonIcon"]

		E:StripTextures(mail)
		E:CreateBackdrop(mail, "Default")
		E:Point(mail.backdrop, "TOPLEFT", 2, 1)
		E:Point(mail.backdrop, "BOTTOMRIGHT", -2, 2)

		E:StripTextures(button)
		E:SetTemplate(button, "Default", true)
		E:StyleButton(button)

		icon:SetTexCoord(unpack(E.TexCoords))
		E:SetInside(icon)
	end

	hooksecurefunc("InboxFrame_Update", function()
		local numItems = GetInboxNumItems()
		local index = ((InboxFrame.pageNum - 1) * INBOXITEMS_TO_DISPLAY) + 1

		for i = 1, INBOXITEMS_TO_DISPLAY do
			if index <= numItems then
				local packageIcon, _, _, _, _, _, _, _, _, _, _, _, isGM = GetInboxHeaderInfo(index)
				local button = _G["MailItem"..i.."Button"]

				if packageIcon and not isGM then
					local itemName = GetInboxItem(index)
					if itemName then
						local _, _, quality = GetItemInfoByName(itemName)

						if quality then
							button:SetBackdropBorderColor(GetItemQualityColor(quality))
						else
							button:SetBackdropBorderColor(unpack(E.media.bordercolor))
						end
					end
				elseif isGM then
					button:SetBackdropBorderColor(0, 0.56, 0.94)
				else
					button:SetBackdropBorderColor(unpack(E.media.bordercolor))
				end
			end

			index = index + 1
		end
	end)

	S:HandleNextPrevButton(InboxPrevPageButton)
	E:Point(InboxPrevPageButton, "CENTER", InboxFrame, "BOTTOMLEFT", 42, 104)

	S:HandleNextPrevButton(InboxNextPageButton)
	E:Point(InboxNextPageButton, "CENTER", InboxFrame, "BOTTOMLEFT", 318, 104)

	S:HandleCloseButton(InboxCloseButton)

	for i = 1, 2 do
		local tab = _G["MailFrameTab"..i]

		E:StripTextures(tab)
		S:HandleTab(tab)
	end

	-- Send Mail Frame
	E:StripTextures(SendMailFrame)

	E:StripTextures(SendMailScrollFrame, true)
	E:SetTemplate(SendMailScrollFrame, "Default")

	E:StripTextures(SendMailPackageButton)
	E:SetTemplate(SendMailPackageButton, "Default", true)
	E:StyleButton(SendMailPackageButton, nil, true)

	hooksecurefunc("SendMailFrame_Update", function()
		local button = SendMailPackageButton
		local texture = button:GetNormalTexture()
		local itemName = GetSendMailItem()

		if itemName then
			local _, _, quality = GetItemInfoByName(itemName)

			if quality then
				button:SetBackdropBorderColor(GetItemQualityColor(quality))
			else
				button:SetBackdropBorderColor(unpack(E.media.bordercolor))
			end
			texture:SetTexCoord(unpack(E.TexCoords))
			E:SetInside(texture)
		else
			button:SetBackdropBorderColor(unpack(E.media.bordercolor))
		end
	end)

	SendMailBodyEditBox:SetTextColor(1, 1, 1)

	S:HandleScrollBar(SendMailScrollFrameScrollBar)

	S:HandleEditBox(SendMailNameEditBox)
	E:Point(SendMailNameEditBox.backdrop, "BOTTOMRIGHT", 2, 0)
	E:Point(SendMailNameEditBox, "TOPLEFT", 79, -46)

	S:HandleEditBox(SendMailSubjectEditBox)
	E:Point(SendMailSubjectEditBox.backdrop, "BOTTOMRIGHT", 2, 0)

	S:HandleEditBox(SendMailMoneyGold)
	S:HandleEditBox(SendMailMoneySilver)
	S:HandleEditBox(SendMailMoneyCopper)

	S:HandleButton(SendMailMailButton)
	E:Point(SendMailMailButton, "RIGHT", SendMailCancelButton, "LEFT", -2, 0)

	S:HandleButton(SendMailCancelButton)
	E:Point(SendMailCancelButton, "BOTTOMRIGHT", -45, 80)

	E:Point(SendMailMoneyFrame, "BOTTOMLEFT", 170, 84)

	-- Open Mail Frame
	E:StripTextures(OpenMailFrame, true)
	E:CreateBackdrop(OpenMailFrame, "Transparent")
	E:Point(OpenMailFrame.backdrop, "TOPLEFT", 12, -12)
	E:Point(OpenMailFrame.backdrop, "BOTTOMRIGHT", -34, 74)

	E:StripTextures(OpenMailPackageButton)
	E:StyleButton(OpenMailPackageButton)
	E:SetTemplate(OpenMailPackageButton, "Default", true)

	for _, region in ipairs({OpenMailPackageButton:GetRegions()}) do
		if region:GetObjectType() == "Texture" then
			region:SetTexCoord(unpack(E.TexCoords))
			E:SetInside(region)
		end
	end

	hooksecurefunc("OpenMail_Update", function()
		local index = InboxFrame.openMailID
		if not index then return end

		local _, _, _, _, _, _, _, hasItem = GetInboxHeaderInfo(index)

		if hasItem then
			local button = OpenMailPackageButton
			local texture = button:GetNormalTexture()
			local itemName = GetInboxItem(index)

			if itemName then
				local _, _, quality = GetItemInfoByName(itemName)

				if quality then
					button:SetBackdropBorderColor(GetItemQualityColor(quality))
				else
					button:SetBackdropBorderColor(unpack(E.media.bordercolor))
				end
				texture:SetTexCoord(unpack(E.TexCoords))
				E:SetInside(texture)
			else
				button:SetBackdropBorderColor(unpack(E.media.bordercolor))
			end
		end
	end)

	S:HandleCloseButton(OpenMailCloseButton)

	S:HandleButton(OpenMailReplyButton)
	E:Point(OpenMailReplyButton, "RIGHT", OpenMailDeleteButton, "LEFT", -2, 0)

	S:HandleButton(OpenMailDeleteButton)
	E:Point(OpenMailDeleteButton, "RIGHT", OpenMailCancelButton, "LEFT", -2, 0)

	S:HandleButton(OpenMailCancelButton)

	E:StripTextures(OpenMailScrollFrame, true)
	E:SetTemplate(OpenMailScrollFrame, "Default")

	S:HandleScrollBar(OpenMailScrollFrameScrollBar)

	OpenMailBodyText:SetTextColor(1, 1, 1)
	InvoiceTextFontNormal:SetTextColor(1, 1, 1)
	OpenMailInvoiceBuyMode:SetTextColor(1, 0.80, 0.10)

	E:Kill(OpenMailArithmeticLine)

	E:StripTextures(OpenMailLetterButton)
	E:SetTemplate(OpenMailLetterButton, "Default", true)
	E:StyleButton(OpenMailLetterButton)

	OpenMailLetterButtonIconTexture:SetTexCoord(unpack(E.TexCoords))
	OpenMailLetterButtonIconTexture:SetDrawLayer("ARTWORK")
	E:SetInside(OpenMailLetterButtonIconTexture)

	OpenMailLetterButtonCount:SetDrawLayer("OVERLAY")

	E:StripTextures(OpenMailMoneyButton)
	E:SetTemplate(OpenMailMoneyButton, "Default", true)
	E:StyleButton(OpenMailMoneyButton)

	OpenMailMoneyButtonIconTexture:SetTexCoord(unpack(E.TexCoords))
	OpenMailMoneyButtonIconTexture:SetDrawLayer("ARTWORK")
	E:SetInside(OpenMailMoneyButtonIconTexture)

	OpenMailMoneyButtonCount:SetDrawLayer("OVERLAY")
end

S:AddCallback("Mail", LoadSkin)