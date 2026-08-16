local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local RF = E:NewModule("RecipeFinder", "AceEvent-3.0");
E.RecipeFinder = RF

--Cache global variables
--Lua functions
local pairs, ipairs, unpack = pairs, ipairs, unpack
local format, find, lower = string.format, string.find, string.lower
local tinsert, sort, getn = table.insert, table.sort, table.getn
local floor, mod = math.floor, math.mod
local _G = _G
--WoW API / Variables
local CreateFrame = CreateFrame
local GetNumSkillLines, GetSkillLineInfo = GetNumSkillLines, GetSkillLineInfo
local GetItemInfo = GetItemInfo
local GetNumMerchantItems, GetMerchantItemInfo = GetNumMerchantItems, GetMerchantItemInfo
local GameTooltip, Minimap = GameTooltip, Minimap
local DEFAULT_CHAT_FRAME = DEFAULT_CHAT_FRAME

--[[
	Recipe Finder.

	Answers one question: "where do I go to get this recipe?" One tab per trade
	skill, a search box, and a detail pane naming every vendor, mob, container
	and quest that can yield the recipe, with zone, coordinates, price, stock
	limit, drop rate and reputation requirement.

	The database in DB/ is GENERATED, not written. It reconciles three upstream
	sources, none of which is sufficient alone:

	  LibCrafts-1.0 (MIT, Refaim)  profession, required skill, craft spell,
	                              reagents. Current to Turtle 1.18, and the only
	                              source that knows Turtle's Jewelcrafting.
	  TradeSkillsData (Refaim)     vendor PRICE and reputation requirement. The
	                              only source carrying either. Archived mid-2024.
	  pfQuest / pfQuest-turtle     live Turtle spawn data: which mobs actually
	  (MIT, Shagu)                drop it, at what rate, and where they stand.

	Regenerate with octoui-dev's build.py after any of those update. It also
	writes REPORT.md listing every field no source could confirm; the entries it
	flags carry `unsure` here and are drawn with a trailing "?" so a guess never
	reads as a fact.

	Prices are seeded from TradeSkillsData and CORRECTED IN PLAY: every merchant
	window read via GetMerchantItemInfo overwrites the stored price for a recipe
	the finder knows. That is the only way to be right about a server that can
	change vendor costs whenever it likes, and it makes a missing price
	self-healing rather than permanently blank.
]]

--Content tiers, lowest first. The filter is a ceiling, so the default of AQ
--shows everything up to and including AQ40 and hides Naxxramas.
local PHASE_ORDER = {BASE = 1, MC = 2, BWL = 3, ZG = 4, AQ = 5, NAXX = 6}
RF.PHASE_ORDER = PHASE_ORDER
RF.PHASE_LABEL = {
	[1] = L["Vanilla"], [2] = L["Molten Core"], [3] = L["Blackwing Lair"],
	[4] = L["Zul'Gurub"], [5] = L["Ahn'Qiraj"], [6] = L["Naxxramas"]
}

--Item quality colours, indexed as the generator writes them.
local QUALITY_COLOR = {
	[0] = {0.62, 0.62, 0.62}, [1] = {1, 1, 1}, [2] = {0.12, 1, 0},
	[3] = {0, 0.44, 0.87}, [4] = {0.64, 0.21, 0.93}, [5] = {1, 0.50, 0}
}
RF.QUALITY_COLOR = QUALITY_COLOR

--Faction reaction colours for source NPCs. A Horde-only vendor is useless to an
--Alliance character and vice versa, so the colour is load-bearing, not decoration.
local REACT_COLOR = {
	["Alliance"] = {0.35, 0.55, 1}, ["Horde"] = {1, 0.30, 0.30},
	["Hostile"] = {1, 0.45, 0.45}, ["Neutral"] = {1, 0.85, 0.35}
}

--Professions that are gathering-only or have a single stub entry. They exist in
--the generated data because a recipe item technically maps to them, but a tab
--holding one row is noise.
local HIDE_TAB = {["Mining"] = true, ["Fishing"] = true}

local index, professions

function RF:Database()
	return _G["OctoUI_RecipeDB"]
end

--------------------------------------------------------------------------------
-- Index
--------------------------------------------------------------------------------

