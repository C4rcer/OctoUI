local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G
local unpack = unpack

--[[
	Skin for OctoWoW's Shop (the Donation Rewards window).

	The shop lives in the client's own FrameXML rather than in an addon, so
	there is no source to read and the frame list came from probing in game:

		ShopFrame                     root, plus Close/Previous/Next/Claim
		ShopFrameSearchBox            + its ClearButton
		ShopFrameAutoDress            checkbox
		ShopFrameAboutFrame
		ShopFrameCategoryFrame0..8    + matching *Icon textures
		ShopDressUpFrame              + Model, Undress, Reset, Close

	Every lookup is guarded. This is the failure mode that has caused nearly
	every runtime error in this port: a name that is missing, or is a different
	object type than expected, kills the rest of LoadSkin and leaves everything
	after it unskinned. Probing gave us names, not types or structure, and a
	client patch can change either, so nothing here is assumed to exist.
]]

local function LoadSkin()
	--The probe listed ShopFrame's children but not ShopFrame itself, so do not
	--assume that name exists: fall back to asking a known child for its parent.
	--Nothing below is gated on finding the root either, or one missing name
	--would silently cost us the whole skin.
	local shop = _G["ShopFrame"]
	if not shop then
		local probe = _G["ShopFrameCloseButton"] or _G["ShopFrameSearchBox"]
			or _G["ShopFrameAboutFrame"] or _G["ShopFrameCategoryFrame0"]
		shop = probe and probe.GetParent and probe:GetParent()
	end

	if shop and shop.GetObjectType and shop:GetObjectType() == "Frame" then
		E:StripTextures(shop)
		E:SetTemplate(shop, "Transparent")
	end

	--Title/close
	local close = _G["ShopFrameCloseButton"]
	if close then
		S:HandleCloseButton(close)
	end

	--Paging and the claim action
	local prev, next = _G["ShopFramePreviousButton"], _G["ShopFrameNextButton"]
	if prev then S:HandleNextPrevButton(prev, nil, true) end
	if next then S:HandleNextPrevButton(next) end

	local claim = _G["ShopFrameClaimButton"]
	if claim then S:HandleButton(claim) end

	--Search
	local search = _G["ShopFrameSearchBox"]
	if search then
		S:HandleEditBox(search)
	end

	local searchClear = _G["ShopFrameSearchBoxClearButton"]
	if searchClear then
		--Not a normal button on every client build, so only strip what is there
		if searchClear.SetNormalTexture then searchClear:SetNormalTexture("") end
		if searchClear.SetPushedTexture then searchClear:SetPushedTexture("") end
	end

	--Auto preview toggle
	local autoDress = _G["ShopFrameAutoDress"]
	if autoDress then
		S:HandleCheckBox(autoDress)
	end

	--The About/description pane
	local about = _G["ShopFrameAboutFrame"]
	if about then
		E:StripTextures(about)
		E:SetTemplate(about, "Transparent")
	end

	--Category list down the left. Probed as 0..8, but walk past the end in case
	--a patch adds more, and stop at the first gap.
	local i = 0
	while true do
		local cat = _G["ShopFrameCategoryFrame"..i]
		if not cat then break end

		E:StripTextures(cat)
		S:HandleButton(cat)

		local icon = _G["ShopFrameCategoryFrame"..i.."Icon"]
		if icon and icon.SetTexCoord then
			icon:SetTexCoord(unpack(E.TexCoords))
		end

		i = i + 1
		if i > 30 then break end --paranoia, never loop forever on a live client
	end

	--Dress-up preview is a separate top level frame
	local dress = _G["ShopDressUpFrame"]
	if dress then
		E:StripTextures(dress)
		E:SetTemplate(dress, "Transparent")

		local dressClose = _G["ShopDressUpFrameCloseButton"]
		if dressClose then S:HandleCloseButton(dressClose) end

		local undress = _G["ShopDressUpFrameUndressButton"]
		if undress then S:HandleButton(undress) end

		local reset = _G["ShopDressUpFrameResetButton"]
		if reset then S:HandleButton(reset) end
	end

	--MinimapShopFrame is deliberately left alone: it is the minimap button, and
	--the Minimap module already owns icon placement there.
end

S:AddCallback("SkinOctoShop", LoadSkin)
