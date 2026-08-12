local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local find, match = string.find, string.match
local pairs, unpack, ipairs, next, tonumber = pairs, unpack, ipairs, next, tonumber
local tinsert = table.insert
--WoW API / Variables
local CursorOnUpdate = CursorOnUpdate
local GetTime = GetTime
local DressUpItemLink = DressUpItemLink
local GetLootRollItemInfo = GetLootRollItemInfo
local GetLootRollItemLink = GetLootRollItemLink
local GetLootRollTimeLeft = GetLootRollTimeLeft
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown
local ResetCursor = ResetCursor
local RollOnLoot = RollOnLoot
local ShowInspectCursor = ShowInspectCursor
local CUSTOM_CLASS_COLORS = CUSTOM_CLASS_COLORS
local ITEM_QUALITY_COLORS = ITEM_QUALITY_COLORS
local RAID_CLASS_COLORS = RAID_CLASS_COLORS

local pos = "TOP"
local cancelled_rolls = {}
local FRAME_WIDTH, FRAME_HEIGHT = 328, 28
M.RollBars = {}

--HOW MUCH BIGGER THAN THE ORIGINAL. One number, applied with SetScale on the whole roll
--bar, so the icon, the roll buttons, the timer bar and every fontstring grow together.
--Rescaling the pieces individually would mean touching nine sizes and six anchor offsets
--and getting the fonts wrong anyway, since they are templated rather than set here.
local ROLL_SCALE = 2

--ITS OWN ANCHOR, rather than hanging off AlertFrameHolder.
--
--Loot rolls used to share the alert frames' holder, which sits at the top of the screen and
--carries the achievement and alert popups with it -- so there was no way to move the rolls
--to the middle without dragging those there too. This is a separate frame with a separate
--mover, defaulting to the centre of the screen.
--
--A NEW mover has no saved position, so this default applies immediately. That is only true
--the first time: from now on E.db.movers owns it, and changing the SetPoint below will do
--nothing until the mover is reset. Anchored CENTER because the bars hang downward from it,
--so the top edge is the one that should stay put.
local LootRollHolder = CreateFrame("Frame", "LootRollHolder", E.UIParent)
LootRollHolder:SetWidth(FRAME_WIDTH * ROLL_SCALE)
LootRollHolder:SetHeight(FRAME_HEIGHT * ROLL_SCALE)
LootRollHolder:SetPoint("CENTER", E.UIParent, "CENTER", 0, 0)

local locale = GetLocale()
local rollpairs = locale == "deDE" and {
	["(.*) würfelt nicht für: (.+|r)$"] = "pass",
	["(.*) hat für (.+) 'Gier' ausgewählt"] = "greed",
	["(.*) hat für (.+) 'Bedarf' ausgewählt"] = "need",
} or locale == "frFR" and {
	["(.*) a passé pour : (.+)"] = "pass",
	["(.*) a choisi Cupidité pour : (.+)"] = "greed",
	["(.*) a choisi Besoin pour : (.+)"] = "need",
} or locale == "zhTW" and {
	["(.*)放棄了:(.+)"] = "pass",
	["(.*)選擇了貪婪:(.+)"] = "greed",
	["(.*)選擇了需求:(.+)"] = "need",
} or locale == "ruRU" and {
	["(.*) отказывается от предмета (.+)%."] = "pass",
	["Разыгрывается: (.+)%. (.*): \"Не откажусь\""] = "greed",
	["Разыгрывается: (.+)%. (.*): \"Мне это нужно\""] = "need",
} or locale == "koKR" and {
	["(.*)님이 주사위 굴리기를 포기했습니다: (.+)"] = "pass",
	["(.*)님이 차비를 선택했습니다: (.+)"] = "greed",
	["(.*)님이 입찰을 선택했습니다: (.+)"] = "need",
} or locale == "esES" and {
	["^(.*) pasó de: (.+|r)$"] = "pass",
	["(.*) eligió Codicia para: (.+)"] = "greed",
	["(.*) eligió Necesidad para: (.+)"] = "need",
} or locale == "esMX" and {
	["^(.*) pasó de: (.+|r)$"] = "pass",
	["(.*) eligió Codicia para: (.+)"] = "greed",
	["(.*) eligió Necesidad para: (.+)"] = "need",
} or {
	["^(.*) passed on: (.+|r)$"] = "pass",
	["(.*) has selected Greed for: (.+)"] = "greed",
	["(.*) has selected Need for: (.+)"] = "need",
}

--[[
	Retiring a bar, which is also what frees it for the next roll.

	GetFrame reuses a bar only when its rollID is nil, so anything that hides one without
	clearing that leaks it: the bar is invisible, still counted in M.RollBars, and never
	used again. Every path that finishes with a bar goes through here for that reason.
]]
local function RetireFrame(f)
	if not f then return end

	f.rollID = nil
	f.time = nil
	f.expires = nil
	f:Hide()
