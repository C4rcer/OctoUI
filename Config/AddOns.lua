local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local ACD = LibStub("AceConfigDialog-3.0");

--Cache global variables
--Lua functions
local sort = table.sort
local tinsert = table.insert
local ipairs = ipairs
local format = string.format
local find = string.find
--WoW API / Variables
local CreateFrame = CreateFrame
local HideUIPanel = HideUIPanel
local HookScript = HookScript
local ReloadUI = ReloadUI
local GetNumAddOns, GetAddOnInfo = GetNumAddOns, GetAddOnInfo
local EnableAddOn, DisableAddOn = EnableAddOn, DisableAddOn

--[[
	Enable and disable other addons without leaving the game.

	Three facts about 1.12 shape this whole page:

	  * EnableAddOn and DisableAddOn set a flag for the NEXT load. Nothing loads or
	    unloads now. Every row is therefore a PENDING state, and the page has to say
	    so rather than implying the change already happened.
	  * A folder added while the game is running cannot be enabled at all -- 1.12
	    indexes the AddOns directory at process start, so it is not in the list to
	    begin with. Enabling something that was not there at launch needs a full exit
	    of WoW.exe, not a reload, and this page is exactly where somebody finds that
	    out the hard way.
	  * GetAddOnInfo returns name, title, notes, enabled, loadable, reason, security.
	    `enabled` at position 4 is the flag this page edits, and it reports the pending
	    value the moment it is set -- which is why `get` needs no state of its own.

	Note Core/StatusReport.lua:21 reads that same call as `name, _, _, loadable, reason`,
	which is off by one against the above. Not touched from here, but it is wrong there.
]]

--Snapshot of what was enabled at load, so the page can report how many rows differ
--from the running UI rather than just how many are ticked.
local INITIAL = {}
do
	for i = 1, GetNumAddOns() do
		local name, _, _, enabled = GetAddOnInfo(i)
		if name then INITIAL[name] = (enabled and true or false) end
	end
end

local function IsBlizzard(name)
	return find(name, "^Blizzard_") and true or false
end

local function PendingCount()
	local pending = 0
	for i = 1, GetNumAddOns() do
		local name, _, _, enabled = GetAddOnInfo(i)
		if name and INITIAL[name] ~= (enabled and true or false) then
			pending = pending + 1
		end
	end
	return pending
end

--Chat line plus the popup. The line is what survives an accidental dismissal of the
--popup, and it names the addon, which the popup deliberately does not -- flipping six
--rows should not produce six identical dialogs saying nothing about which.
local function Announce(name, enabled)
	E:Print(format(enabled and "AddOn '%s' will be enabled when the UI next loads. Type /reload to do it now."
		or "AddOn '%s' will be disabled when the UI next loads. Type /reload to do it now.", name))
	E:StaticPopup_Show("ADDON_RL")
end

local function SetAddOn(name, value)
	if value then EnableAddOn(name) else DisableAddOn(name) end
	Announce(name, value)
end

local function OpenAddOnPage()
	--ToggleConfig would close an already-open window, which is the opposite of what a
	--button called AddOns should do.
	if not ACD.OpenFrames[E.ConfigAppName] then
		E:ToggleConfig()
	end
	ACD:SelectGroup(E.ConfigAppName, "addons")
end

--Sorted once at load. The list cannot change while the process lives, by the indexing
--rule above, so there is nothing to invalidate.
local ordered = {}
do
	for i = 1, GetNumAddOns() do
		local name, title = GetAddOnInfo(i)
		if name then
			tinsert(ordered, {name = name, title = (title and title ~= "" and title) or name})
		end
	end
	sort(ordered, function(a, b) return a.name < b.name end)
end

