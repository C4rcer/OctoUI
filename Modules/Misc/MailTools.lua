local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local _G = _G
local format = string.format
local tostring, type = tostring, type
--WoW API / Variables
local CreateFrame = CreateFrame
local CheckInbox = CheckInbox
local GetContainerItemInfo = GetContainerItemInfo
local GetContainerNumSlots = GetContainerNumSlots
local GetInboxHeaderInfo = GetInboxHeaderInfo
local GetInboxItem = GetInboxItem
local GetInboxNumItems = GetInboxNumItems
local GetMoney = GetMoney
local GetTime = GetTime
local TakeInboxItem = TakeInboxItem
local TakeInboxMoney = TakeInboxMoney

--[[
	Take All, for the mailbox. Open item 18.

	WRITTEN FROM SCRATCH, AND IT HAD TO BE. TurtleMail is the addon this replaces, and it
	carries NO LICENCE -- checked 2026-08-06, not assumed: no LICENSE file, no licence
	field in its .toc (only `## Author: shirsig/sica`), nothing in its README, and only a
	FUNDING.yml in .github. Upstream is github.com/sica42/TurtleMail. **No licence means no
	permission**; a missing licence is restrictive, not permissive. Its behaviour was read
	to decide what this should do. None of its implementation was.

	The shape of vanilla mail makes this smaller than it looks: TakeInboxMoney(index) and
	TakeInboxItem(index) over GetInboxNumItems() is the whole of it. What takes the care is
	everything around those two calls.

	THREE RULES, in the order they matter:

	1. **A cash-on-delivery letter is never touched.** Taking a CoD attachment pays the
	   sender out of the player's own gold, immediately, with no confirmation and no way
	   for an addon to undo it. Every CoD letter is skipped and counted, and the summary
	   says how many. This is the one thing in here that could cost real money and it is
	   the one thing that is not automated.

	2. **Every step waits for the server.** TakeInboxItem is asynchronous: the inbox does
	   not change until MAIL_INBOX_UPDATE comes back. Firing on a fixed timer instead means
	   re-issuing an action the server has not processed yet, which is how a naive loop
	   drops attachments on the floor. So one action goes out, and the next waits for the
	   event -- with a floor interval on top of that, and a timeout so a lost reply stops
	   the run instead of hanging it.

	3. **A silent refusal must stop the run, not spin.** TakeInboxItem does nothing at all
	   when the bags are full -- no error, no event, nothing. Bag space is checked before
	   every attachment, and on top of that any action repeated with no change stops the
	   whole thing. Belt and braces, because that is the class of bug this codebase froze
	   the client with once already.

	Deliberately NOT here: deleting letters. The server removes a letter that has nothing
	left in it and no body text; one with text stays, and destroying that is a decision for
	the player, not for a button. Sending mail is the other half of item 18 and is separate.
]]

--Bottom centre of the inbox pane, level with the Prev/Next row -- the widest gap on the
--frame, since those two sit hard left and hard right of it.
--
--Two wrong versions before this one, both from anchoring to a frame instead of to what is
--on screen. First the title bar beside the close button, which landed ON the close button.
--Then BOTTOM-to-BOTTOM on InboxFrame, which put it about sixteen pixels right of centre,
--because InboxFrame's extents are not the pane the eye sees. See PlaceButton below: it now
--takes the midpoint of Prev and Next, which ARE the row.
local BUTTON_WIDTH, BUTTON_HEIGHT = 76, 20
local BUTTON_Y_FALLBACK = 14

--A letter carries one attachment on vanilla and more on later Turtle patches, so the
--attachment slot is looked up rather than assumed. Both forms of the call are compatible:
--vanilla ignores a second argument, so TakeInboxItem(i, 1) is correct either way.
local function AttachmentSlots()
	local slots = _G.ATTACHMENTS_MAX_RECEIVE
	if type(slots) == "number" and slots > 1 then return slots end
	return 1
end

local function FreeBagSlots()
	local free = 0
	for bag = 0, 4 do
		local slots = GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			if not GetContainerItemInfo(bag, slot) then free = free + 1 end
		end
	end

	return free