end

--Called from AutoRoll as well, which knows a rollID but not which bar carries it.
function M:RetireRollBar(rollID)
	if not rollID then return end

	for _, f in ipairs(M.RollBars) do
		if f.rollID == rollID then RetireFrame(f) end
	end
end

--The bar goes when the roll is cast. There is nothing left for it to ask, which is what
--the default UI does too -- and without this nothing retires a bar you rolled on, so they
--stack up one per drop for the rest of the run.
local function ClickRoll(frame)
	local parent = frame.parent
	RollOnLoot(parent.rollID, frame.rolltype)
	RetireFrame(parent)
end

local function HideTip() GameTooltip:Hide() end
local function HideTip2() GameTooltip:Hide() ResetCursor() end

local rolltypes = {"need", "greed", [0] = "pass"}
local function SetTip(frame)
	GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
	GameTooltip:SetText(frame.tiptext)
	if frame:IsEnabled() == 0 then
		GameTooltip:AddLine("|cffff3333"..L["Can't Roll"])
	end

	for name, tbl in pairs(frame.parent.rolls) do
		if tbl[1] == rolltypes[frame.rolltype] and tbl[2] then
			local classColor = CUSTOM_CLASS_COLORS and CUSTOM_CLASS_COLORS[tbl[2]] or RAID_CLASS_COLORS[tbl[2]]
			GameTooltip:AddLine(name, classColor.r, classColor.g, classColor.b)
		end
	end
	GameTooltip:Show()
end

local function SetItemTip(frame)
	if not frame.link then return end

	GameTooltip:SetOwner(frame, "ANCHOR_TOPLEFT")
	GameTooltip:SetHyperlink(match(frame.link, "item[%-?%d:]+"))
	-- if IsShiftKeyDown() then
	-- 	GameTooltip_ShowCompareItem()
	-- end
	if IsControlKeyDown() then
		ShowInspectCursor()
	else
		ResetCursor()
	end
end

local function ItemOnUpdate(self)
	-- if IsShiftKeyDown() then
	-- 	GameTooltip_ShowCompareItem()
	-- end
	CursorOnUpdate(self)
end

local function LootClick(frame)
	if IsControlKeyDown() then
		DressUpItemLink(frame.link)
	elseif IsShiftKeyDown() then
		ChatEdit_InsertLink(frame.link)
	end
end

local function OnEvent(frame)
	local rollID = arg1
	cancelled_rolls[rollID] = true
	if frame.rollID ~= rollID then return end

	RetireFrame(frame)
end

local function StatusUpdate(frame)
	local parent = frame.parent
	if not parent.rollID then return end

	local t = GetLootRollTimeLeft(parent.rollID)

	--Retired on the wall clock as well, because neither of the two things that used to end
	--a bar can be relied on here: CANCEL_LOOT_ROLL is the server's to send, and the huge
	--return value tested below is a later-client habit this one may not share. A roll
	--cannot outlive its own length, and that length came from the event itself, so this
	--needs nothing from the client to be right. The margin keeps it behind the real end.
	if t > 1000000000 or (parent.expires and GetTime() > parent.expires) then
		RetireFrame(parent)
		return
	end

	local perc = t / parent.time
	E:Point(frame.spark, "CENTER", frame, "LEFT", perc * frame:GetWidth(), 0)
	frame:SetValue(t)
end

local function CreateRollButton(parent, ntex, ptex, htex, rolltype, tiptext, point, relativeFrame, relativePoint, ofsx, ofsy)
	local f = CreateFrame("Button", nil, parent)
	E:Point(f, point, relativeFrame, relativePoint, ofsx, ofsy)
	E:Size(f, FRAME_HEIGHT - 4)
	f:SetNormalTexture(ntex)
	if ptex then f:SetPushedTexture(ptex) end
	f:SetHighlightTexture(htex)
	f.rolltype = rolltype
	f.parent = parent
	f.tiptext = tiptext
	f:SetScript("OnEnter", function() SetTip(f) end)
	f:SetScript("OnLeave", HideTip)
	f:SetScript("OnClick", function() ClickRoll(f) end)
	local txt = f:CreateFontString(nil, nil)
	E:FontTemplate(txt, nil, nil, "OUTLINE")
	E:Point(txt, "CENTER", 0, rolltype == 2 and 1 or rolltype == 0 and -1.2 or 0)
	return f, txt
end

