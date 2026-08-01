local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB

--Cache global variables
--Lua functions
local _G = _G
local tonumber, type, pairs = tonumber, type, pairs
local format, len, lower, match = string.format, string.len, string.lower, string.match
--WoW API / Variables
local UIFrameFadeOut, UIFrameFadeIn = UIFrameFadeOut, UIFrameFadeIn
local EnableAddOn, DisableAddOn, DisableAllAddOns = EnableAddOn, DisableAddOn, DisableAllAddOns
local SetCVar, GetCVar = SetCVar, GetCVar
local ReloadUI = ReloadUI
local GetAddOnInfo = GetAddOnInfo
local IsAddOnLoaded = IsAddOnLoaded
local GetScreenWidth, GetScreenHeight = GetScreenWidth, GetScreenHeight
local GetPlayerBuff, GetPlayerBuffTexture = GetPlayerBuff, GetPlayerBuffTexture
local GetTime = GetTime
local GetNumRaidMembers, GetNumPartyMembers = GetNumRaidMembers, GetNumPartyMembers

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

--Damage meter totals, before there is any window to read them in. `overall` unless
--"current" is passed, so a fight can be checked against a whole session.
function E:MeterReport(msg)
	local M = E:GetModule("Misc", true)
	if not (M and M.MeterData) then
		E:Print("|cffff0000Damage meter is not loaded.|r")
		return
	end

	--Which of the two sources is running, and for the fallback how much of the combat
	--log this client actually handed over. A fallback with no format strings behind it
	--is a window that will stay empty forever, and that has to be visible rather than
	--looking like nothing is happening.
	local source, patterns, events = M:MeterSource()
	if source == "combatlog" then
		E:Print(format("|cffff9900combat log fallback|r - nampower's events are not on this client, so the meter is reading the log instead: %d format strings, %d events. Less accurate, and capped by the log's own range.", patterns or 0, events or 0))
	end

	if not M.MeterAvailable() then
		E:Print("|cffff0000No usable source.|r nampower's combat events are not available, and this client did not provide the combat log format strings to fall back on either.")
		return
	end

	if msg and lower(msg) == "reset" then
		M:ResetMeter()
		E:Print("Meter reset.")
		return
	elseif msg and lower(msg) == "debug" then
		E:Print(format("Meter event dump %s.", M:ToggleMeterDebug() and "|cff00ff00on|r - every damage event in range now prints its raw arguments" or "|cffff9900off|r"))
		return
	end

	local segment = (msg and lower(msg) == "current") and "current" or "overall"
	local rows, duration = M:MeterData(segment)

	E:Print(format("%s -- %.1fs, %d sources", segment, duration, getn(rows)))

	--The banked fights, so the window's segment button is not the only way to know
	--what is in there
	local past = M:MeterHistory()
	if getn(past) > 0 then
		local line = ""
		for i = 1, getn(past) do
			line = line..format("%s%s (%.0fs)", (i > 1) and ", " or "", past[i].label, past[i].duration)
		end
		E:Print(format("%d banked: %s", getn(past), line))
	end

	if getn(rows) == 0 then
		E:Print("nothing recorded yet")
		return
	end

	for i = 1, getn(rows) do
		local row = rows[i]
		if row.damage > 0 or row.healing > 0 then
			E:Print(format("%d. %s  %d dmg (%.1f dps)%s", i, row.name, row.damage, row.dps,
				row.healing > 0 and format("  %d heal (%.1f hps)", row.healing, row.hps) or ""))

			--Per-spell breakdown, which until now was recorded and never shown anywhere.
			--The window has a click-through view of the same data; this is the version
			--that can be pasted into a chat window.
			local spells = M:MeterSpells(segment, row.guid, "damage")
			for s = 1, getn(spells) do
				local hits = spells[s].hits
				E:Print(format("      |cff999999%s  %d  %.0f%%  %d %s|r",
					spells[s].name, spells[s].damage, spells[s].share * 100,
					hits, (hits == 1) and "hit" or "hits"))
			end
		end
	end
end