E.Options.args.addons = {
	type = "group",
	name = L["AddOns"],
	order = 6,
	args = {
		intro = {
			order = 1,
			type = "description",
			name = L["ADDONS_DESC"]
		},
		pending = {
			order = 2,
			type = "description",
			name = function()
				local pending = PendingCount()
				if pending == 0 then
					return L["No changes waiting. What is ticked here is what is running."]
				end
				return format(L["%d change(s) waiting for a reload."], pending)
			end
		},
		reload = {
			order = 3,
			type = "execute",
			name = L["Reload UI"],
			desc = L["Apply every change on this page now."],
			func = function() ReloadUI() end
		},
		bulk = {
			order = 4,
			type = "group",
			guiInline = true,
			name = L["All At Once"],
			args = {
				enableAll = {
					order = 1,
					type = "execute",
					name = L["Enable All"],
					confirm = true,
					confirmText = L["Enable every addon, including any you switched off deliberately?"],
					func = function()
						for _, entry in ipairs(ordered) do EnableAddOn(entry.name) end
						E:Print("Every addon enabled. Type /reload to apply.")
						E:StaticPopup_Show("ADDON_RL")
					end
				},
				disableOthers = {
					order = 2,
					type = "execute",
					name = L["Disable All Except OctoUI"],
					desc = L["Leaves OctoUI on so you can switch things back afterwards. The fastest way to find out what an addon is costing you."],
					confirm = true,
					confirmText = L["Switch off every addon except OctoUI?"],
					func = function()
						for _, entry in ipairs(ordered) do
							if entry.name ~= "OctoUI" then DisableAddOn(entry.name) end
						end
						E:Print("Every addon except OctoUI disabled. Type /reload to apply.")
						E:StaticPopup_Show("ADDON_RL")
					end
				}
			}
		},
		list = {
			order = 5,
			type = "group",
			guiInline = true,
			name = L["AddOns"],
			args = {}
		},
		blizzard = {
			order = 6,
			type = "group",
			guiInline = true,
			name = L["Blizzard"],
			args = {
				warning = {
					order = 1,
					type = "description",
					name = L["These load on demand when the game needs them. Switching one off removes the window it provides, so leave them alone unless that is the intention."]
				}
			}
		}
	}
}

do
	local listArgs = E.Options.args.addons.args.list.args
	local blizzArgs = E.Options.args.addons.args.blizzard.args

	for index, entry in ipairs(ordered) do
		local name = entry.name
		local option = {
			order = index + 10,
			type = "toggle",
			name = entry.title,
			desc = name,
			get = function()
				local _, _, _, enabled = GetAddOnInfo(name)
				return enabled and true or false
			end,
			set = function(_, value) SetAddOn(name, value) end
		}

		--Switching off the addon that draws this page works, and then the page is gone
		--and there is no obvious way back. Worth one dialog.
		if name == "OctoUI" then
			option.confirm = true
			option.confirmText = L["Disabling OctoUI removes this options window along with the rest of the UI. You would need to re-enable it from Blizzard's own addon list at the character screen. Continue?"]
		end

		if IsBlizzard(name) then
			blizzArgs[name] = option
		else
			listArgs[name] = option
		end
	end
end

--The Main Menu button, sitting under Return to Game.
--
--GameMenuButtonContinue is the last button in the stock frame, so the frame has to grow
--by a row or this hangs off the bottom edge. Init.lua plays the same trick for the
--OctoUI button and flags the frame so it only grows once; this keeps its own flag for
--the same reason, and the two hooks do not interfere.
--
--Built on first show rather than at file scope: Config files run during addon load,
--before E.private exists, and the skin call below needs it.
local function EnsureGameMenuButton()
	if GameMenuFrame.octoAddOnsButton then return GameMenuFrame.octoAddOnsButton end
	if not GameMenuButtonContinue then return end

	local button = CreateFrame("Button", "OctoUIAddOnsMenuButton", GameMenuFrame, "GameMenuButtonTemplate")
	button:SetWidth(GameMenuButtonContinue:GetWidth())
	button:SetHeight(GameMenuButtonContinue:GetHeight())
	button:SetText(L["AddOns"])
	button:SetScript("OnClick", function()
		HideUIPanel(GameMenuFrame)
		OpenAddOnPage()
	end)

	GameMenuFrame.octoAddOnsButton = button

	if E.private and E.private.skins and E.private.skins.blizzard.enable == true and E.private.skins.blizzard.misc == true then
		local S = E:GetModule("Skins")
		if S and S.HandleButton then S:HandleButton(button) end
	end

	return button
end

if GameMenuFrame then
	HookScript(GameMenuFrame, "OnShow", function()
		local button = EnsureGameMenuButton()
		if not button then return end

		if not GameMenuFrame.octoAddOnsSized then
			GameMenuFrame:SetHeight(GameMenuFrame:GetHeight() + button:GetHeight() + 6)
			GameMenuFrame.octoAddOnsSized = true
		end

		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", GameMenuButtonContinue, "BOTTOMLEFT", 0, -6)
	end)
end