--Flattens the per-profession tables into sorted arrays and precomputes the
--lowercase haystack each search runs against. Doing that once at load costs a
--few milliseconds; doing it per keystroke over 1100 recipes does not.
function RF:BuildIndex()
	local db = self:Database()
	if not db or not db.recipes then return end

	index, professions = {}, {}

	for profession, list in pairs(db.recipes) do
		if not HIDE_TAB[profession] and getn(list) > 0 then
			local rows = {}
			for i = 1, getn(list) do
				local recipe = list[i]
				recipe.prof = profession
				--Searchable on both the recipe item name and the thing it makes,
				--because people look for "Mongoose", not "Recipe: Elixir of the".
				recipe.search = lower((recipe.name or "").." "..(recipe.craft or ""))
				tinsert(rows, recipe)
			end

			sort(rows, function(a, b)
				local sa, sb = a.skill or 0, b.skill or 0
				if sa ~= sb then return sa < sb end
				return (a.name or "") < (b.name or "")
			end)

			index[profession] = rows
			tinsert(professions, profession)
		end
	end

	sort(professions)
	self.professions = professions
end

function RF:Professions()
	if not professions then self:BuildIndex() end
	return professions or {}
end

function RF:Recipes(profession)
	if not index then self:BuildIndex() end
	return (index and index[profession]) or {}
end

--------------------------------------------------------------------------------
-- Player state
--------------------------------------------------------------------------------

--Current rank in each trade skill, read fresh rather than cached: skill lines
--change while the window is open and a stale "learnable" filter is worse than none.
function RF:PlayerSkills()
	local skills = {}
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if name and not isHeader then
			skills[name] = rank or 0
		end
	end
	return skills
end

--------------------------------------------------------------------------------
-- Filtering
--------------------------------------------------------------------------------

function RF:Filter(profession, query, options)
	options = options or {}
	local rows = self:Recipes(profession)
	local out = {}

	query = query and lower(query) or ""
	if query == "" then query = nil end

	local ceiling = options.phase or PHASE_ORDER.AQ
	local skill = options.learnable and (self:PlayerSkills()[profession] or 0) or nil

	for i = 1, getn(rows) do
		local recipe = rows[i]
		local keep = true

		if query and not find(recipe.search, query, 1, true) then
			keep = false
		end

		if keep and (PHASE_ORDER[recipe.phase or "BASE"] or 1) > ceiling then
			keep = false
		end

		--"Learnable now" means the skill requirement is met. A recipe with no
		--known requirement is kept: hiding it would silently lose data the
		--sources simply do not have.
		if keep and skill and recipe.skill and recipe.skill > skill then
			keep = false
		end

		if keep and options.vendorOnly and not recipe.vendor then
			keep = false
		end

		if keep then tinsert(out, recipe) end
	end

	return out
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

function RF:FormatMoney(copper)
	if not copper or copper <= 0 then return nil end

	local gold = floor(copper / 10000)
	local silver = floor(mod(copper, 10000) / 100)
	local bronze = mod(copper, 100)
	local text = ""

	if gold > 0 then text = text..format("|cffffd700%d|rg ", gold) end
	if silver > 0 then text = text..format("|cffc7c7cf%d|rs ", silver) end
	if bronze > 0 or text == "" then text = text..format("|cffeda55f%d|rc", bronze) end

	return text
end

local function ZoneName(db, id)
	return (id and db.zones[id]) or L["Unknown location"]
end

--One human-readable line for an NPC: name, faction colour, level, zone, coords.
function RF:NpcLine(id)
	local db = self:Database()
	local npc = db and db.npcs[id]
	if not npc then return format(L["NPC %d"], id) end

	--floor before %x: the colours are fractions, and Lua's %x on a non-integer is
	--not something to rely on across versions.
	local color = REACT_COLOR[npc.r] or REACT_COLOR["Neutral"]
	local text = format("|cff%02x%02x%02x%s|r",
		floor(color[1] * 255), floor(color[2] * 255), floor(color[3] * 255), npc.n)

	if npc.lmin then
		if npc.lmax and npc.lmax ~= npc.lmin then
			text = text..format(" |cff9d9d9d(%d-%d)|r", npc.lmin, npc.lmax)
		else
			text = text..format(" |cff9d9d9d(%d)|r", npc.lmin)
		end
	end
	if npc.elite then text = text.." |cffffd700+|r" end

	text = text.." - "..ZoneName(db, npc.z)
	if npc.x and npc.y then
		text = text..format(" |cff8080ff%.1f, %.1f|r", npc.x, npc.y)
	end

	return text