--Locally modelled threat on the current target, for when the server will not answer --
--which on this server is any time you are not in a group. Prints the confidence
--alongside, because a fight carried by Torment's unverified flat value deserves less
--trust than one that was all plain damage, and the number alone cannot say which.
function E:ThreatModelReport(msg)
	local M = E:GetModule("Misc", true)
	if not (M and M.ThreatOn) then
		E:Print("|cffff0000Threat model is not loaded.|r A newly added file needs a full exit of WoW.exe, not a reload.")
		return
	end

	if not M:ThreatModelAvailable() then
		E:Print("|cffff0000nampower is not in this session|r - the model reads its structured combat events, so it has nothing to work from.")
		return
	end

	if msg and lower(msg) == "calibrate" then
		local on = M:ToggleThreatCalibration()
		E:Print(format("Threat calibration %s.", on
			and "|cff00ff00on|r - fight normally; every time aggro changes hands between you and your pet it will report what that implies for the pet's flat threat per cast"
			or "|cffff9900off|r"))
		return
	end

	if msg and lower(msg) == "samples" then
		local samples = M:ThreatCalibrationSamples()
		if getn(samples) == 0 then
			E:Print("no calibration samples yet - run |cffffcc00/octoui-threatmodel calibrate|r and fight something your pet can hold.")
			return
		end

		--Printed rather than averaged. The melee and ranged columns cannot both be right,
		--and which one applies depends on where you were standing at that instant; the
		--true value is whichever column agrees with itself across fights, and that is
		--something to look at rather than something to compute a mean of.
		E:Print(format("%d calibration sample(s) -- flat threat per cast:", getn(samples)))
		for i = 1, getn(samples) do
			local s = samples[i]
			E:Print(format("  %d. %s after %d cast(s):  melee %.0f  |cff999999|r  ranged %.0f",
				i, s.direction, s.casts, s.melee, s.ranged))
		end
		return
	end

	local rows, top = M:ThreatOn()
	if getn(rows) == 0 then
		E:Print("no threat recorded on the current target yet")
		return
	end

	local confidence = M:ThreatConfidence()
	E:Print(format("threat on %s -- %d source(s), %.0f%% from checked numbers",
		UnitName("target") or "?", getn(rows), confidence * 100))

	if confidence < 1 then
		E:Print("|cffff9900Some of this leans on ability threat values that have not been verified on this server.|r See ABILITY_THREAT in Modules/Misc/ThreatModel.lua.")
	end

	for i = 1, getn(rows) do
		local row = rows[i]
		E:Print(format("%d. %s  %.0f  |cff999999%.0f%%|r", i, row.name, row.threat, row.share * 100))

		--What that number was built from, read at the same instant as the number itself.
		--Comparing this against the damage meter cannot work -- the two are read seconds
		--apart with a fight still running, so a discrepancy is equally explained by the
		--model being wrong or by you having killed more things in between. Shown inline,
		--a single reading checks itself: for a warlock, with no stance and no modelled
		--talents, the ratio should sit at 1.0 and anything else is a real finding.
		--The ratio measures how damage and healing were converted into threat, so the
		--flat component comes out of the numerator first. Left in, it reads as an error
		--on precisely the actors that carry flat threat -- a Voidwalker showed 1.94 when
		--its damage conversion was in fact exactly 1.00, and the whole 0.94 was Torment
		--working as designed. Flat is printed beside it because it is the guessed part
		--and deserves to be looked at, not because it belongs in the ratio.
		local base = row.damage + (row.healing * 0.5)
		E:Print(format("      |cff999999from %.0f dmg + %.0f heal + %.0f flat -- ratio %.2f|r",
			row.damage, row.healing, row.flat,
			(base > 0) and ((row.threat - row.flat) / base) or 0))
	end
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
	local frame = _G["OctoTWTMain"]

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
		(OctoTWT_CONFIG and OctoTWT_CONFIG.windowScale) or 0))

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

	if OctoTWT_CONFIG then
		E:Print(format("config: visible %s, hideOOC %s, showInCombat %s, bars %d, bar height %d",
			tostring(OctoTWT_CONFIG.visible), tostring(OctoTWT_CONFIG.hideOOC),
			tostring(OctoTWT_CONFIG.showInCombat), OctoTWT_CONFIG.visibleBars or 0,
			OctoTWT_CONFIG.barHeight or 0))
	else
		E:Print("|cffff0000OctoTWT_CONFIG is nil|r - saved variables never loaded.")
	end

	--An empty window has two completely different causes that look identical from the
	--outside: nobody ever asked the server, or the server was asked and said nothing.
	--Threat on this client is entirely server-side, so without these two counters there
	--is no way to tell them apart and no way to know which half to go and fix.
	local TM = E:GetModule("ThreatMeter", true)
	if TM and TM.ThreatTraffic then
		local sent, replies, last, failures = TM:ThreatTraffic()
		local verdict = ""
		if failures > 0 then
			--the client refusing the send is a third cause, and it looks exactly like
			--the other two from the outside
			verdict = format(" |cffff0000-- %d send(s) rejected by the client|r", failures)
		elseif sent == 0 then
			verdict = " |cffff0000-- never asked; nothing will ever appear|r"
		elseif replies == 0 then
			verdict = " |cffff0000-- asked, but the server has not answered|r"
		elseif last then
			verdict = format(" |cff00ff00-- last reply %.0fs ago|r", GetTime() - last)
		end

		E:Print(format("traffic: %d sent, %d received%s", sent, replies, verdict))
	end

	local solo = (GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0)
	local soloState
	if not (OctoTWT_CONFIG and OctoTWT_CONFIG.soloThreat ~= false) then
		soloState = "|cffff9900off|r"
	elseif TM and TM.SoloGaveUp and TM:SoloGaveUp() then
		soloState = "|cffff9900stopped -- this server does not answer them|r"
	else
		soloState = "|cff00ff00on|r"
	end

	E:Print(format("group: %s, solo threat requests %s", solo and "solo" or "grouped", soloState))
