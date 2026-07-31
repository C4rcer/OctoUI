local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB

--Cache global variables
--Lua functions
local _G = _G
local tonumber, type = tonumber, type
local format, len, lower, match = string.format, string.len, string.lower, string.match
--WoW API / Variables
local UIFrameFadeOut, UIFrameFadeIn = UIFrameFadeOut, UIFrameFadeIn
local EnableAddOn, DisableAddOn, DisableAllAddOns = EnableAddOn, DisableAddOn, DisableAllAddOns
local SetCVar, GetCVar = SetCVar, GetCVar
local ReloadUI = ReloadUI
local GetAddOnInfo = GetAddOnInfo
local IsAddOnLoaded = IsAddOnLoaded
local GetScreenWidth, GetScreenHeight = GetScreenWidth, GetScreenHeight

function E:EnableAddon(addon)
	local _, _, _, _, _, reason, _ = GetAddOnInfo(addon)
	if reason ~= "MISSING" then
		EnableAddOn(addon)
		ReloadUI()
	else
		E:Print(format("Addon '%s' not found.", addon))
	end
end

function E:DisableAddon(addon)
	local _, _, _, _, _, reason, _ = GetAddOnInfo(addon)
	if reason ~= "MISSING" then
		DisableAddOn(addon)
		ReloadUI()
	else
		E:Print(format("Addon '%s' not found.", addon))
	end
end

function FarmMode()
	if E.private.general.minimap.enable ~= true then return end

	if Minimap:IsShown() then
		UIFrameFadeOut(Minimap, 0.3)
		UIFrameFadeIn(FarmModeMap, 0.3)
		Minimap.fadeInfo.finishedFunc = function()
			Minimap:Hide()
			Minimap.backdrop:Hide()
			_G.MinimapZoomIn:Click()
			_G.MinimapZoomOut:Click()
			Minimap:SetAlpha(1)
		end
		FarmModeMap.enabled = true
	else
		UIFrameFadeOut(FarmModeMap, 0.3)
		UIFrameFadeIn(Minimap, 0.3)
		FarmModeMap.fadeInfo.finishedFunc = function()
			FarmModeMap:Hide()
			Minimap.backdrop:Show()
			_G.MinimapZoomIn:Click()
			_G.MinimapZoomOut:Click()
			Minimap:SetAlpha(1)
		end
		FarmModeMap.enabled = false
	end
end

function E:FarmMode(msg)
	if E.private.general.minimap.enable ~= true then return end
	if msg and type(tonumber(msg)) == "number" and tonumber(msg) <= 500 and tonumber(msg) >= 20 then
		E.db.farmSize = tonumber(msg)
		E:Size(FarmModeMap, tonumber(msg))
	end

	FarmMode()
end

function E:Grid(msg)
	msg = msg and tonumber(msg)
	if type(msg) == "number" and (msg <= 256 and msg >= 4) then
		E.db.gridSize = msg
		E:Grid_Show()
	elseif _G.ElvUIGrid and _G.ElvUIGrid:IsShown() then
		E:Grid_Hide()
	else
		E:Grid_Show()
	end
end

function E:LuaError(msg)
	msg = lower(msg)
	if msg == "on" then
		DisableAllAddOns()
		EnableAddOn("OctoUI")
		SetCVar("ShowErrors", 1)
		ReloadUI()
	elseif msg == "off" then
		SetCVar("ShowErrors", 0)
		E:Print("Lua errors off.")
	else
		E:Print("/luaerror on - /luaerror off")
	end
end

function E:BGStats()
	local DT = E:GetModule("DataTexts")
	DT.ForceHideBGStats = nil
	DT:LoadDataTexts()

	E:Print(L["Battleground datatexts will now show again if you are inside a battleground."])
end

local editbox = CreateFrame("Editbox", "MacroEditBox")
editbox:Hide()

local function OnCallback(command)
	local defaulteditbox = ChatFrameEditBox
	MacroEditBox.chatType = defaulteditbox.chatType
	MacroEditBox.tellTarget = defaulteditbox.tellTarget
	MacroEditBox.channelTarget = defaulteditbox.channelTarget
	MacroEditBox:SetText(command)
	ChatEdit_SendText(MacroEditBox)
end

function E:DelayScriptCall(msg)
	local secs, command = match(msg, "^(%S+)%s+(.*)$")
	secs = tonumber(secs)
	if (not secs) or (len(command) == 0) then
		self:Print("usage: /in <seconds> <command>")
		self:Print("example: /in 1.5 /say hi")
	else
		E:Delay(secs, OnCallback, command)
	end
end

