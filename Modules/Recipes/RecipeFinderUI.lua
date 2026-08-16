local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local RF = E:GetModule("RecipeFinder");

--Cache global variables
--Lua functions
local pairs, ipairs, unpack = pairs, ipairs, unpack
local format, lower = string.format, string.lower
local tinsert, getn = table.insert, table.getn
local min, max, floor = math.min, math.max, math.floor
--WoW API / Variables
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip

--[[
	The Recipe Finder window.

	Layout is three columns: profession tabs, the filtered recipe list, and the
	detail pane for whatever is selected. Everything is built once, on first
	open, and thereafter only the TEXT on a fixed set of rows changes. Creating
	frames per refresh is what makes vanilla list windows stutter, and 1.12 never
	frees a frame once made, so a search that rebuilt its rows would leak for the
	whole session.

	Scrolling is a plain slider plus mouse wheel rather than FauxScrollFrame.
	Faux would work, but it drags Blizzard's scrollbar art in with it, which then
	needs skinning to match; a slider we own is fewer moving parts than a
	template we immediately have to undo.
]]

local WIDTH, HEIGHT = 720, 520
local TAB_WIDTH = 116
local LIST_WIDTH = 258
local ROW_HEIGHT = 16
local VISIBLE_ROWS = 24
local DETAIL_LINES = 26

--Single-letter source glyphs on each row, so the list itself says whether a
--recipe is bought, farmed or quested without opening it.
local function SourceGlyphs(recipe)
	local text = ""
	if recipe.vendor then text = text.."|cff40ff40V|r" end
	if recipe.drop then text = text..(recipe.drop.wd and "|cffff8040w|r" or "|cffff8040D|r") end
	if recipe.object then text = text.."|cffc080ffC|r" end
	if recipe.quest then text = text.."|cffffd700Q|r" end
	if recipe.spellsrc then text = text.."|cff80c0ffT|r" end
	return text
end

--------------------------------------------------------------------------------
-- Widget helpers
--------------------------------------------------------------------------------