end

--Puts the window back in the middle of the screen at a sane size, for when the saved
--position or scale has put it somewhere unreachable. /twt has no equivalent.
function E:ThreatReset()
	local frame = _G["OctoTWTMain"]
	if not frame then
		E:Print("|cffff0000TWTMain does not exist.|r")
		return
	end

	if OctoTWT_CONFIG then
		OctoTWT_CONFIG.visible = true
		OctoTWT_CONFIG.windowScale = 1
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

--Aura filter lists. The options GUI has no page for these -- E:SetToFilterConfig is called
--by the Filters buttons in Config/UnitFrames.lua and defined nowhere, it did not survive
--the merge of the old config addon -- so without this there is no way to see what is in a
--list, and no way at all to undo a Shift + Right-Click blacklist short of editing
--SavedVariables while logged out.
local function ResolveFilter(name)
	local filters = E.global.unitframe.aurafilters
	if not (filters and name) then return end

	if filters[name] then return name end

	--typing the name in full, in the right case, for something with no completion is a
	--poor deal; match case-insensitively instead
	local wanted = lower(name)
	for key in pairs(filters) do
		if lower(key) == wanted then return key end
	end
end

local function FilterNames()
	local out, n = "", 0
	for key in pairs(E.global.unitframe.aurafilters) do
		out = (n == 0) and key or (out..", "..key)
		n = n + 1
	end

	return out
end

function E:FilterCommand(msg)
	local filters = E.global.unitframe.aurafilters
	if not filters then
		E:Print("No aura filters are defined.")
		return
	end

	local name, rest = match(msg or "", "^%s*(%S*)%s*(.-)%s*$")
	if not name or name == "" then
		--Slashes, not pipes: `|` is the chat escape character, so "add|remove|clear" loses
		--the "r" to a |r colour reset and prints as "addemove|clear". Doubling to `||`
		--works too, but reads worse in the source than it does on screen.
		E:Print("Aura filters. Usage: /octoui-filter <filter> [add / remove / clear] [spell name]")
		for key, filter in pairs(filters) do
			local count = 0
			for _ in pairs(filter.spells or {}) do count = count + 1 end
			E:Print(format("  %s (%s) - %d spell(s)", key, filter.type or "?", count))
		end
		return
	end

	local key = ResolveFilter(name)
	if not key then
		E:Print(format("No filter called '%s'. Known: %s", name, FilterNames()))
		return
	end

	local filter = filters[key]
	filter.spells = filter.spells or {}

	local action, spell = match(rest or "", "^(%S*)%s*(.-)$")
	action = action and lower(action) or ""

	if action == "" or action == "list" then
		local count = 0
		for spellName, entry in pairs(filter.spells) do
			count = count + 1
			E:Print(format("  %s%s", spellName, entry.enable and "" or " |cff888888(disabled)|r"))
		end
		E:Print(format("%s (%s): %d spell(s)", key, filter.type or "?", count))
		return
	end

	if action == "clear" then
		local count = 0
		for _ in pairs(filter.spells) do count = count + 1 end
		filter.spells = {}
		E:Print(format("Cleared %d spell(s) from %s.", count, key))
	elseif action == "add" then
		if spell == "" then E:Print("Usage: /octoui-filter "..key.." add <spell name>") return end
		--Spell names are matched exactly against what the client reports, so they are
		--stored exactly as typed rather than normalised.
		filter.spells[spell] = {["enable"] = true, ["priority"] = 0, ["stackThreshold"] = 0}
		E:Print(format("Added '%s' to %s.", spell, key))
	elseif action == "remove" or action == "delete" then
		if spell == "" then E:Print("Usage: /octoui-filter "..key.." remove <spell name>") return end
		if filter.spells[spell] == nil then
			E:Print(format("'%s' is not in %s. /octoui-filter %s lists what is.", spell, key, key))
			return
		end
		filter.spells[spell] = nil
		E:Print(format("Removed '%s' from %s.", spell, key))
	else
		E:Print(format("Unknown action '%s'. Use add, remove, clear or list.", action))
		return
	end

	local UF = E:GetModule("UnitFrames", true)
	if UF then
		--the raid debuff element only reads its list when the headers are rebuilt
		if UF.UpdateAllHeaders then UF:UpdateAllHeaders() end
		if UF.Update_AllFrames then UF:Update_AllFrames() end
	end

	--The standalone player buff and debuff panels are a separate module and rebuild only
	--on PLAYER_AURAS_CHANGED, so without this a filter edit would not show until the next
	--time an aura happened to change.
	local A = E:GetModule("Auras", true)
	if A and A.RefreshHeaders then A:RefreshHeaders() end