function M:CreateRollFrame()
	local frame = CreateFrame("Frame", nil, E.UIParent)
	E:Size(frame, FRAME_WIDTH, FRAME_HEIGHT)
	--Scales the whole widget tree -- icon, buttons, timer bar, fonts -- in one call, so the
	--layout below stays in the original units and does not have to be re-derived.
	frame:SetScale(ROLL_SCALE)
	E:SetTemplate(frame, "Default")
	frame:SetScript("OnEvent", function() OnEvent(frame) end)
	frame:RegisterEvent("CANCEL_LOOT_ROLL")
	frame:Hide()

	local button = CreateFrame("Button", nil, frame)
	E:Point(button, "RIGHT", frame, "LEFT", -(E.Spacing*3), 0)
	E:Size(button, FRAME_HEIGHT - (E.Border * 2))
	E:CreateBackdrop(button, "Default")
	button:SetScript("OnEnter", function() SetItemTip(button) end)
	button:SetScript("OnLeave", HideTip2)
	button:SetScript("OnUpdate", function() ItemOnUpdate(button) end)
	button:SetScript("OnClick", function() LootClick(button) end)
	frame.button = button

	button.icon = button:CreateTexture(nil, "OVERLAY")
	button.icon:SetAllPoints()
	button.icon:SetTexCoord(unpack(E.TexCoords))

	local tfade = frame:CreateTexture(nil, "BORDER")
	E:Point(tfade, "TOPLEFT", frame, "TOPLEFT", 4, 0)
	E:Point(tfade, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 0)
	tfade:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
	tfade:SetBlendMode("ADD")
	tfade:SetGradientAlpha("VERTICAL", .1, .1, .1, 0, .1, .1, .1, 0)

	local status = CreateFrame("StatusBar", nil, frame)
	E:SetInside(status)
	status:SetScript("OnUpdate", function() StatusUpdate(status) end)
	status:SetFrameLevel(status:GetFrameLevel() - 1)
	status:SetStatusBarTexture(E.media.normTex)
	E:RegisterStatusBar(status)
	status:SetStatusBarColor(.8, .8, .8, .9)
	status.parent = frame
	frame.status = status

	status.bg = status:CreateTexture(nil, "BACKGROUND")
	status.bg:SetAlpha(0.1)
	status.bg:SetAllPoints()
	local spark = frame:CreateTexture(nil, "OVERLAY")
	E:Size(spark, 14, FRAME_HEIGHT)
	spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
	spark:SetBlendMode("ADD")
	status.spark = spark

	local need, needtext = CreateRollButton(frame, "Interface\\Buttons\\UI-GroupLoot-Dice-Up", "Interface\\Buttons\\UI-GroupLoot-Dice-Highlight", "Interface\\Buttons\\UI-GroupLoot-Dice-Down", 1, NEED, "LEFT", frame.button, "RIGHT", 5, -1)
	local greed, greedtext = CreateRollButton(frame, "Interface\\Buttons\\UI-GroupLoot-Coin-Up", "Interface\\Buttons\\UI-GroupLoot-Coin-Highlight", "Interface\\Buttons\\UI-GroupLoot-Coin-Down", 2, GREED, "LEFT", need, "RIGHT", 0, -1)
	local pass, passtext = CreateRollButton(frame, "Interface\\AddOns\\OctoUI\\media\\textures\\UI-GroupLoot-Pass-Up", nil, "Interface\\AddOns\\OctoUI\\media\\textures\\UI-GroupLoot-Pass-Down", 0, PASS, "LEFT", greed, "RIGHT", 0, 2)
	frame.needbutt, frame.greedbutt = need, greed
	frame.need, frame.greed, frame.pass = needtext, greedtext, passtext

	local bind = frame:CreateFontString()
	E:Point(bind, "LEFT", pass, "RIGHT", 3, 1)
	E:FontTemplate(bind, nil, nil, "OUTLINE")
	frame.fsbind = bind

	local loot = frame:CreateFontString(nil, "ARTWORK")
	E:FontTemplate(loot, nil, nil, "OUTLINE")
	E:Point(loot, "LEFT", bind, "RIGHT", 0, 0)
	E:Point(loot, "RIGHT", frame, "RIGHT", -5, 0)
	E:Size(loot, 200, 10)
	loot:SetJustifyH("LEFT")
	frame.fsloot = loot

	frame.rolls = {}

	return frame
end

local function GetFrame()
	for _, f in ipairs(M.RollBars) do
		if not f.rollID then
			return f
		end
	end

	local f = M:CreateRollFrame()
	--The first bar hangs off the holder; every later one off the bar before it.
	local anchor = next(M.RollBars) and M.RollBars[getn(M.RollBars)] or LootRollHolder
	if pos == "TOP" then
		E:Point(f, "TOP", anchor, "BOTTOM", 0, -4)
	else
		E:Point(f, "BOTTOM", anchor, "TOP", 0, 4)
	end

	tinsert(M.RollBars, f)

	return f