local function Toggle(parent, label, width, onClick)
	local button = CreateFrame("Button", nil, parent)
	E:Size(button, width, 18)
	E:SetTemplate(button, "Transparent")

	button.text = button:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(button.text, nil, 11, "NONE")
	button.text:SetAllPoints()
	button.text:SetText(label)

	function button:SetActive(active)
		self.active = active and true or false
		if self.active then
			self:SetBackdropBorderColor(unpack(E.media.rgbvaluecolor))
			self.text:SetTextColor(unpack(E.media.rgbvaluecolor))
		else
			E:SetTemplate(self, "Transparent")
			self.text:SetTextColor(0.8, 0.8, 0.8)
		end
	end

	button:SetScript("OnClick", onClick)
	button:SetScript("OnEnter", function()
		if not this.active then this:SetBackdropBorderColor(1, 1, 1) end
	end)
	button:SetScript("OnLeave", function() this:SetActive(this.active) end)
	button:SetActive(false)

	return button
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function RF:BuildWindow()
	if self.frame then return end

	local frame = CreateFrame("Frame", "OctoUI_RecipeFinder", E.UIParent)
	E:Size(frame, WIDTH, HEIGHT)
	E:SetTemplate(frame, "Transparent")
	E:Point(frame, "CENTER", E.UIParent, "CENTER", 0, 0)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()

	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function() this:StartMoving() end)
	frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

	--Escape closes it. UISpecialFrames is the only mechanism 1.12 offers for
	--that, and it takes the frame's global NAME, not the frame.
	tinsert(UISpecialFrames, "OctoUI_RecipeFinder")

	frame.title = frame:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(frame.title, nil, 14, "OUTLINE")
	E:Point(frame.title, "TOPLEFT", frame, "TOPLEFT", 10, -9)
	frame.title:SetText(L["Recipe Finder"])

	E:CreateCloseButton(frame, 16, -6)

	self.frame = frame
	self:BuildTabs()
	self:BuildFilterBar()
	self:BuildList()
	self:BuildDetail()

	frame.status = frame:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(frame.status, nil, 10, "NONE")
	E:Point(frame.status, "BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)
	frame.status:SetTextColor(0.6, 0.6, 0.6)

	self.selected = nil
	self.offset = 0
	self.filters = {
		phase = RF.PHASE_ORDER.AQ,
		learnable = false,
		vendorOnly = false
	}
	self.profession = self:Professions()[1]
end

function RF:BuildTabs()
	local frame = self.frame
	local tabs = {}
	local list = self:Professions()

	for i = 1, getn(list) do
		local profession = list[i]
		local tab = CreateFrame("Button", nil, frame)
		E:Size(tab, TAB_WIDTH - 12, 20)
		E:SetTemplate(tab, "Transparent")

		if i == 1 then
			E:Point(tab, "TOPLEFT", frame, "TOPLEFT", 8, -32)
		else
			E:Point(tab, "TOPLEFT", tabs[i - 1], "BOTTOMLEFT", 0, -2)
		end

		tab.text = tab:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(tab.text, nil, 11, "NONE")
		E:Point(tab.text, "LEFT", tab, "LEFT", 6, 0)
		tab.text:SetText(profession)
		tab.profession = profession

		tab.count = tab:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(tab.count, nil, 9, "NONE")
		E:Point(tab.count, "RIGHT", tab, "RIGHT", -5, 0)
		tab.count:SetText(getn(self:Recipes(profession)))
		tab.count:SetTextColor(0.5, 0.5, 0.5)

		tab:SetScript("OnClick", function()
			RF.profession = this.profession
			RF.offset = 0
			RF.selected = nil
			RF:Refresh()
		end)
		tab:SetScript("OnEnter", function()
			if RF.profession ~= this.profession then this:SetBackdropBorderColor(1, 1, 1) end
		end)
		tab:SetScript("OnLeave", function() RF:UpdateTabs() end)

		tabs[i] = tab
	end

	frame.tabs = tabs
end

function RF:BuildFilterBar()
	local frame = self.frame

	local search = CreateFrame("EditBox", "OctoUI_RecipeFinderSearch", frame)
	E:Size(search, 210, 18)
	E:SetTemplate(search, "Transparent")
	E:Point(search, "TOPLEFT", frame, "TOPLEFT", TAB_WIDTH + 4, -32)
	search:SetAutoFocus(false)
	search:SetTextInsets(4, 4, 0, 0)
	E:FontTemplate(search, nil, 11, "NONE")
	search:SetScript("OnTextChanged", function()
		RF.offset = 0
		RF:Refresh()
	end)
	search:SetScript("OnEscapePressed", function()
		this:SetText("")
		this:ClearFocus()
	end)
	search:SetScript("OnEnterPressed", function() this:ClearFocus() end)

	search.hint = search:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(search.hint, nil, 11, "NONE")
	E:Point(search.hint, "LEFT", search, "LEFT", 5, 0)
	search.hint:SetText(L["Search recipes..."])
	search.hint:SetTextColor(0.45, 0.45, 0.45)
	frame.search = search

	local learnable = Toggle(frame, L["Learnable"], 74, function()
		RF.filters.learnable = not RF.filters.learnable
		RF.offset = 0
		RF:Refresh()
	end)
	E:Point(learnable, "LEFT", search, "RIGHT", 4, 0)
	frame.learnable = learnable

	local vendor = Toggle(frame, L["Vendor"], 60, function()
		RF.filters.vendorOnly = not RF.filters.vendorOnly
		RF.offset = 0
		RF:Refresh()
	end)
	E:Point(vendor, "LEFT", learnable, "RIGHT", 4, 0)
	frame.vendorOnly = vendor

	--Cycles the content ceiling. Defaults to AQ, which is "up to and including
	--AQ40" -- the tier this database was assembled for.
	local phase = Toggle(frame, RF.PHASE_LABEL[RF.PHASE_ORDER.AQ], 92, function()
		local current = RF.filters.phase
		RF.filters.phase = (current >= RF.PHASE_ORDER.NAXX) and RF.PHASE_ORDER.BASE or (current + 1)
		RF.offset = 0
		RF:Refresh()
	end)
	E:Point(phase, "LEFT", vendor, "RIGHT", 4, 0)
	phase:SetScript("OnEnter", function()
		this:SetBackdropBorderColor(1, 1, 1)
		GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
		GameTooltip:AddLine(L["Content tier"])
		GameTooltip:AddLine(L["Hides recipes from later content. Click to cycle."], 1, 1, 1, 1)
		GameTooltip:Show()
	end)
	phase:SetScript("OnLeave", function()
		this:SetActive(this.active)
		GameTooltip:Hide()
	end)
	frame.phase = phase
end

function RF:BuildList()
	local frame = self.frame

	local list = CreateFrame("Frame", nil, frame)
	E:Size(list, LIST_WIDTH, VISIBLE_ROWS * ROW_HEIGHT + 8)
	E:SetTemplate(list, "Transparent")
	E:Point(list, "TOPLEFT", frame, "TOPLEFT", TAB_WIDTH + 4, -54)

	local rows = {}
	for i = 1, VISIBLE_ROWS do
		local row = CreateFrame("Button", nil, list)
		E:Size(row, LIST_WIDTH - 20, ROW_HEIGHT)
		if i == 1 then
			E:Point(row, "TOPLEFT", list, "TOPLEFT", 4, -4)
		else
			E:Point(row, "TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, 0)
		end

		row.highlight = row:CreateTexture(nil, "BACKGROUND")
		row.highlight:SetAllPoints()
		row.highlight:SetTexture(E.media.normTex)
		row.highlight:SetVertexColor(0.3, 0.3, 0.3, 0.5)
		row.highlight:Hide()

		row.name = row:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(row.name, nil, 11, "NONE")
		E:Point(row.name, "LEFT", row, "LEFT", 3, 0)
		row.name:SetJustifyH("LEFT")
		E:Width(row.name, LIST_WIDTH - 90)

		row.skill = row:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(row.skill, nil, 10, "NONE")
		E:Point(row.skill, "RIGHT", row, "RIGHT", -2, 0)
		row.skill:SetJustifyH("RIGHT")

		row.glyphs = row:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(row.glyphs, nil, 10, "NONE")
		E:Point(row.glyphs, "RIGHT", row.skill, "LEFT", -4, 0)

		row:SetScript("OnClick", function()
			if this.recipe then
				RF.selected = this.recipe
				RF:UpdateDetail()
				RF:UpdateRows()
			end
		end)
		row:SetScript("OnEnter", function()
			if this.recipe then this.highlight:Show() end
		end)
		row:SetScript("OnLeave", function()
			if RF.selected ~= this.recipe then this.highlight:Hide() end
		end)

		rows[i] = row
	end
	frame.rows = rows

	local slider = CreateFrame("Slider", nil, list)
	E:Size(slider, 10, VISIBLE_ROWS * ROW_HEIGHT - 4)
	E:Point(slider, "TOPRIGHT", list, "TOPRIGHT", -4, -4)
	E:SetTemplate(slider, "Transparent")
	slider:SetOrientation("VERTICAL")
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	slider:SetValue(0)

	--SetThumbTexture is given a PATH, not a texture object. Both are accepted on
	--later clients; 1.12 is reliable only with the path, and the object form
	--fails silently -- a slider with an invisible thumb still scrolls, so this
	--is the kind of mistake that survives testing.
	slider:SetThumbTexture(E.media.normTex)
	local thumb = slider:GetThumbTexture()
	if thumb then
		thumb:SetVertexColor(unpack(E.media.rgbvaluecolor))
		E:Size(thumb, 8, 28)
	end

	slider:SetScript("OnValueChanged", function()
		RF.offset = floor(this:GetValue() + 0.5)
		RF:UpdateRows()
	end)
	frame.slider = slider

	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", function()
		--arg1 is 1 scrolling up and -1 scrolling down.
		RF:Scroll(-arg1 * 3)
	end)

	frame.list = list
end

function RF:BuildDetail()
	local frame = self.frame

	local detail = CreateFrame("Frame", nil, frame)
	E:Size(detail, WIDTH - TAB_WIDTH - LIST_WIDTH - 20, VISIBLE_ROWS * ROW_HEIGHT + 8)
	E:SetTemplate(detail, "Transparent")
	E:Point(detail, "TOPLEFT", frame.list, "TOPRIGHT", 4, 0)

	detail.header = detail:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(detail.header, nil, 12, "OUTLINE")
	E:Point(detail.header, "TOPLEFT", detail, "TOPLEFT", 6, -6)
	E:Point(detail.header, "TOPRIGHT", detail, "TOPRIGHT", -6, -6)
	detail.header:SetJustifyH("LEFT")

	detail.sub = detail:CreateFontString(nil, "OVERLAY")
	E:FontTemplate(detail.sub, nil, 10, "NONE")
	E:Point(detail.sub, "TOPLEFT", detail.header, "BOTTOMLEFT", 0, -3)
	detail.sub:SetJustifyH("LEFT")
	detail.sub:SetTextColor(0.7, 0.7, 0.7)

	local lines = {}
	for i = 1, DETAIL_LINES do
		local line = detail:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(line, nil, 11, "NONE")
		if i == 1 then
			E:Point(line, "TOPLEFT", detail.sub, "BOTTOMLEFT", 0, -8)
		else
			E:Point(line, "TOPLEFT", lines[i - 1], "BOTTOMLEFT", 0, -1)
		end
		E:Point(line, "RIGHT", detail, "RIGHT", -6, 0)
		line:SetJustifyH("LEFT")
		lines[i] = line
	end
	detail.lines = lines

	frame.detail = detail
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

function RF:Scroll(delta)
	local rows = self.filtered and getn(self.filtered) or 0
	local maxOffset = max(0, rows - VISIBLE_ROWS)
	self.offset = min(maxOffset, max(0, self.offset + delta))
	self.frame.slider:SetValue(self.offset)
	self:UpdateRows()
end

function RF:UpdateTabs()
	local tabs = self.frame.tabs
	for i = 1, getn(tabs) do
		local tab = tabs[i]
		if tab.profession == self.profession then
			tab:SetBackdropBorderColor(unpack(E.media.rgbvaluecolor))
			tab.text:SetTextColor(unpack(E.media.rgbvaluecolor))
		else
			E:SetTemplate(tab, "Transparent")
			tab.text:SetTextColor(0.85, 0.85, 0.85)
		end
	end
end

function RF:UpdateRows()
	local frame = self.frame
	local rows = frame.rows
	local filtered = self.filtered or {}

	for i = 1, VISIBLE_ROWS do
		local row = rows[i]
		local recipe = filtered[i + self.offset]

		if recipe then
			local color = RF.QUALITY_COLOR[recipe.q or 1] or RF.QUALITY_COLOR[1]
			local name = recipe.craft or recipe.name
			--A trailing "?" marks a recipe whose profession the generator had to
			--infer. Never dressed up as certain, because it is not.
			if recipe.unsure then name = name.." |cffff8000?|r" end

			row.name:SetText(name)
			row.name:SetTextColor(color[1], color[2], color[3])
			row.skill:SetText(recipe.skill or "-")
			row.skill:SetTextColor(0.6, 0.6, 0.6)
			row.glyphs:SetText(SourceGlyphs(recipe))
			row.recipe = recipe
			row:Show()

			if self.selected == recipe then
				row.highlight:Show()
				row.highlight:SetVertexColor(unpack(E.media.rgbvaluecolor))
				row.highlight:SetAlpha(0.35)
			else
				row.highlight:Hide()
				row.highlight:SetVertexColor(0.3, 0.3, 0.3, 0.5)
				row.highlight:SetAlpha(1)
			end
		else
			row.recipe = nil
			row.name:SetText("")
			row.skill:SetText("")
			row.glyphs:SetText("")
			row.highlight:Hide()
		end
	end
end

function RF:UpdateDetail()
	local detail = self.frame.detail
	local recipe = self.selected

	for i = 1, DETAIL_LINES do
		detail.lines[i]:SetText("")
	end

	if not recipe then
		detail.header:SetText(L["Select a recipe"])
		detail.header:SetTextColor(0.6, 0.6, 0.6)
		detail.sub:SetText("")
		return
	end

	local color = RF.QUALITY_COLOR[recipe.q or 1] or RF.QUALITY_COLOR[1]
	detail.header:SetText(recipe.name)
	detail.header:SetTextColor(color[1], color[2], color[3])

	local sub = recipe.prof
	if recipe.skill then sub = sub..format(" - %s %d", L["skill"], recipe.skill) end
	if recipe.unsure then sub = sub.." |cffff8000("..L["profession inferred"]..")|r" end
	detail.sub:SetText(sub)

	local at = 0
	local function put(text, header)
		at = at + 1
		if at > DETAIL_LINES then return end
		detail.lines[at]:SetText(text)
		if header then
			detail.lines[at]:SetTextColor(unpack(E.media.rgbvaluecolor))
		else
			detail.lines[at]:SetTextColor(0.9, 0.9, 0.9)
		end
	end

	local lines = self:SourceLines(recipe)
	for i = 1, getn(lines) do
		put(lines[i].text, lines[i].header)
	end

	local reagents = self:ReagentLines(recipe)
	if getn(reagents) > 0 and at + 2 <= DETAIL_LINES then
		put("", false)
		put(L["Reagents"], true)
		for i = 1, getn(reagents) do
			put("|cffb0b0b0"..reagents[i].."|r")
		end
	end
end

function RF:Refresh()
	if not self.frame then return end

	local search = self.frame.search
	local query = search:GetText()
	if query and query ~= "" then search.hint:Hide() else search.hint:Show() end

	self.filtered = self:Filter(self.profession, query, self.filters)

	local total = getn(self.filtered)
	local maxOffset = max(0, total - VISIBLE_ROWS)
	if self.offset > maxOffset then self.offset = maxOffset end

	self.frame.slider:SetMinMaxValues(0, maxOffset)
	self.frame.slider:SetValue(self.offset)

	self.frame.learnable:SetActive(self.filters.learnable)
	self.frame.vendorOnly:SetActive(self.filters.vendorOnly)
	self.frame.phase:SetActive(self.filters.phase ~= RF.PHASE_ORDER.NAXX)
	self.frame.phase.text:SetText(RF.PHASE_LABEL[self.filters.phase])

	self.frame.status:SetText(format(L["%d of %d shown"], total,
		getn(self:Recipes(self.profession))))

	self:UpdateTabs()
	self:UpdateRows()
	self:UpdateDetail()
end