local BLIZZARD_ADDONS = {
	"Blizzard_AuctionUI",
	"Blizzard_BattlefieldMinimap",
	"Blizzard_BindingUI",
	"Blizzard_CombatText",
	"Blizzard_CraftUI",
	"Blizzard_GMSurveyUI",
	"Blizzard_InspectUI",
	"Blizzard_MacroUI",
	"Blizzard_RaidUI",
	"Blizzard_TalentUI",
	"Blizzard_TradeSkillUI",
	"Blizzard_TrainerUI"
}

function E:EnableBlizzardAddOns()
	for _, addon in pairs(BLIZZARD_ADDONS) do
		local reason = select(5, GetAddOnInfo(addon))
		if reason == "DISABLED" then
			EnableAddOn(addon)
			E:Print("The following addon was re-enabled:", addon)
		end
	end
end

--Spell queueing is nampower's, not OctoUI's, and it is configured entirely through
--CVars the DLL registers at load. Three things can be wrong and they need telling
--apart: the DLL is not reaching this Lua state at all, it is loaded but the relevant
--queue type is switched off, or it is loaded and queueing fine and the problem lies
--elsewhere. Only the last is invisible without watching the event.
local QUEUE_CVARS = {
	"NP_QueueCastTimeSpells",
	"NP_QueueInstantSpells",
	"NP_QueueChannelingSpells",
	"NP_QueueTargetingSpells",
	"NP_QueueSpellsOnCooldown",
	"NP_QueueOnSwingSpells",
	"NP_SpellQueueWindowMs",
	"NP_ChannelQueueWindowMs",
	"NP_CooldownQueueWindowMs",
}

local QUEUE_API = {"QueueSpellByName", "CastSpellByNameNoQueue", "CastSpellNoQueue", "QueueScript"}

local queueWatcher, queueWatching, queueHooked

--How much of the current cast is left, in seconds, or nil when nothing is casting.
--This is the number that decides whether a press queues, and it is the one thing the
--player cannot see -- "sporadic" is what a 500ms window looks like from the outside.
local function CastRemaining()
	local bar = _G.ElvUF_Player and _G.ElvUF_Player.Castbar
	if not (bar and bar:IsShown()) then return end

	if bar.channeling then
		return bar.value
	elseif bar.casting then
		return (bar.max or 0) - (bar.value or 0)
	end
end

--Logged on the way past, so a press that never queued still leaves a line. The hooks
--stay installed once added -- hooksecurefunc cannot be undone -- so everything they do
--is behind the watching flag.
local function LogCastAttempt(what)
	if not queueWatching then return end

	local remaining = CastRemaining()
	if remaining then
		E:Print(format("press %s with |cffffff00%.2fs|r left on the current cast", what, remaining))
	else
		E:Print(format("press %s (nothing casting)", what))
	end
end

function E:QueueReport()
	local seen = 0
	for i = 1, getn(QUEUE_CVARS) do
		local name = QUEUE_CVARS[i]
		local value = GetCVar(name)
		if value then seen = seen + 1 end

		--"0" is a perfectly ordinary answer and the reason one of these is off by
		--default: on-swing spells do not queue unless asked to
		E:Print(format("%s = %s", name,
			value and ((value == "0") and ("|cffff9900"..value.."|r") or value) or "|cffff0000nil|r"))
	end

	if seen == 0 then
		E:Print("|cffff0000None of nampower's CVars exist|r - the DLL is not in this session. Check dlls.txt and Logs\\nampower_debug.log.")
		return
	end

	local missing = ""
	for i = 1, getn(QUEUE_API) do
		if not _G[QUEUE_API[i]] then
			missing = missing..((missing == "") and "" or ", ")..QUEUE_API[i]
		end
	end
	E:Print(format("nampower Lua API: %s", (missing == "") and "|cff00ff00all present|r" or ("|cffff0000missing "..missing.."|r")))

	--The only actual proof that a press was queued rather than dropped
	if queueWatching then
		queueWatcher:UnregisterAllEvents()
		queueWatching = nil
		E:Print("Queue watch |cffff9900off|r.")
		return
	end

	if not queueWatcher then
		queueWatcher = CreateFrame("Frame", "OctoUI_QueueWatch", E.UIParent)
		queueWatcher:SetScript("OnEvent", function()
			E:Print(format("|cff00ff00queued|r %s %s", tostring(arg1), tostring(arg2)))
		end)
	end

	if not queueHooked then
		queueHooked = true
		hooksecurefunc("CastSpellByName", function(spell) LogCastAttempt(tostring(spell)) end)
		hooksecurefunc("UseAction", function(slot) LogCastAttempt("action "..tostring(slot)) end)
	end

	--pcall: registering an event this client has never heard of raises, and that is
	--itself the answer -- it means nampower never added its custom event codes
	local ok = pcall(queueWatcher.RegisterEvent, queueWatcher, "SPELL_QUEUE_EVENT")
	if not ok then
		E:Print("|cffff0000SPELL_QUEUE_EVENT is not a known event|r - nampower did not register its custom events in this session.")
		return
	end

	queueWatching = true
	E:Print("Queue watch |cff00ff00on|r - every press now prints how much of the current cast was left, and a queued press prints a second line. Compare the two against the windows above. Run /octoui-queue again to stop.")
