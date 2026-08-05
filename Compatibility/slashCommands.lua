--Cache global variables
local strmatch = strmatch
local format = format
local tostring = tostring
--WoW API
local IsAddOnLoaded = IsAddOnLoaded
local GetRealZoneText = GetRealZoneText
local IsInInstance = IsInInstance

local checked
local function LoadDebugTools()
	if checked then return end

	local _, _, _, _, loadable, reason = GetAddOnInfo("!DebugTools")
	checked = true

	if reason == "MISSING" then return end

	--Load-on-demand reports loadable as nil, so it needs testing on its own; only a
	--genuinely disabled addon takes the enable/load/disable path below.
	if loadable or reason == "DEMAND_LOADED" then
		LoadAddOn("!DebugTools")
	else
		EnableAddOn("!DebugTools")
		LoadAddOn("!DebugTools")
		DisableAddOn("!DebugTools")
	end
end

SLASH_FRAMESTACK1 = "/framestack"
SLASH_FRAMESTACK2 = "/fstack"
SlashCmdList["FRAMESTACK"] = function(msg)
	LoadDebugTools()

	if IsAddOnLoaded("!DebugTools") then
		local showHiddenArg, showRegionsArg = strmatch(msg, "^%s*(%S+)%s+(%S+)%s*$")
		if (not showHiddenArg or not showRegionsArg) then
			showHiddenArg = strmatch(msg, "^%s*(%S+)%s*$")
			showRegionsArg = "1"
		end
		local showHidden = showHiddenArg == "true" or showHiddenArg == "1"
		local showRegions = showRegions == "true" or showRegionsArg == "1"

		FrameStackTooltip_Toggle(showHidden, showRegions)
	end
end

SLASH_EVENTTRACE1 = "/eventtrace"
SLASH_EVENTTRACE2 = "/etrace"
SlashCmdList["EVENTTRACE"] = function(msg)
	LoadDebugTools()

	if IsAddOnLoaded("!DebugTools") then
		EventTraceFrame_HandleSlashCmd(msg)
	end
end

SLASH_DUMP1 = "/dump"
SlashCmdList["DUMP"] = function(msg)
	LoadDebugTools()

	if IsAddOnLoaded("!DebugTools") then
		DevTools_DumpCommand(msg)
	end
end

--Reports the current zone as the client actually names it, so custom server
--instances can be added to customZoneInfo in api\wowAPI.lua. Without an entry
--an unlisted raid falls back to the default group size rather than a real one.
local function Print(text)
	DEFAULT_CHAT_FRAME:AddMessage(text)
end

SLASH_OCTOUIZONEDUMP1 = "/octoui-zonedump"
SLASH_OCTOUIZONEDUMP2 = "/ozd"
SlashCmdList["OCTOUIZONEDUMP"] = function()
	local zone = GetRealZoneText()
	local inInstance, instanceType = IsInInstance()

	Print("|cff1784d1OctoUI|r zone dump")
	Print(format("  zone          : %s", (zone and zone ~= "") and zone or "<unknown>"))
	Print(format("  instanceType  : %s", instanceType or "none"))

	if not inInstance then
		Print("  Not inside an instance, so there is nothing to add.")
		return
	end

	local _, _, _, difficultyName, maxPlayers = GetInstanceInfo()
	Print(format("  resolved size : %s (%s)", tostring(maxPlayers), tostring(difficultyName)))
	Print("  Add to customZoneInfo in !Compatibility\\api\\wowAPI.lua:")
	Print(format("    [\"%s\"] = {mapID = 0, maxPlayers = %s},", zone, tostring(maxPlayers)))
end