end

--What is still sitting in the inbox, right now.
--
--The summary used to count what was REQUESTED: money was added to the total on the line
--before TakeInboxMoney and the item count incremented straight after TakeInboxItem. Both
--are requests, not receipts. Close the mailbox mid-run -- which is a supported thing to do
--and stops the run cleanly -- and the last request is counted but never lands. Reported on
--2026-08-07: the summary claimed 1g 7s 80c, exactly two Felcloth sales, while one of them
--was still in the box.
--
--Counting the difference between the start and the end sidesteps all of it. Money comes
--from GetMoney, which is the player's actual purse and cannot be wrong; attachments are
--recounted across the whole inbox, which is immune to the index shifting as letters are
--consumed and removed.
local function CountAttachments()
	local total = 0
	for i = 1, (GetInboxNumItems() or 0) do
		for slot = 1, AttachmentSlots() do
			if GetInboxItem(i, slot) then total = total + 1 end
		end
	end

	return total
end

local takeAll = {}
local takeButton, eventFrame

--The mailbox in the only terms that say whether anything is actually happening. Used by the
--stall detector in TakeAll_OnUpdate; see the note there for why an index cannot serve.
local function Progress()
	return format("%d|%d|%d", GetInboxNumItems() or 0, CountAttachments(), GetMoney())
end

local function Summary()
	--Attachments and money, not letters: a letter carrying both is two actions and counting
	--those as two letters would be a lie. Said as one line, because the interesting part is
	--rarely the count -- "and 2 cash-on-delivery letters left alone" is the bit worth
	--reading, and it is the bit a silent take-all would never tell anyone.
	--Both are measured, never accumulated from requests. Clamped at zero because mail
	--arriving mid-run can legitimately push the attachment count back up, and "took -1
	--attachments" helps nobody.
	local gained = GetMoney() - (takeAll.startMoney or GetMoney())
	if gained < 0 then gained = 0 end

	local taken = (takeAll.startAttachments or 0) - CountAttachments()
	if taken < 0 then taken = 0 end

	local text = format(L["MAIL_TAKEALL_DONE"], taken, E:FormatMoney(gained, "SMART"))

	if (takeAll.skippedCod or 0) > 0 then
		text = text.." "..format(L["MAIL_TAKEALL_COD"], takeAll.skippedCod)
	end

	return text
end

local function StopTakeAll(reason)
	if not takeAll.active then return end
	takeAll.active = false

	if eventFrame then eventFrame:SetScript("OnUpdate", nil) end
	if takeButton then takeButton:SetText(L["Take All"]) end

	local text = Summary()
	if reason then text = text.." "..reason end
	E:Print(text)
end

--The next thing to do, or nil when there is nothing left to do. Rescanned from the top on
--every step rather than walked once, because indices shift under us: the server removes a
--letter the moment it is empty, and mail can arrive mid-run.
local function NextAction()
	local num = GetInboxNumItems() or 0
	local cod = 0

	for i = 1, num do
		local _, _, _, _, money, codAmount, _, hasItem = GetInboxHeaderInfo(i)

		if codAmount and codAmount > 0 then
			cod = cod + 1
		else
			if money and money > 0 then return i, "money", nil, cod end

			if hasItem then
				for slot = 1, AttachmentSlots() do
					if GetInboxItem(i, slot) then return i, "item", slot, cod end
				end
			end
		end
	end

	return nil, nil, nil, cod
end