end

--Builds the detail pane contents as a flat list of {text, header} rows. Kept
--separate from the UI so the same text can go to chat via the slash command.
function RF:SourceLines(recipe)
	local db = self:Database()
	local lines = {}

	local function add(text, header) tinsert(lines, {text = text, header = header}) end

	if recipe.rep then
		local faction = db.factions[recipe.rep.f] or L["Unknown faction"]
		local standing = db.repLevels[recipe.rep.l] or "?"
		add(format(L["Requires %s - %s"], faction, "|cffffd700"..standing.."|r"), true)
	end

	local vendor = recipe.vendor
	if vendor then
		local price = self:FormatMoney(vendor.price)
		add(price and format(L["Sold by (%s)"], price) or L["Sold by (price unknown)"], true)
		for i = 1, getn(vendor.npcs) do
			local id = vendor.npcs[i]
			local text = self:NpcLine(id)
			local stock = vendor.stock and vendor.stock[id]
			if stock then
				text = text..format(" |cffff8080["..L["limited: %d"].."]|r", stock)
			end
			add(text)
		end
	end

	local drop = recipe.drop
	if drop then
		if drop.wd then
			local header = format(L["World drop from %d creatures"], drop.n or 0)
			if drop.lvl then
				header = header..format(" "..L["(level %d-%d)"], drop.lvl[1], drop.lvl[2])
			end
			add(header, true)
			if drop.zones and getn(drop.zones) > 0 then
				local zones = ""
				for i = 1, getn(drop.zones) do
					zones = zones..(i > 1 and ", " or "")..ZoneName(db, drop.zones[i])
				end
				add("|cff9d9d9d"..L["Mostly"]..":|r "..zones)
			end
			add("|cff9d9d9d"..L["Best rates"]..":|r")
		else
			add(L["Dropped by"], true)
		end

		for i = 1, getn(drop.npcs) do
			local id = drop.npcs[i]
			local text = self:NpcLine(id)
			local rate = drop.rates and drop.rates[id]
			if rate then text = text..format(" |cff00ff00%.2f%%|r", rate) end
			add(text)
		end
	end

	local object = recipe.object
	if object then
		add(L["Found in containers"], true)
		for i = 1, getn(object.ids) do
			local id = object.ids[i]
			local entry = db.objects[id]
			if entry then
				local text = entry.n.." - "..ZoneName(db, entry.z)
				local rate = object.rates and object.rates[id]
				if rate then text = text..format(" |cff00ff00%.2f%%|r", rate) end
				add(text)
			end
		end
	end

	if recipe.quest then
		add(L["Quest reward"], true)
		for i = 1, getn(recipe.quest) do
			local quest = db.quests[recipe.quest[i]]
			if quest then
				add(quest.n..(quest.lvl and quest.lvl > 0
					and format(" |cff9d9d9d(%d)|r", quest.lvl) or ""))
			end
		end
	end

	--Crafts with no recipe item at all: trainer-taught, quest-taught, or known
	--from the moment the profession is learned.
	if recipe.spellsrc then
		for i = 1, getn(recipe.spellsrc) do
			local source = recipe.spellsrc[i]
			if source == "Trainer" then
				add(L["Taught by a trade skill trainer"], true)
			elseif source == "LearnedAutomatically" then
				add(L["Known automatically at the required skill"], true)
			elseif source == "Quest" then
				add(L["Taught by a quest"], true)
			elseif source == "WorldObject" then
				add(L["Learned from a world object"], true)
			end
		end
	end

	if getn(lines) == 0 then
		add(L["No source known. See REPORT.md."], true)
	end

	return lines
end

function RF:ReagentLines(recipe)
	local lines = {}
	if not recipe.reagents then return lines end

	for id, count in pairs(recipe.reagents) do
		local name = GetItemInfo(id)
		tinsert(lines, format("%s x%d", name or format(L["Item %d"], id), count))
	end
	sort(lines)
	return lines
end

--------------------------------------------------------------------------------
-- Live price correction
--------------------------------------------------------------------------------