end

--Why the standalone buff and debuff panels are or are not on screen. Every guess about
--this has been wrong so far: it is not the enable flag, not the MMHolder anchor and not
--the growth-direction tables. Report the frames' actual state rather than reasoning about
--what it ought to be.
local function ReportAuraHeader(label, frame)
	if not frame then
		E:Print(format("  %s: FRAME DOES NOT EXIST", label))
		return
	end

	local point, relativeTo, relativePoint, x, y = frame:GetPoint()
	local relName = relativeTo and relativeTo.GetName and relativeTo:GetName() or tostring(relativeTo)

	E:Print(format("  %s: shown=%s alpha=%.2f scale=%.2f size=%dx%d",
		label, tostring(frame:IsShown()), frame:GetAlpha() or 0, frame:GetScale() or 0,
		frame:GetWidth() or 0, frame:GetHeight() or 0))

	if point then
		E:Print(format("    anchored %s to %s %s at %d, %d", point, relName, tostring(relativePoint), x or 0, y or 0))
	else
		E:Print("    |cffff0000NO ANCHOR|r - a frame with no point never draws")
	end

	--GetLeft is nil for a frame that is hidden or not yet laid out, so a real rect here is
	--also proof the frame has actually been positioned.
	local left, bottom = frame:GetLeft(), frame:GetBottom()
	if left and bottom then
		E:Print(format("    rect left=%d bottom=%d (screen is %dx%d)",
			left, bottom, GetScreenWidth(), GetScreenHeight()))
	else
		E:Print("    |cffff0000NO RECT|r - not laid out")
	end

	local shown, total = 0, 0
	local i, button = 1
	button = _G[frame:GetName().."AuraButton"..i]
	while button do
		total = total + 1
		if button:IsShown() then shown = shown + 1 end
		i = i + 1
		button = _G[frame:GetName().."AuraButton"..i]
	end
	E:Print(format("    buttons: %d created, %d shown", total, shown))
end

function E:AuraReport()
	E:Print("Standalone buff/debuff panels:")
	E:Print(format("  private.auras.enable=%s disableBlizzard=%s  MMHolder=%s",
		tostring(E.private.auras.enable), tostring(E.private.auras.disableBlizzard),
		MMHolder and "exists" or "|cffff0000MISSING|r"))

	local A = E:GetModule("Auras", true)
	if not A then E:Print("  |cffff0000module not registered|r") return end
	if not A.db then E:Print("  |cffff0000A.db is nil - Initialize returned early or raised|r") return end

	--What the client says the player actually has, independent of any of our frames.
	local counts = {}
	local f
	for _, filter in pairs({"HELPFUL", "HARMFUL"}) do
		local n, idx = 0, 0
		while true do
			idx = GetPlayerBuff(n, filter)
			if not GetPlayerBuffTexture(idx) then break end
			n = n + 1
		end
		counts[filter] = n
	end
	E:Print(format("  client reports %d buff(s), %d debuff(s)", counts.HELPFUL, counts.HARMFUL))

	ReportAuraHeader("BuffFrame", A.BuffFrame)
	ReportAuraHeader("DebuffFrame", A.DebuffFrame)

	f = E.db.movers
	E:Print(format("  saved movers: BuffsMover=%s DebuffsMover=%s",
		(f and f.BuffsMover) or "none", (f and f.DebuffsMover) or "none"))
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
	self:RegisterChatCommand("octoui-dps", "MeterReport")
	self:RegisterChatCommand("octoui-threatmodel", "ThreatModelReport")
	self:RegisterChatCommand("octoui-filter", "FilterCommand")
	self:RegisterChatCommand("octoui-auras", "AuraReport")
	self:RegisterChatCommand("octoui-threatreset", "ThreatReset")

	if E:GetModule("ActionBars") and E.private.actionbar.enable then
		self:RegisterChatCommand("kb", E:GetModule("ActionBars").ActivateBindMode)
	end
end