local function TakeAll_OnUpdate()
	if not takeAll.active then
		this:SetScript("OnUpdate", nil)
		return
	end

	--Waiting on the server. The deadline is what separates "slow" from "never coming".
	if takeAll.waiting then
		if GetTime() > takeAll.deadline then
			StopTakeAll(L["MAIL_TAKEALL_TIMEOUT"])
		end
		return
	end

	if GetTime() < takeAll.nextAt then return end

	local index, kind, slot, cod = NextAction()
	takeAll.skippedCod = cod

	if not index then
		StopTakeAll(nil)
		return
	end

	--Any action asked for twice running with nothing changing in between means the request
	--is being refused silently. Stop rather than spin: this client gives no error for a
	--refused take, and a loop that cannot tell the difference is exactly the shape that
	--froze the client in July.
	--
	--MEASURED ON PROGRESS, NOT ON THE IDENTITY OF THE NEXT ACTION.
	--
	--The old test compared `index|kind|slot`, and that string is IDENTICAL on every
	--successful step of an ordinary run: the server deletes a letter the moment it is
	--emptied, so the next letter slides down to index 1 and the next action is `1|item|1`
	--all over again. The counter therefore incremented on SUCCESS, and every take-all
	--stopped after exactly three attachments claiming it had stalled.
	--
	--Inbox size, attachment count and purse together move on any action that did anything:
	--money raises the purse, a taken attachment lowers the count, an emptied letter lowers
	--the size. All three unchanged across a completed round trip is a real silent refusal,
	--whatever the indices happen to say.
	local progress = Progress()
	if progress == takeAll.lastProgress then
		takeAll.stalled = (takeAll.stalled or 0) + 1
		if takeAll.stalled >= 3 then
			StopTakeAll(L["MAIL_TAKEALL_STALLED"])
			return
		end
	else
		takeAll.lastProgress = progress
		takeAll.stalled = 0
	end

	if kind == "money" then
		TakeInboxMoney(index)
	else
		--Checked before every attachment rather than once at the start, because the run
		--itself is what fills the bags. Conservative on purpose: an item that would have
		--stacked into a partial stack needs no free slot, so this can stop a little early.
		--Stopping early is recoverable; a silent no-op loop is not.
		if FreeBagSlots() < 1 then
			StopTakeAll(L["MAIL_TAKEALL_BAGS_FULL"])
			return
		end
		TakeInboxItem(index, slot)
	end

	takeAll.waiting = true
	takeAll.deadline = GetTime() + 5
end

local function StartTakeAll()
	if takeAll.active then
		StopTakeAll(L["MAIL_TAKEALL_CANCELLED"])
		return
	end

	if not (_G.MailFrame and _G.MailFrame:IsShown()) then return end

	takeAll.active = true
	takeAll.waiting = false
	takeAll.nextAt = 0
	takeAll.lastProgress = nil
	takeAll.stalled = 0
	takeAll.skippedCod = 0
	takeAll.startMoney = GetMoney()
	takeAll.startAttachments = CountAttachments()

	if takeButton then takeButton:SetText(L["Stop"]) end
	if CheckInbox then CheckInbox() end

	eventFrame:SetScript("OnUpdate", TakeAll_OnUpdate)
end

local function BuildButton()
	if takeButton then return end

	--Parented to the INBOX PANE, not to MailFrame. Parenting it to the frame left it on
	--screen over the Send Mail tab, sitting across the postage box and the Send button --
	--a take-all button has no meaning there, and hiding it by hand on every tab change is
	--work the frame hierarchy already does. InboxFrame hides when the tab switches and its
	--children go with it.
	local parent = _G.InboxFrame or _G.MailFrame
	if not parent then return end

	--CreateFrame does not fail on a name already taken: it builds a second frame, rebinds
	--the global to it and ORPHANS the first, which stays on screen and can no longer be
	--reached by name. Reuse rather than risk it. See the gotchas list in HANDOFF.
	local b = _G.ElvUI_MailTakeAllButton
	if b then
		b:SetParent(parent)
	else
		b = CreateFrame("Button", "ElvUI_MailTakeAllButton", parent, "UIPanelButtonTemplate")
	end

	E:Width(b, BUTTON_WIDTH)
	E:Height(b, BUTTON_HEIGHT)
	b:SetText(L["Take All"])
	b:SetScript("OnClick", function() StartTakeAll() end)

	local skins = E:GetModule("Skins", true)
	if skins and skins.HandleButton then skins:HandleButton(b) end

	takeButton = b
	M.MailTakeAllButton = b
end

