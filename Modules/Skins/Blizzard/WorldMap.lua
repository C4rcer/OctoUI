local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local S = E:GetModule("Skins");

--Cache global variables
--Lua functions
local _G = _G

local function LoadSkin()
	if E.private.skins.blizzard.enable ~= true or E.private.skins.blizzard.worldmap ~= true then return end

	local WorldMapFrame = _G["WorldMapFrame"]
	E:StripTextures(WorldMapFrame)
	E:CreateBackdrop(WorldMapPositioningGuide, "Transparent")

	--The continent and zone dropdowns are DEAD on this client -- clicking either opens
	--nothing -- and skinned they were worse than useless: HandleDropDownBox strips their
	--textures and lays a backdrop over them, so they showed up as two blank black bars
	--pasted across the top of the map with no label and no function.
	--
	--Killed rather than skinned. The zone name is already in the frame title and pfQuest
	--carries its own navigation, so nothing is lost with them gone.
	--
	--Re-anchor BEFORE killing: E:Kill reparents to E.HiddenFrame, and the zoom out button
	--was anchored to the zone dropdown, so it would have gone with it.
	E:Point(WorldMapZoomOutButton, "TOPLEFT", WorldMapDetailFrame, "TOPLEFT", 4, -4)
	S:HandleButton(WorldMapZoomOutButton)

	E:Kill(WorldMapContinentDropDown)
	E:Kill(WorldMapZoneDropDown)

	S:HandleCloseButton(WorldMapFrameCloseButton)

	E:CreateBackdrop(WorldMapDetailFrame, "Default")
end

S:AddCallback("SkinWorldMap", LoadSkin)