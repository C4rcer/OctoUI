local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local RF = E:NewModule("RecipeFinder", "AceEvent-3.0");
E.RecipeFinder = RF

--Cache global variables
--Lua functions
local pairs, ipairs, unpack = pairs, ipairs, unpack
local format, find, lower, gsub = string.format, string.find, string.lower, string.gsub
local tinsert, sort, getn = table.insert, table.sort, table.getn
local floor, mod = math.floor, math.mod
local _G = _G
--WoW API / Variables
local CreateFrame = CreateFrame
local GetNumSkillLines, GetSkillLineInfo = GetNumSkillLines, GetSkillLineInfo
local GetItemInfo = GetItemInfo
--It is GetMerchantNumItems on this client, NOT GetNumMerchantItems -- the latter
--is a later-expansion name that exists nowhere in 1.12, and caching it here gave
--a nil that only blew up when someone opened a vendor. Modules\Skins\Blizzard\
--Merchant.lua had the right name all along.
local GetMerchantNumItems, GetMerchantItemInfo = GetMerchantNumItems, GetMerchantItemInfo
local GetNumTradeSkills, GetTradeSkillInfo = GetNumTradeSkills, GetTradeSkillInfo
local GetTradeSkillLine = GetTradeSkillLine
local GetNumCrafts, GetCraftInfo = GetNumCrafts, GetCraftInfo
local GetCraftDisplaySkillLine = GetCraftDisplaySkillLine
local GetNumSpellTabs, GetSpellTabInfo = GetNumSpellTabs, GetSpellTabInfo
local GetSpellName = GetSpellName
--Constants.lua defines this before addons load, but "spell" is its value and a
--correct argument regardless, so there is no reason to depend on the ordering.
local BOOKTYPE_SPELL = BOOKTYPE_SPELL or "spell"
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
--Labelled as ceilings, because that is what the filter is. "Ahn'Qiraj" on a
--button reads as "show me AQ recipes", which is the opposite of what it does.
RF.PHASE_LABEL = {
	[1] = L["Vanilla only"], [2] = L["Up to Molten Core"], [3] = L["Up to Blackwing Lair"],
	[4] = L["Up to Zul'Gurub"], [5] = L["Up to AQ40"], [6] = L["Everything"]
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

	--Every profession with anything in it gets a tab, including the one-row ones.
	--Mining and Fishing were suppressed as stubs until it turned out their single
	--entries are the Expert Fishing book and Turtle's Smelt Dreamsteel -- exactly
	--the sort of thing someone opens this window to find.
	for profession, list in pairs(db.recipes) do
		if getn(list) > 0 then
			local rows = {}
			for i = 1, getn(list) do
				local recipe = list[i]
				recipe.prof = profession
				--Searchable on both the recipe item name and the thing it makes,
				--because people look for "Mongoose", not "Recipe: Elixir of the".
				recipe.search = lower((recipe.name or "").." "..(recipe.craft or ""))

				--What the trade skill window would call this, for the "unlearned"
				--filter to match against. Usually the craft name; where no source
				--supplied one, the item name with its "Manual: "/"Pattern: "
				--prefix stripped is the next best thing. A name with no prefix is
				--left alone, so it simply never matches rather than matching
				--something wrong.
				recipe.knownKey = recipe.craft
				if not recipe.knownKey and recipe.name then
					recipe.knownKey = gsub(recipe.name, "^%a+:%s*", "")
				end

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
--change while the window is open and a stale filter is worse than none.
function RF:PlayerSkills()
	local ranks = {}
	for i = 1, GetNumSkillLines() do
		local name, isHeader, _, rank = GetSkillLineInfo(i)
		if name and not isHeader then
			ranks[name] = rank or 0
		end
	end
	return ranks
end

--Which rank of a profession the character holds, read from the SPELLBOOK: the
--profession's entry carries the rank as its subtext, which is why the spellbook
--shows "First Aid / Artisan" and "Cooking / Journeyman".
--
--This is the exact test for owning a rank book, and it is exact precisely where
--a skill-cap comparison is weakest -- at the boundary. A character sitting at
--225 First Aid either needs Expert or has it, and the cap alone cannot say
--which; the spellbook says outright. It also assumes nothing about what
--GetSkillLineInfo reports as a maximum, which is not something to take on faith.
function RF:ProfessionRank(profession)
	local db = self:Database()
	local words = db and db.professionRanks and db.professionRanks[profession]
	if not words then return nil end

	for tab = 1, GetNumSpellTabs() do
		local _, _, offset, count = GetSpellTabInfo(tab)
		if offset and count then
			for slot = offset + 1, offset + count do
				local name, rank = GetSpellName(slot, BOOKTYPE_SPELL)
				if name == profession and rank then
					return words[rank]
				end
			end
		end
	end

	return nil
end

--------------------------------------------------------------------------------
-- Known recipes
--------------------------------------------------------------------------------

--1.12 will only tell an addon what a character has learned while the profession
--window is OPEN -- GetTradeSkillInfo reads whatever that frame is currently
--showing and nothing else. So the known set is scraped whenever a profession is
--opened and remembered per character.
--
--Entries are only ever ADDED. A collapsed category is simply absent from the
--list rather than marked as unknown, so a subtractive scan would "forget"
--recipes every time someone browsed with a header rolled up. Nothing in vanilla
--can be unlearned, which makes merge-only both safe and correct.
function RF:KnownStore()
	if not ElvCharacterDB then return nil end
	if not ElvCharacterDB.RecipeFinderKnown then
		ElvCharacterDB.RecipeFinderKnown = {}
	end
	return ElvCharacterDB.RecipeFinderKnown
end

function RF:RecordKnown(profession, names)
	local store = self:KnownStore()
	--Only professions the database actually has a tab for. The Craft API is
	--shared with Beast Training, so this is what keeps pet skills out.
	if not store or not profession or not index or not index[profession] then return end

	local known = store[profession]
	if not known then
		known = {}
		store[profession] = known
	end

	for i = 1, getn(names) do
		known[names[i]] = true
	end

	if self.frame and self.frame:IsShown() then self:Refresh() end
end

function RF:TRADE_SKILL_SHOW()
	local profession = GetTradeSkillLine()
	if not profession then return end

	local names = {}
	for i = 1, GetNumTradeSkills() do
		local name, skillType = GetTradeSkillInfo(i)
		if name and skillType ~= "header" then
			tinsert(names, name)
		end
	end

	self:RecordKnown(profession, names)
end

RF.TRADE_SKILL_UPDATE = RF.TRADE_SKILL_SHOW

function RF:CRAFT_SHOW()
	--Enchanting is a Craft, not a TradeSkill, on this client. This is the same
	--call Atlas-OctoUI's profession hooks use to name the Craft frame, which is
	--how it is known to work here.
	local profession = GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
	if not profession then return end

	local names = {}
	for i = 1, GetNumCrafts() do
		local name, _, craftType = GetCraftInfo(i)
		if name and craftType ~= "header" then
			tinsert(names, name)
		end
	end

	self:RecordKnown(profession, names)
end

RF.CRAFT_UPDATE = RF.CRAFT_SHOW

function RF:KnownCount(profession)
	local store = self:KnownStore()
	local known = store and store[profession]
	if not known then return nil end

	local count = 0
	for _ in pairs(known) do count = count + 1 end
	return count
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

	local ranks
	if options.learnable or options.unlearned then
		ranks = self:PlayerSkills()
	end

	local skill = options.learnable and (ranks[profession] or 0) or nil
	local current = ranks and ranks[profession] or nil
	local profRank = options.unlearned and self:ProfessionRank(profession) or nil

	local store = options.unlearned and self:KnownStore() or nil
	local known = store and store[profession] or nil

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

		--Matched on the CRAFT name, which is what the trade skill window lists;
		--recipe.name is the scroll in the bag and never appears there.
		if keep and known and recipe.knownKey and known[recipe.knownKey] then
			keep = false
		end

		--A profession rank book. The spellbook rank settles it outright; where
		--that cannot be read, fall back to the cap of the rank BELOW this one,
		--which the character could not have passed without owning the book.
		--That fallback can only ever be late, never wrong: someone who just
		--bought Expert at exactly 150 still sees it until they gain a point.
		if keep and options.unlearned and recipe.tierRank then
			if profRank then
				if profRank >= recipe.tierRank then keep = false end
			elseif recipe.tierFrom and current and current > recipe.tierFrom then
				keep = false
			end
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
	local parts = {}

	if gold > 0 then tinsert(parts, format("|cffffd700%d|rg", gold)) end
	if silver > 0 then tinsert(parts, format("|cffc7c7cf%d|rs", silver)) end
	--Joined rather than each part carrying its own trailing space, which is what
	--rendered a round 50 silver as "Sold by (50s )".
	if bronze > 0 or getn(parts) == 0 then
		tinsert(parts, format("|cffeda55f%d|rc", bronze))
	end

	local text = parts[1]
	for i = 2, getn(parts) do text = text.." "..parts[i] end
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

	if recipe.tier then
		add(format(L["Raises the skill cap to %d"], recipe.tier), true)
	end

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

	for slot = 1, GetMerchantNumItems() do
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

	local button = CreateFrame("Button", "OctoUI_RecipeFinderButton", Minimap)
	E:Size(button, E.db.general.minimap.buttonBar.buttonSize or 26)
	E:SetTemplate(button, "Default")
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
	--Opt in to the third-party button bar. MinimapButtons.lua otherwise skips
	--every OctoUI-named frame, which left this as the one button still stuck on
	--the minimap while all the others lined up underneath it.
	button.octoCollect = true

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

--Only ever positions the button while it is still on the minimap. Once the
--button bar has adopted it, the bar owns both its parent and its point, and
--ClearAllPoints here would unanchor a frame whose SetPoint has been noop'd --
--leaving it invisible with no way to get it back short of a reload.
function RF:PositionMinimapButton()
	local button = self.minimapButton
	if not button or button.octoCollected then return end

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
	self:RegisterEvent("TRADE_SKILL_SHOW")
	self:RegisterEvent("TRADE_SKILL_UPDATE")
	self:RegisterEvent("CRAFT_SHOW")
	self:RegisterEvent("CRAFT_UPDATE")
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
