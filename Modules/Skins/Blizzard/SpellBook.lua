local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack
--WoW API / Variables
local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc

local function LoadSkin()
	if E.private.skins.blizzard.enable ~= true or E.private.skins.blizzard.spellbook ~= true then return end

	local SpellBookFrame = _G["SpellBookFrame"]
	E:StripTextures(SpellBookFrame, true)
	E:CreateBackdrop(SpellBookFrame, "Transparent")
	E:Point(SpellBookFrame.backdrop, "TOPLEFT", 10, -12)
	E:Point(SpellBookFrame.backdrop, "BOTTOMRIGHT", -31, 75)

	SpellBookFrame:EnableMouseWheel(true)
	SpellBookFrame:SetScript("OnMouseWheel", function()
		--do nothing if not on an appropriate book type
		if SpellBookFrame.bookType ~= BOOKTYPE_SPELL then
			return
		end

		local currentPage, maxPages = SpellBook_GetCurrentPage()

		if arg1 > 0 then
			if currentPage > 1 then
				PrevPageButton_OnClick()
			end
		else
			if currentPage < maxPages then
				NextPageButton_OnClick()
			end
		end
	end)

	for i = 1, 3 do
		local tab = _G["SpellBookFrameTabButton"..i]

		tab:GetNormalTexture():SetTexture("")
		tab:GetDisabledTexture():SetTexture("")

		S:HandleTab(tab)

		E:Point(tab.backdrop, "TOPLEFT", 14, E.PixelMode and -17 or -19)
		E:Point(tab.backdrop, "BOTTOMRIGHT", -14, 19)
	end

	S:HandleNextPrevButton(SpellBookPrevPageButton)
	S:HandleNextPrevButton(SpellBookNextPageButton)

	S:HandleCloseButton(SpellBookCloseButton)

	for i = 1, SPELLS_PER_PAGE do
		local button = _G["SpellButton"..i]
		E:StripTextures(button)

		--AutoCastable belongs to the pet spellbook and is absent from the
		--regular one on this client
		local autoCastable = _G["SpellButton"..i.."AutoCastable"]
		if autoCastable then
			if autoCastable.SetTexture then
				autoCastable:SetTexture("Interface\\Buttons\\UI-AutoCastableOverlay")
			end
			E:SetOutside(autoCastable, button, 16, 16)
		end

		E:CreateBackdrop(button, "Default", true)

		local skinObj = _G["SpellButton"..i.."IconTexture"]
		if skinObj then skinObj:SetTexCoord(unpack(E.TexCoords)) end

		E:RegisterCooldown(_G["SpellButton"..i.."Cooldown"])
	end

	hooksecurefunc("SpellButton_UpdateButton", function()
		local name = this:GetName()
		local spellName = _G[name.."SpellName"]
		local subSpellName = _G[name.."SubSpellName"]
		local spellHighlight = _G[name.."Highlight"]
		if spellName then spellName:SetTextColor(1, 0.80, 0.10) end
		if subSpellName then subSpellName:SetTextColor(1, 1, 1) end
		if spellHighlight and spellHighlight.SetTexture then spellHighlight:SetTexture(1, 1, 1, 0.3) end
	end)

	for i = 1, MAX_SKILLLINE_TABS do
		local tab = _G["SpellBookSkillLineTab"..i]

		E:StripTextures(tab)
		E:StyleButton(tab, nil, true)
		E:SetTemplate(tab, "Default", true)

		E:SetInside(tab:GetNormalTexture())
		tab:GetNormalTexture():SetTexCoord(unpack(E.TexCoords))
	end

	SpellBookPageText:SetTextColor(1, 1, 1)
end

S:AddCallback("SpellBook", LoadSkin)