end

function M:START_LOOT_ROLL()
	if cancelled_rolls[rollID] then return end

	local f = GetFrame()
	f.rollID = arg1
	f.time = arg2

	--arg2 is the roll's length. Every 1.12 client seen gives it in milliseconds, but a
	--value that small could only be seconds, so both read the same rather than one being
	--assumed. Five seconds of margin so this never beats the roll's real end.
	local duration = tonumber(arg2) or 0
	if duration > 1000 then duration = duration / 1000 end
	f.expires = GetTime() + duration + 5
	for i in pairs(f.rolls) do f.rolls[i] = nil end
	f.need:SetText(0)
	f.greed:SetText(0)
	f.pass:SetText(0)

	local texture, name, _, quality, bindOnPickUp = GetLootRollItemInfo(arg1)
	f.button.icon:SetTexture(texture)
	f.button.link = GetLootRollItemLink(arg1)

	f.needbutt:Enable()
	f.greedbutt:Enable()
	SetDesaturation(f.needbutt:GetNormalTexture())
	SetDesaturation(f.greedbutt:GetNormalTexture())
	f.needbutt:SetAlpha(1)
	f.greedbutt:SetAlpha(1)

	f.fsbind:SetText(bindOnPickUp and "BoP" or "BoE")
	f.fsbind:SetVertexColor(bindOnPickUp and 1 or .3, bindOnPickUp and .3 or 1, bindOnPickUp and .1 or .3)

	local color = ITEM_QUALITY_COLORS[quality]
	f.fsloot:SetText(name)
	f.status:SetStatusBarColor(color.r, color.g, color.b, .7)
	f.status.bg:SetTexture(color.r, color.g, color.b)

	f.status:SetMinMaxValues(0, arg2)
	f.status:SetValue(arg2)

	E:Point(f, "CENTER", WorldFrame, "CENTER")
	f:Show()

	--A per-item rule from AutoRoll.lua wins over the blanket greed. Both handlers see this
	--same event and either may run first, so this asks whether a rule MATCHES rather than
	--whether one has already rolled -- otherwise the order would decide, and a green named
	--as a need would sometimes be greeded instead. Guarded because AutoRoll.lua is a newer
	--file: after a /reload this one is current while that one may not exist yet.
	local ruled = M.GetAutoRollRule and M:GetAutoRollRule(arg1)
	if E.db.general.autoRoll and not ruled and UnitLevel("player") == MAX_PLAYER_LEVEL and quality == 2 and not bindOnPickUp then
		RollOnLoot(arg1, 2)
		RetireFrame(f)
		return
	end

	--Retired here as well as from AutoRoll for the same ordering reason: whichever of the
	--two handlers runs second is the one that finds a bar to hide. AutoRoll running first
	--finds no bar at all, since this is what builds it.
	if ruled then
		RetireFrame(f)
	end
end

function M:ParseRollChoice(msg)
	if not msg then return end
	for i, v in pairs(rollpairs) do
		local _, _, playername, itemname = find(msg, i)
		if locale == "ruRU" and (v == "greed" or v == "need") then
			local temp = playername
			playername = itemname
			itemname = temp
		end
		if playername and itemname and playername ~= "Everyone" then return playername, itemname, v end
	end
end

function M:CHAT_MSG_LOOT()
	local playername, itemname, rolltype = self:ParseRollChoice(arg1)
	if playername and itemname and rolltype then
		for _, f in ipairs(M.RollBars) do
			if f.rollID and f.button.link == itemname and not f.rolls[playername] then
				f.rolls[playername] = { rolltype }
				f[rolltype]:SetText(tonumber(f[rolltype]:GetText()) + 1)
				return
			end
		end
--[[
		local _, class = UnitClass(playername)
		for _, f in ipairs(M.RollBars) do
			if f.rollID and f.button.link == itemname and not f.rolls[playername] then
				f.rolls[playername] = { rolltype, class }
				f[rolltype]:SetText(tonumber(f[rolltype]:GetText()) + 1)
				return
			end
		end
]]
	end

end

function M:LoadLootRoll()
	if not E.private.general.lootRoll then return end

	self:RegisterEvent("START_LOOT_ROLL")
	self:RegisterEvent("CHAT_MSG_LOOT")
	UIParent:UnregisterEvent("START_LOOT_ROLL")
	UIParent:UnregisterEvent("CANCEL_LOOT_ROLL")

	--Registered here rather than at file scope: CreateMover reads the frame's current point
	--as the mover's default, so it has to run after the SetPoint above and after E.db is
	--loaded. Rolls are no longer tied to the alert frames, so this can be dragged anywhere
	--without taking the achievement popups along with it.
	E:CreateMover(LootRollHolder, "LootRollMover", L["Loot Roll"])
end