end

--Delegates: the interesting state is all locals of Modules/Bags/Sort.lua.
function E:BagSortReport()
	local B = E:GetModule("Bags", true)
	if B and B.SortReport then
		B:SortReport()
	else
		E:Print("|cffff0000Bags module is not loaded.|r")
	end
end

--Why the threat window is not on screen. Every one of these has been a real cause
--at least once: the module never initialised, the frame is hidden, it is parked off
--screen by the saved position, it is scaled or faded to nothing, or it is sized to
--zero height. Reports all of them at once rather than one reload per guess.
function E:ThreatReport()
	local frame = _G["TWTMain"]

	E:Print(format("module: %s, private toggle: %s, standalone TWThreat: %s",
		E:GetModule("ThreatMeter", true) and "registered" or "|cffff0000MISSING|r",
		E.private.general.threatMeter and "on" or "|cffff0000off|r",
		IsAddOnLoaded("TWThreat") and "|cffff0000loaded (conflicts)|r" or "not loaded"))

	if not frame then
		E:Print("|cffff0000TWTMain does not exist|r - the XML never loaded. A newly added file needs a full exit of WoW.exe, not a reload.")
		return
	end

	E:Print(format("frame: shown %s, visible %s, alpha %.2f, strata %s, level %d",
		tostring(frame:IsShown()), tostring(frame:IsVisible()), frame:GetAlpha(),
		frame:GetFrameStrata(), frame:GetFrameLevel()))

	E:Print(format("size: %.0f x %.0f, scale %.2f (config %.2f)",
		frame:GetWidth(), frame:GetHeight(), frame:GetEffectiveScale(),
		(TWT_CONFIG and TWT_CONFIG.windowScale) or 0))

	--nil means the frame has never been given a position it could resolve
	local left, top = frame:GetLeft(), frame:GetTop()
	if not (left and top) then
		E:Print("position: |cffff0000unresolved|r - the frame has no usable anchor, so it is drawn nowhere.")
	else
		--both sides converted to real pixels: GetLeft is in the frame's own units and
		--GetScreenWidth is in UIParent's, and comparing the two directly is nonsense
		local scale = frame:GetEffectiveScale()
		local uiScale = E.UIParent:GetEffectiveScale()
		local pxLeft, pxTop = left * scale, top * scale
		local pxWidth = GetScreenWidth() * uiScale
		local pxHeight = GetScreenHeight() * uiScale
		local onScreen = pxTop > 0 and pxTop <= pxHeight + frame:GetHeight() * scale
			and pxLeft < pxWidth and pxLeft > -(frame:GetWidth() * scale)

		E:Print(format("position: left %.0f top %.0f px on a %.0f x %.0f px screen -- %s",
			pxLeft, pxTop, pxWidth, pxHeight,
			onScreen and "|cff00ff00on screen|r" or "|cffff0000off screen|r"))
	end

	if TWT_CONFIG then
		E:Print(format("config: visible %s, hideOOC %s, showInCombat %s, bars %d, bar height %d",
			tostring(TWT_CONFIG.visible), tostring(TWT_CONFIG.hideOOC),
			tostring(TWT_CONFIG.showInCombat), TWT_CONFIG.visibleBars or 0,
			TWT_CONFIG.barHeight or 0))
	else
		E:Print("|cffff0000TWT_CONFIG is nil|r - saved variables never loaded.")
	end
end

--Puts the window back in the middle of the screen at a sane size, for when the saved
--position or scale has put it somewhere unreachable. /twt has no equivalent.
function E:ThreatReset()
	local frame = _G["TWTMain"]
	if not frame then
		E:Print("|cffff0000TWTMain does not exist.|r")
		return
	end

	if TWT_CONFIG then
		TWT_CONFIG.visible = true
		TWT_CONFIG.windowScale = 1
	end

	frame:SetScale(1)
	frame:SetAlpha(1)
	frame:Show()

	--the mover owns the anchor, so moving the frame alone would be undone on the next
	--reload; reset the mover when there is one and only free-hand it when there is not
	if E.CreatedMovers and E.CreatedMovers["ThreatMeterMover"] then
		E:ResetMovers(L["Threat Meter"])
		E:Print("Threat window mover reset to its default position at scale 1.")
	else
		frame:ClearAllPoints()
		frame:SetPoint("CENTER", E.UIParent, "CENTER", 0, 0)
		E:Print("Threat window reset to the centre of the screen at scale 1.")
	end
end

