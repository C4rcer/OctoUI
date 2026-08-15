local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local M = E:GetModule("Misc");

--Cache global variables
--Lua functions
local pairs, ipairs, type, pcall, loadstring = pairs, ipairs, type, pcall, loadstring
local getn, tinsert, sort, concat = table.getn, table.insert, table.sort, table.concat
local format, gsub = string.format, string.gsub
--WoW API / Variables
local CreateFrame = CreateFrame

--[[
	Lua that loads itself, so a macro can call it.

	A macro on this client is 255 characters and cannot hold a function, so anything with
	real logic in it has to live somewhere that survives a reload and be called by name.
	Vanilla's answer was SuperMacro; this is the same idea kept inside OctoUI, because a
	rotation helper is no use if it evaporates every time the UI reloads.

	WHY IT EXISTS AT ALL: conditional macro addons read debuff state through their own
	trackers, and when one of those is not populated its conditionals fail silently -- a
	[nodebuff:X] that is always true reads exactly like a working macro right up until you
	notice it never stops casting. Lua asks the client directly, which is the one source
	that cannot quietly be empty.

	ACCOUNT-WIDE, in E.global. A helper written for one character is nearly always wanted on
	the next, and the alternative is pasting it into every profile.

	RUN AS SOON AS THIS LOADS. The first version waited for PLAYER_LOGIN, which cannot work:
	Init.lua registers PLAYER_LOGIN to run Initialize, so a frame created from Initialize is
	registering for an event that is being dispatched right then and will never see it
	again. Only PLAYER_ENTERING_WORLD was carrying it, which is one accident away from
	nothing running at all.

	Loading here is also late enough for the thing that requirement was about: every addon
	has had its ADDON_LOADED before PLAYER_LOGIN, so a snippet calling into another addon
	finds it. The events stay as a backstop, guarded so nothing runs twice.

	EVERY SNIPPET IS ISOLATED. Compiled with loadstring and called through pcall, so one
	broken line costs that snippet and nothing else -- the error is kept and reported by
	/octoui-lua rather than being thrown into the middle of the login sequence, where it
	would look like OctoUI itself had failed.
]]

local loaded = false

local function Store()
	if not E.global.luaMacros then
		E.global.luaMacros = {}
	end

	return E.global.luaMacros
end

--Sorted, so the list reads the same every time and two snippets cannot swap places.
function M:GetLuaMacros()
	local list = {}
	for name, entry in pairs(Store()) do
		tinsert(list, {name = name, entry = entry})
	end

	sort(list, function(a, b) return a.name < b.name end)
	return list
end

function M:SetLuaMacro(name, code)
	if not name or name == "" then return nil end

	local db = Store()
	if not db[name] then
		db[name] = {enable = true}
	end

	db[name].code = code or ""
	--Cleared rather than kept: the error described the previous text and would otherwise sit
	--there accusing code that no longer exists.
	db[name].error = nil

	return db[name]
end

function M:RemoveLuaMacro(name)
	local db = Store()
	if not (name and db[name]) then return nil end

	db[name] = nil
	return true
end

--[[
	Compile and run one snippet.

	loadstring reports a syntax error by returning nil and a message; pcall catches anything
	the code raises while running. Both are recorded on the entry so the options page and
	/octoui-lua can show WHICH snippet is broken and why, which is the whole difference
	between this and pasting the same code into a login macro.
]]
function M:RunLuaMacro(name)
	local entry = Store()[name]
	if not entry then return false, "no such snippet" end
	if entry.enable == false then return false, "disabled" end
	if not entry.code or entry.code == "" then return false, "empty" end

	local chunk, syntaxError = loadstring(entry.code, "OctoUI:"..name)
	if not chunk then
		entry.error = syntaxError or "could not compile"
		return false, entry.error
	end

	local ok, runError = pcall(chunk)
	if not ok then
		entry.error = runError or "raised while running"
		return false, entry.error
	end

	entry.error = nil
	return true
end

function M:RunLuaMacros()
	local ran, failed = 0, 0

	for _, item in ipairs(M:GetLuaMacros()) do
		if item.entry.enable ~= false and item.entry.code and item.entry.code ~= "" then
			if M:RunLuaMacro(item.name) then
				ran = ran + 1
			else
				failed = failed + 1
			end
		end
	end

	loaded = true
	return ran, failed
end

function M:LuaMacrosLoaded()
	return loaded
end

--What UserMacros.lua defined, by name. That file works out its own list -- see the two
--blocks at its top and bottom -- so this is only the reader.
--
--The point of it is that the game can SAY what is loaded. A file you have to open and read
--to know whether your own code is live is barely better than no answer at all.
function M:GetUserMacroFunctions()
	local list = _G.OctoUI_UserMacros
	if type(list) ~= "table" then return {} end

	return list
end

--[[
	The options page, built here rather than in Config/ so a change needs only /reload.
]]
local refreshPending

--Never rebuild the options tree from inside a widget callback: AceConfigDialog is still
--unwinding the click and would return to a group this had deleted. Same guard as the
--ignore list uses, and for the same reason.
function M:ScheduleLuaMacroRefresh()
	if refreshPending then return end
	refreshPending = true

	E:Delay(0.05, function()
		refreshPending = nil
		M:RefreshLuaMacroOptions()

		local ACR = LibStub and LibStub("AceConfigRegistry-3.0", true)
		if ACR and E.ConfigAppName then
			pcall(ACR.NotifyChange, ACR, E.ConfigAppName)
		end
	end)