--Centred between the Prev and Next buttons, and anchored to Prev so the vertical comes free.
--
--Centring on InboxFrame was the obvious thing and it was visibly wrong -- that frame's
--centre sits about sixteen pixels right of the pane the eye sees, for reasons not worth
--establishing. Prev and Next ARE the row, they sit hard left and hard right of it, and
--their midpoint is what "centred" means to anyone looking at the window. Measuring the two
--things being judged against removes the question of which frame counts as the pane.
--
--Raw SetPoint rather than E:Point: the offset is measured off frames already on screen, so
--it is already in the coordinate space SetPoint expects and E:Scale would move it.
local function PlaceButton()
	if not takeButton or takeButton.placed then return end

	local prev = _G.InboxPrevPageButton
	local nextPage = _G.InboxNextPageButton

	if prev and nextPage then
		--GetCenter answers nil for a frame that is hidden or has never been laid out, so a
		--failure here leaves `placed` false and the next MAIL_SHOW tries again.
		local px = prev:GetCenter()
		local nx = nextPage:GetCenter()

		if px and nx then
			takeButton:ClearAllPoints()
			takeButton:SetPoint("CENTER", prev, "CENTER", ((px + nx) / 2) - px, 0)
			takeButton.placed = true
			return
		end
	end

	--Nothing measurable yet. Roughly right and definitely visible, which is what makes a
	--failed measurement reportable rather than silent.
	local pane = _G.InboxFrame or _G.MailFrame
	if pane then
		takeButton:ClearAllPoints()
		takeButton:SetPoint("BOTTOM", pane, "BOTTOM", 0, BUTTON_Y_FALLBACK)
	end
end

local function UpdateButton()
	if not takeButton then return end

	if E.db.general.mailTakeAll then
		takeButton:Show()
	else
		takeButton:Hide()
		StopTakeAll(nil)
	end
end

--[[
	The inbox as this module sees it, letter by letter.

	This exists because the safety rule that matters most cannot be tested on this server:
	the user cannot send themselves a cash-on-delivery letter, so "does Take All really skip
	CoD" has no direct experiment. An untestable guard is a guard nobody can trust.

	So the guard is made inspectable instead. This prints the exact fields the decision is
	made on -- the CoD amount straight out of GetInboxHeaderInfo, and the verdict beside it
	-- for every letter in the box. It answers the question the moment a CoD letter arrives
	from anyone, and until then it at least proves the field is being read from the right
	position in the return list, which is the failure that would actually happen.

	It also reports the two client facts the implementation branches on, so they are checked
	from inside the feature rather than assumed.
]]
function M:MailReport()
	local num = GetInboxNumItems() or 0

	E:Print(format(L["MAIL_REPORT_HEADER"], num, AttachmentSlots(),
		type(_G.AutoLootMailItem) == "function" and L["present"] or L["absent"]))

	if num == 0 then return end

	for i = 1, num do
		local _, _, sender, subject, money, codAmount, _, hasItem = GetInboxHeaderInfo(i)

		local attachments = 0
		for slot = 1, AttachmentSlots() do
			if GetInboxItem(i, slot) then attachments = attachments + 1 end
		end

		local verdict
		if codAmount and codAmount > 0 then
			verdict = "|cffff8000"..format(L["MAIL_REPORT_SKIP_COD"], E:FormatMoney(codAmount, "SMART")).."|r"
		elseif (money and money > 0) or attachments > 0 then
			verdict = "|cff00ff00"..L["MAIL_REPORT_TAKE"].."|r"
		else
			verdict = "|cffa0a0a0"..L["MAIL_REPORT_NOTHING"].."|r"
		end

		E:Print(format("  %d. %s -- %s | %s %s | %s",
			i, tostring(sender or "?"), tostring(subject or ""),
			E:FormatMoney(money or 0, "SMART"),
			format(L["MAIL_REPORT_ATTACHMENTS"], attachments, tostring(hasItem)),
			verdict))
	end
end