--Nameplate debuff timers are reconstructed from three separate things -- the bundled
--duration table, a tooltip scan for the spell name, and combat-log timestamps -- and
--when no timer appears there is no way to tell which one failed by looking at the
--nameplate. Dumps all three for the current target.
function E:DebuffTimerReport()
	local NP = E:GetModule("NamePlates")
	local lib = NP and NP.LibDebuff

	local durations = E.DebuffDurations and E.DebuffDurations["debuffs"]
	local spells = 0
	if durations then
		for _ in pairs(durations) do spells = spells + 1 end
	end

	local tracked = 0
	if lib and lib.objects then
		for _ in pairs(lib.objects) do tracked = tracked + 1 end
	end

	E:Print(format("locale %s, duration table: %s (%d spells)", GetLocale(),
		durations and "loaded" or "|cffff0000MISSING|r", spells))
	E:Print(format("LibDebuff: %s, units with tracked debuffs: %d",
		lib and "loaded" or "|cffff0000MISSING|r", tracked))

	local haste = NP and NP.LibHaste
	if haste then
		E:Print(format("haste %d%% + casting speed %d%% = %.1f%% total, scales DoTs: %s",
			E.Stats:Get("haste"), E.Stats:Get("castingSpeed"), haste:GetCastingSpeed() * 100,
			haste:ScalesDots() and "|cff00ff00yes|r" or "no (durations left unhasted)"))
	else
		E:Print("LibHaste: |cffff0000MISSING|r")
	end

	--the keys say whether the combat log is giving names or GUIDs, which is the
	--difference between a lookup that matches and one that silently does not
	if lib and lib.objects then
		for key in pairs(lib.objects) do
			E:Print(format("  tracked key: '%s'", tostring(key)))
		end
	end

	if not UnitExists("target") then
		E:Print("no target - target something you have a debuff on and run this again")
		return
	end

	local name, level = UnitName("target"), UnitLevel("target")
	--SuperWoW returns the GUID as a second value from UnitExists
	local _, guid = UnitExists("target")
	E:Print(format("target: %s (level %s) guid %s", tostring(name), tostring(level), tostring(guid)))

	local found
	for i = 1, 16 do
		local texture = UnitDebuff("target", i)
		if not texture then break end
		found = true

		local effect = NP:ScanAuraName("target", i, true)
		local known = (durations and effect and durations[effect]) and "in table" or "|cffff0000not in table|r"
		--`local a, b = cond and f()` truncates f() to one value, so timeleft was
		--always nil here regardless of what the store held. Call it plainly.
		local duration, timeleft
		if lib then
			duration, timeleft = lib:GetTimeLeft(name, level, effect or "", guid)
		end

		--built separately: a nil reaching string.format raises, and an error here
		--aborts the loop, so the remaining debuffs never get reported at all
		local timer = "|cffff0000no timer|r"
		if type(timeleft) == "number" then
			timer = format("left %.1f of %.0f", timeleft, (type(duration) == "number" and duration) or 0)
		end

		E:Print(format("  %d. %s | %s | %s", i,
			effect and ("'"..effect.."'") or "|cffff0000name unresolved|r", known, timer))
	end

	if not found then E:Print("  target has no debuffs") end
end

function E:LoadCommands()
	self:RegisterChatCommand("in", "DelayScriptCall")

	--The ElvUI names (/ec, /elvui, /egrid, /estatus) are deliberately NOT registered.
	--Only the engine table, saved variables and AceConfig registry key stay "ElvUI",
	--because profiles and mover positions are keyed off them; nothing a user types is.
	self:RegisterChatCommand("oc", "ToggleConfig")
	self:RegisterChatCommand("octoui", "ToggleConfig")
	self:RegisterChatCommand("ocgrid", "Grid")
	self:RegisterChatCommand("ocstatus", "ShowStatusReport")

	self:RegisterChatCommand("bgstats", "BGStats")
	self:RegisterChatCommand("luaerror", "LuaError")
	self:RegisterChatCommand("moveui", "ToggleConfigMode")
	self:RegisterChatCommand("resetui", "ResetUI")
	self:RegisterChatCommand("enable", "EnableAddon")
	self:RegisterChatCommand("disable", "DisableAddon")
	self:RegisterChatCommand("farmmode", "FarmMode")
	self:RegisterChatCommand("enableblizzard", "EnableBlizzardAddOns")
	self:RegisterChatCommand("octoui-dots", "DebuffTimerReport")
	self:RegisterChatCommand("octoui-threat", "ThreatReport")
	self:RegisterChatCommand("octoui-bags", "BagSortReport")
	self:RegisterChatCommand("octoui-queue", "QueueReport")
	self:RegisterChatCommand("octoui-threatreset", "ThreatReset")

	if E:GetModule("ActionBars") and E.private.actionbar.enable then
		self:RegisterChatCommand("kb", E:GetModule("ActionBars").ActivateBindMode)
	end
end