end

local staticArgs = {intro = true, fileHeader = true, fileList = true, add = true, runAll = true}

function M:RefreshLuaMacroOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	local group = general and general.args and general.args.luaMacros
	if not group then return end

	local args = group.args
	for key in pairs(args) do
		if not staticArgs[key] then args[key] = nil end
	end

	local list = M:GetLuaMacros()
	if getn(list) == 0 then
		args.empty = {
			order = 10,
			type = "description",
			name = L["Nothing here yet. Name one above, then paste its code into the box that appears."]
		}
		return
	end

	for index, item in ipairs(list) do
		local name = item.name

		args["snippet"..index] = {
			order = 10 + index,
			type = "group",
			guiInline = true,
			name = name,
			args = {
				enable = {
					order = 1,
					type = "toggle",
					name = L["Enable"],
					get = function()
						local entry = Store()[name]
						return entry and entry.enable ~= false
					end,
					set = function(_, value)
						local entry = Store()[name]
						if entry then entry.enable = value and true or false end
					end
				},
				run = {
					order = 2,
					type = "execute",
					name = L["Run now"],
					desc = L["Runs it immediately, without waiting for the next reload."],
					func = function()
						M:RunLuaMacro(name)
						M:ScheduleLuaMacroRefresh()
					end
				},
				delete = {
					order = 3,
					type = "execute",
					name = L["Delete"],
					func = function()
						M:RemoveLuaMacro(name)
						M:ScheduleLuaMacroRefresh()
					end
				},
				code = {
					order = 4,
					type = "input",
					multiline = 10,
					width = "full",
					name = L["Code"],
					get = function()
						local entry = Store()[name]
						return (entry and entry.code) or ""
					end,
					set = function(_, value)
						M:SetLuaMacro(name, value)
						M:RunLuaMacro(name)
						M:ScheduleLuaMacroRefresh()
					end
				},
				status = {
					order = 5,
					type = "description",
					name = function()
						local entry = Store()[name]
						if entry and entry.error then
							return format(L["LUAMACRO_ERROR"], entry.error)
						end
						return L["LUAMACRO_OK"]
					end
				}
			}
		}
	end
end

local function BuildOptions()
	local general = E.Options and E.Options.args and E.Options.args.general
	if not general or not general.args then return end

	general.args.luaMacros = {
		--Between CC Watch (5.7) and Chat Bubbles (6).
		order = 5.8,
		type = "group",
		name = L["Lua Macros"],
		args = {
			intro = {
				order = 1,
				type = "description",
				name = L["Lua that is compiled and run every time the UI loads, so a macro can call it by name. A 255 character macro cannot hold a function; this is where the function lives. Call it with /run YourFunction()"]
			},
			--First thing on the page, because "is my code loaded" is the question being asked
			--and it should not need a file opened or a spell cast to answer it.
			fileHeader = {
				order = 2,
				type = "header",
				name = L["Loaded from UserMacros.lua"]
			},
			fileList = {
				order = 3,
				type = "description",
				name = function()
					local fns = M:GetUserMacroFunctions()
					if getn(fns) == 0 then
						return L["LUAMACRO_FILE_EMPTY"]
					end

					return format(L["LUAMACRO_FILE_LIST"], getn(fns), concat(fns, ", "))
				end
			},
			add = {
				order = 4,
				type = "input",
				width = "full",
				name = L["New snippet"],
				desc = L["A name for it. Letters and numbers, no spaces -- it is only a label, not the function name."],
				get = function() return "" end,
				set = function(_, value)
					if value and value ~= "" then
						--Spaces would make the /octoui-lua arguments ambiguous, and the name is
						--only ever a label.
						M:SetLuaMacro(gsub(value, "%s+", ""), "")
						M:ScheduleLuaMacroRefresh()
					end
				end
			},
			runAll = {
				order = 5,
				type = "execute",
				name = L["Run all now"],
				func = function()
					M:RunLuaMacros()
					M:ScheduleLuaMacroRefresh()
				end
			}
		}
	}

	M:RefreshLuaMacroOptions()
end

local function LoadOnce()
	if loaded then return end

	local ran, failed = M:RunLuaMacros()
	if failed > 0 then
		E:Print(format(L["LUAMACRO_LOAD_FAILED"], failed, ran))
	end

	--Said out loud, once, at login. Loading code that the game never mentions leaves you
	--pressing a button to find out whether it worked.
	local fns = M:GetUserMacroFunctions()
	if getn(fns) > 0 then
		E:Print(format(L["LUAMACRO_FILE_LOADED"], getn(fns), concat(fns, ", ")))
	end
end

function M:LoadLuaMacros()
	Store()
	BuildOptions()

	--Straight away. See the note at the top: waiting for an event we are already inside is
	--how the snippets came to never run at all.
	LoadOnce()

	--Its own frame rather than M:RegisterEvent, because Misc already registers events on the
	--module and AceEvent keeps one callback per event per object. Purely a backstop for a
	--load order where this runs before the saved variables are ready; `loaded` means it
	--costs one comparison per zone change and nothing else.
	local f = CreateFrame("Frame")
	f:RegisterEvent("PLAYER_ENTERING_WORLD")
	f:SetScript("OnEvent", LoadOnce)
end
