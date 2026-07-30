ElvUI = {}

--Cache global variables
--Lua functions
local _G = _G
local pairs, unpack = pairs, unpack
local getn, wipe = table.getn, wipe
local format, strsplit = string.format, string.split
--WoW API / Variables
local CreateFrame = CreateFrame
local GetAddOnInfo = GetAddOnInfo
local GetAddOnMetadata = GetAddOnMetadata
local HideUIPanel = HideUIPanel
local IsAddOnLoaded = IsAddOnLoaded
local LoadAddOn = LoadAddOn
local ReloadUI = ReloadUI
local GameMenuFrame = GameMenuFrame
local GameMenuButtonLogout = GameMenuButtonLogout

BINDING_HEADER_ELVUI = GetAddOnMetadata("OctoUI", "Title")

--The engine table stays named ElvUI: ~300 files start with unpack(ElvUI), and
--the AceAddon/AceLocale/AceConfig registry keys, saved variables (ElvDB) and
--frame names (ElvUF_*) all key off it. Only the addon FOLDER is OctoUI, which
--is what GetAddOnMetadata and every media path use.
local AddOnName, Engine = "ElvUI", ElvUI
OctoUI = ElvUI --alias, so new code can say either

local AddOn = LibStub("AceAddon-3.0"):NewAddon(AddOnName, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0", "AceHook-3.0")

--AceConfig's registry key. Separate from AddOnName because that one doubles as
--the engine global and the AceLocale key, which 300-odd files and every locale
--file depend on. This one is only an AceConfig handle, and it shows up in
--option validation errors, so it is worth having it read OctoUI.
AddOn.ConfigAppName = "OctoUI"

AddOn.callbacks = AddOn.callbacks or LibStub("CallbackHandler-1.0"):New(AddOn)

-- Defaults
AddOn.DF = {}
AddOn.DF.profile = {}
AddOn.DF.global = {}
AddOn.privateVars = {}
AddOn.privateVars.profile = {}

AddOn.Options = {
	type = "group",
	name = "OctoUI", --display name only; the addon, engine global and AceConfig registry key stay "ElvUI"
	args = {},
}

local Locale = LibStub("AceLocale-3.0"):GetLocale(AddOnName, false)
Engine[1] = AddOn
Engine[2] = Locale
Engine[3] = AddOn.privateVars.profile
Engine[4] = AddOn.DF.profile
Engine[5] = AddOn.DF.global

_G[AddOnName] = Engine
local tcopy = table.copy
function AddOn:OnInitialize()
	if not ElvCharacterDB then
		ElvCharacterDB = {}
	end

	ElvCharacterData = nil --Depreciated
	ElvPrivateData = nil --Depreciated
	ElvData = nil --Depreciated

	self.db = tcopy(self.DF.profile, true)
	self.global = tcopy(self.DF.global, true)
	if ElvDB then
		if ElvDB.global then
			self:CopyTable(self.global, ElvDB.global)
		end

		local profileKey
		if ElvDB.profileKeys then
			profileKey = ElvDB.profileKeys[self.myname.." - "..self.myrealm]
		end

		if profileKey and ElvDB.profiles and ElvDB.profiles[profileKey] then
			self:CopyTable(self.db, ElvDB.profiles[profileKey])
		end
	end

	self.private = tcopy(self.privateVars.profile, true)
	if ElvPrivateDB then
		local profileKey
		if ElvPrivateDB.profileKeys then
			profileKey = ElvPrivateDB.profileKeys[self.myname.." - "..self.myrealm]
		end

		if profileKey and ElvPrivateDB.profiles and ElvPrivateDB.profiles[profileKey] then
			self:CopyTable(self.private, ElvPrivateDB.profiles[profileKey])
		end
	end

	if self.private.general.pixelPerfect then
		self.Border = self.mult
		self.Spacing = 0
		self.PixelMode = true
	end

	self:UIScale()
	self:UpdateMedia()

	self:RegisterEvent("PLAYER_LOGIN", "Initialize")
	self:Contruct_StaticPopups()
	self:InitializeInitialModules()

	if IsAddOnLoaded("Tukui") then
		self:StaticPopup_Show("TUKUI_ELVUI_INCOMPATIBLE")
	end

	local GameMenuButton = CreateFrame("Button", nil, GameMenuFrame, "GameMenuButtonTemplate")
	GameMenuButton:SetWidth(GameMenuButtonLogout:GetWidth())
	GameMenuButton:SetHeight(GameMenuButtonLogout:GetHeight())

	GameMenuButton:SetText(self.title)
	GameMenuButton:SetScript("OnClick", function()
		AddOn:ToggleConfig()
		HideUIPanel(GameMenuFrame)
	end)
	GameMenuFrame[AddOnName] = GameMenuButton

	HookScript(GameMenuFrame, "OnShow", function()
		if not GameMenuFrame.isElvUI then
			GameMenuFrame:SetHeight(GameMenuFrame:GetHeight() + GameMenuButtonLogout:GetHeight() + 17)
			GameMenuFrame.isElvUI = true
		end
		local _, relTo = GameMenuButtonLogout:GetPoint()
		if relTo ~= GameMenuFrame[AddOnName] then
			GameMenuFrame[AddOnName]:ClearAllPoints()
			GameMenuFrame[AddOnName]:SetPoint("TOPLEFT", relTo, "BOTTOMLEFT", 0, -1)
			GameMenuButtonLogout:ClearAllPoints()
			GameMenuButtonLogout:SetPoint("TOPLEFT", GameMenuFrame[AddOnName], "BOTTOMLEFT", 0, -16)
		end
	end)

	if AddOn.private.skins.blizzard.enable ~= true or AddOn.private.skins.blizzard.misc ~= true then return end

	local S = AddOn:GetModule("Skins")
	S:HandleButton(GameMenuButton)
end

function AddOn:ResetProfile()
	local profileKey
	if ElvPrivateDB.profileKeys then
		profileKey = ElvPrivateDB.profileKeys[self.myname.." - "..self.myrealm]
	end

	if profileKey and ElvPrivateDB.profiles and ElvPrivateDB.profiles[profileKey] then
		ElvPrivateDB.profiles[profileKey] = nil
	end

	ElvCharacterDB = nil
	ReloadUI()
end

function AddOn:OnProfileReset()
	self:StaticPopup_Show("RESET_PROFILE_PROMPT")
end

local pageNodes = {}
function AddOn:ToggleConfig(msg)
	--The options GUI used to be the load-on-demand ElvUI_Config addon and was
	--pulled in here on first /ec. It now ships inside this addon under Config\
	--and is already loaded, so there is nothing to demand-load or version-check.
	if not self.ConfigLoaded then
		self:Print("|cffff0000Error -- the OctoUI options GUI failed to load. Reinstall the addon.|r")
		return
	end

	--Anything in the options that needs a live engine (E.db, E.data, movers,
	--registered datatexts) is built here rather than at file load. Idempotent.
	self:BuildDeferredOptions()

	local ACD = LibStub("AceConfigDialog-3.0")
	local ConfigOpen = ACD.OpenFrames[AddOn.ConfigAppName]

	local pages, msgStr
	if msg and msg ~= "" then
		pages = {strsplit(",", msg)}
		msgStr = gsub(msg, ",","\001")
	end

	local mode = "Close"
	if not ConfigOpen or (pages ~= nil) then
		if pages ~= nil then
			local pageCount, index, mainSel = getn(pages)
			if pageCount > 1 then
				wipe(pageNodes)
				index = 0

				local main, mainNode, mainSelStr, sub, subNode, subSel
				for i = 1, pageCount do
					if i == 1 then
						main = pages[i] and ACD.Status and ACD.Status[AddOn.ConfigAppName]
						mainSel = main and main.status and main.status.groups and main.status.groups.selected
						mainSelStr = mainSel and (gsub("^"..mainSel, "([%(%)%.%%%+%-%*%?%[%^%$])","%%%1").."\001")
						mainNode = main and main.children and main.children[pages[i]]
						pageNodes[index + 1], pageNodes[index + 2] = main, mainNode
					else
						sub = pages[i] and pageNodes[i] and ((i == pageCount and pageNodes[i]) or pageNodes[i].children[pages[i]])
						subSel = sub and sub.status and sub.status.groups and sub.status.groups.selected
						subNode = (mainSelStr and match(msgStr, gsub(mainSelStr..pages[i], "([%(%)%.%%%+%-%*%?%[%^%$])","%%%1").."$") and (subSel and subSel == pages[i])) or ((i == pageCount and not subSel) and mainSel and mainSel == msgStr)
						pageNodes[index + 1], pageNodes[index + 2] = sub, subNode
					end
					index = index + 2
				end
			else
				local main = pages[1] and ACD.Status and ACD.Status[AddOn.ConfigAppName]
				mainSel = main and main.status and main.status.groups and main.status.groups.selected
			end

			if ConfigOpen and ((not index and mainSel and mainSel == msg) or (index and pageNodes and pageNodes[index])) then
				mode = "Close"
			else
				mode = "Open"
			end
		else
			mode = "Open"
		end
	end
	--ConfigAppName, not AddOnName: the options table is registered with
	--AceConfig under the former. AddOnName is the engine/AceLocale identity.
	ACD[mode](ACD, AddOn.ConfigAppName)

	if pages and (mode == "Open") then
		ACD:SelectGroup(AddOn.ConfigAppName, unpack(pages))
	end

	if mode == "Open" then
		PlaySound("igMainMenuOpen")
	else
		PlaySound("igMainMenuClose")
	end

	GameTooltip:Hide() --Just in case you're mouseovered something and it closes.
end