--[[
	THE MINIMAP MAIL ICON, which nothing else ever turns off.

	MiniMapMailFrame is driven by UPDATE_PENDING_MAIL. Captured with /oprobe on 2026-08-09,
	that event arrived exactly three times across a fifteen hour session -- once per login,
	immediately after PLAYER_ENTERING_WORLD, and never again. So the icon shows the state as
	it was at login, and a relog is the only thing that clears it. That is the whole bug.

	HasNewMail() is deliberately not consulted: it reads the same server-side flag that is not
	being cleared, so it would agree with the stuck icon. The INBOX is authoritative while the
	mailbox is open -- zero items means there is no mail, whatever the flag says.

	This only ever HIDES. Showing the icon stays Blizzard's business on UPDATE_PENDING_MAIL;
	an addon forcing it visible would resurrect it for mail that is not there.
]]
local lastInboxCount

local function RefreshMailIcon()
	--Not `not lastInboxCount`: nil means the inbox has never been read this session, which is
	--not the same as it being empty and must not hide anything.
	if lastInboxCount ~= 0 then return end

	if MiniMapMailFrame and MiniMapMailFrame:IsShown() then
		MiniMapMailFrame:Hide()
	end
end

--ASK THE SERVER AGAIN once the mailbox is shut.
--
--Hiding the icon locally fixes what is on screen but not what the client believes, so the
--next thing to consult the mail flag disagrees with the minimap. CheckInbox() is the request
--the client itself uses to poll for mail: the server answers with MAIL_INBOX_UPDATE, and
--with the real state rather than the one it has been sitting on since login.
--
--DELAYED, because the take and the close race. Sending the request in the same frame as
--MAIL_CLOSED asks the server about an inbox it has not finished emptying, and it answers
--with the item still in it -- which is the stuck icon all over again, just with an extra
--round trip. A second is far longer than the round trip and far shorter than anyone notices.
--
--No loop: the reply lands on MAIL_INBOX_UPDATE below, which reads the count and does not
--send anything further.
local CHECK_DELAY = 1

local function PulseInboxCheck()
	if type(CheckInbox) == "function" then
		CheckInbox()
	end
end

function M:LoadMailTools()
	if eventFrame then return end

	eventFrame = CreateFrame("Frame", "ElvUI_MailTools", UIParent)
	eventFrame:RegisterEvent("MAIL_SHOW")
	eventFrame:RegisterEvent("MAIL_CLOSED")
	eventFrame:RegisterEvent("MAIL_INBOX_UPDATE")
	eventFrame:SetScript("OnEvent", function()
		if event == "MAIL_INBOX_UPDATE" then
			--Read while the mailbox is open, which is the only time the inbox is valid.
			--Taking the last letter fires this with zero items, and that is the moment the
			--icon should go.
			lastInboxCount = GetInboxNumItems() or 0
			RefreshMailIcon()

			--The server has answered. Release the step and let the interval decide when the
			--next one goes out.
			if takeAll.active and takeAll.waiting then
				takeAll.waiting = false
				takeAll.nextAt = GetTime() + (E.db.general.mailTakeAllInterval or 0.3)
			end
		elseif event == "MAIL_CLOSED" then
			--Again on close, from the remembered count rather than a fresh read: the inbox
			--is no longer valid here, and the final update can arrive after the last take.
			RefreshMailIcon()

			--And ask the server to tell us the truth, so the client's own flag catches up
			--rather than only the icon.
			E:Delay(CHECK_DELAY, PulseInboxCheck)

			--Walking away from the mailbox ends the run. Further calls would fail anyway,
			--and the letters already emptied are still emptied.
			StopTakeAll(nil)
		else
			BuildButton()
			PlaceButton()
			UpdateButton()
		end
	end)

	M.UpdateMailButton = UpdateButton
	M.StartMailTakeAll = StartTakeAll

	--The mail frame is part of FrameXML rather than a load-on-demand addon, so it exists
	--already and the button can be built now. MAIL_SHOW is the retry, and is where the
	--placement actually lands -- nothing has a rect until the frame has been shown once.
	BuildButton()
	PlaceButton()
	UpdateButton()
end