--Vendor prices ship as a seed and are overwritten by what the merchant actually
--charges. Reputation discounts are deliberately NOT unwound: the number shown is
--what this character pays, which is the number that matters when deciding
--whether to make the trip.
function RF:MERCHANT_SHOW()
	local db = self:Database()
	if not db then return end

	local byName = self.vendorByName
	if not byName then
		byName = {}
		for profession, rows in pairs(index or {}) do
			for i = 1, getn(rows) do
				if rows[i].vendor then byName[rows[i].name] = rows[i] end
			end
		end
		self.vendorByName = byName
	end

	for slot = 1, GetNumMerchantItems() do
		local name, _, price, quantity = GetMerchantItemInfo(slot)
		local recipe = name and byName[name]
		if recipe and price and price > 0 and (quantity or 1) == 1 then
			recipe.vendor.price = price
			recipe.vendor.seen = true
		end
	end
end

--------------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------------

function RF:CreateMinimapButton()
	local config = E.db.general.minimap.icons.recipeFinder
	if not config or config.hide then return end
	if self.minimapButton then return end

	--Named with the OctoUI prefix on purpose: MinimapButtons.lua skips anything
	--so named, which keeps this button out of the third-party collection bar and
	--under the control of the options below instead.
	local button = CreateFrame("Button", "OctoUI_RecipeFinderButton", Minimap)
	E:Size(button, 24)
	E:SetTemplate(button, "Default")
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(Minimap:GetFrameLevel() + 8)

	local icon = button:CreateTexture(nil, "ARTWORK")
	E:SetInside(icon, button, 2, 2)
	icon:SetTexture("Interface\\Icons\\INV_Scroll_03")
	--Trim the 1.12 icon border, which is baked into the texture rather than
	--drawn as a separate region.
	icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
	button.icon = icon

	button:SetScript("OnClick", function() RF:Toggle() end)
	button:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(unpack(E.media.rgbvaluecolor))
		GameTooltip:SetOwner(this, "ANCHOR_LEFT")
		GameTooltip:AddLine(L["Recipe Finder"])
		GameTooltip:AddLine(L["Click to look up where a recipe comes from."], 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		E:SetTemplate(this, "Default")
		GameTooltip:Hide()
	end)

	self.minimapButton = button
	self:PositionMinimapButton()
end

function RF:PositionMinimapButton()
	local button = self.minimapButton
	if not button then return end

	local config = E.db.general.minimap.icons.recipeFinder
	local point = config.position or "TOPLEFT"

	button:ClearAllPoints()
	button:SetScale(config.scale or 1)
	E:Point(button, point, Minimap, point, config.xOffset or 2, config.yOffset or -2)

	if config.hide then button:Hide() else button:Show() end
end

--------------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------------

function RF:Toggle()
	if not self.frame then self:BuildWindow() end
	if not self.frame then return end

	if self.frame:IsShown() then
		self.frame:Hide()
	else
		self.frame:Show()
		self:Refresh()
	end
end

--Chat fallback for the detail pane, so a source can be read (and copied) without
--the window, and so a broken window is never the only way to reach the data.
function RF:PrintRecipe(query)
	local found
	for _, profession in ipairs(self:Professions()) do
		local rows = self:Filter(profession, query, {phase = PHASE_ORDER.NAXX})
		if getn(rows) > 0 then found = rows[1] break end
	end

	if not found then
		E:Print(format(L["No recipe matching '%s'."], query))
		return
	end

	E:Print(found.name.." |cff9d9d9d("..found.prof
		..(found.skill and format(", %d", found.skill) or "")..")|r")
	local lines = self:SourceLines(found)
	for i = 1, getn(lines) do
		DEFAULT_CHAT_FRAME:AddMessage("  "..lines[i].text)
	end
end

function RF:Initialize()
	self.Initialized = true

	if not self:Database() then
		E:Print(L["Recipe Finder: database failed to load."])
		return
	end

	self:BuildIndex()
	self:CreateMinimapButton()
	self:RegisterEvent("MERCHANT_SHOW")
end

--Reached from /octoui-recipes, registered in Core\Commands.lua with the rest.
function RF:Command(msg)
	if msg and msg ~= "" then
		self:PrintRecipe(msg)
	else
		self:Toggle()
	end
end

local function InitializeCallback()
	RF:Initialize()
end

E:RegisterModule(RF:GetName(), InitializeCallback)
