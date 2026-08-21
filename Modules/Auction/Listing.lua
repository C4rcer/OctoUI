local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local A = E:GetModule("Auction");

--Cache global variables
--Lua functions
local ipairs, type, unpack = ipairs, type, unpack
local sort, getn, tinsert = table.sort, table.getn, table.insert
local format = string.format
local floor, max, min = math.floor, math.max, math.min
local mod = math.mod
--WoW API / Variables
local CreateFrame = CreateFrame

--[[
	The sortable column list every auction tab draws into.

	One widget, four consumers: search results, your postings, your bids and the
	item you are about to sell. Writing it once is the whole reason the later
	tabs are cheap.

	FIXED ROW POOL. Rows are created once and only their text changes. 1.12 never
	frees a frame, so a list that rebuilt its rows per search would leak for the
	session -- the same reason the recipe finder works this way.

	COLUMN WIDTHS COME FROM GetWidth, NOT GetRight-minus-GetLeft. That difference
	is not stylistic: aux computes its column weight from
	`contentFrame:GetRight() - contentFrame:GetLeft()`, and when that frame's rect
	has not resolved yet both return nil and the whole listing dies at load with
	"attempt to perform arithmetic on a nil value" -- which is exactly the error
	sitting in the log right now. GetWidth answers from the frame's own size, and
	every path here has a fallback anyway, so an unresolved rect costs a column
	layout that corrects itself on the next refresh rather than an addon that
	never finishes loading.
]]

local ROW_HEIGHT = 14
local HEADER_HEIGHT = 16

local function SortRows(listing)
	local column = listing.columns[listing.sortColumn]
	if not (column and listing.data) then return end

	local key, descending = column.key, listing.sortDescending
	local compare = column.compare

	sort(listing.data, function(a, b)
		local av, bv = a[key], b[key]

		if compare then return compare(a, b, descending) end

		--nil sorts last whichever way the column is pointing, so an auction with
		--no buyout never displaces a real price at the top of the list.
		if av == nil and bv == nil then return false end
		if av == nil then return false end
		if bv == nil then return true end

		if descending then return av > bv end
		return av < bv
	end)
end

local function LayoutColumns(listing)
	--Fallback keeps a column layout possible before the frame has a resolved size.
	local width = listing:GetWidth()
	if not width or width <= 0 then width = listing.fallbackWidth or 600 end
	width = width - 16 --slider gutter

	local weight = 0
	for _, column in ipairs(listing.columns) do
		weight = weight + (column.width or 1)
	end
	if weight <= 0 then return end

	local x = 0
	for index, column in ipairs(listing.columns) do
		local w = floor((column.width or 1) / weight * width)
		listing.headers[index].width = w
		listing.headers[index]:ClearAllPoints()
		E:Point(listing.headers[index], "LEFT", listing.header, "LEFT", x, 0)
		E:Width(listing.headers[index], w)

		for r = 1, getn(listing.rows) do
			local cell = listing.rows[r].cells[index]
			cell:ClearAllPoints()
			E:Point(cell, "LEFT", listing.rows[r], "LEFT", x + 2, 0)
			E:Width(cell, w - 4)
		end

		x = x + w
	end
end

function A:CreateListing(parent, columns, rowCount, fallbackWidth)
	local listing = CreateFrame("Frame", nil, parent)
	listing.columns = columns
	listing.rows = {}
	listing.headers = {}
	listing.data = nil
	listing.offset = 0
	listing.sortColumn = 1
	listing.sortDescending = false
	listing.fallbackWidth = fallbackWidth
	listing.visibleRows = rowCount

	local header = CreateFrame("Frame", nil, listing)
	E:Height(header, HEADER_HEIGHT)
	E:Point(header, "TOPLEFT", listing, "TOPLEFT", 0, 0)
	E:Point(header, "TOPRIGHT", listing, "TOPRIGHT", -16, 0)
	listing.header = header

	for index, column in ipairs(columns) do
		local button = CreateFrame("Button", nil, header)
		E:Height(button, HEADER_HEIGHT)
		button.text = button:CreateFontString(nil, "OVERLAY")
		E:FontTemplate(button.text, nil, 10, "NONE")
		button.text:SetAllPoints()
		button.text:SetJustifyH(column.justify or "LEFT")
		button.text:SetText(column.label or "")
		button.text:SetTextColor(0.8, 0.8, 0.8)
		button.index = index

		button:SetScript("OnClick", function()
			if listing.sortColumn == this.index then
				listing.sortDescending = not listing.sortDescending
			else
				listing.sortColumn = this.index
				listing.sortDescending = column.defaultDescending and true or false
			end
			listing:Refresh()
		end)
		button:SetScript("OnEnter", function() this.text:SetTextColor(unpack(E.media.rgbvaluecolor)) end)
		button:SetScript("OnLeave", function() this.text:SetTextColor(0.8, 0.8, 0.8) end)

		listing.headers[index] = button
	end

	for r = 1, rowCount do
		local row = CreateFrame("Button", nil, listing)
		E:Height(row, ROW_HEIGHT)
		if r == 1 then
			E:Point(row, "TOPLEFT", header, "BOTTOMLEFT", 0, -2)
		else
			E:Point(row, "TOPLEFT", listing.rows[r - 1], "BOTTOMLEFT", 0, 0)
		end
		E:Point(row, "RIGHT", listing, "RIGHT", -16, 0)

		row.highlight = row:CreateTexture(nil, "BACKGROUND")
		row.highlight:SetAllPoints()
		row.highlight:SetTexture(E.media.normTex)
		row.highlight:SetVertexColor(0.3, 0.3, 0.3, 0.4)
		row.highlight:Hide()

		row.cells = {}
		for index, column in ipairs(columns) do
			local cell = row:CreateFontString(nil, "OVERLAY")
			E:FontTemplate(cell, nil, 10, "NONE")
			cell:SetJustifyH(column.justify or "LEFT")
			row.cells[index] = cell
		end

		row:SetScript("OnEnter", function()
			if this.entry then this.highlight:Show() end
			if this.entry and listing.OnEnter then listing.OnEnter(this.entry, this) end
		end)
		row:SetScript("OnLeave", function()
			this.highlight:Hide()
			if listing.OnLeave then listing.OnLeave() end
		end)
		row:SetScript("OnClick", function()
			if this.entry and listing.OnClick then listing.OnClick(this.entry, arg1) end
		end)

		listing.rows[r] = row
	end

	local slider = CreateFrame("Slider", nil, listing)
	E:Width(slider, 10)
	E:Point(slider, "TOPRIGHT", header, "BOTTOMRIGHT", 14, -2)
	E:Point(slider, "BOTTOM", listing, "BOTTOM", 0, 0)
	E:SetTemplate(slider, "Transparent")
	slider:SetOrientation("VERTICAL")
	slider:SetMinMaxValues(0, 0)
	slider:SetValueStep(1)
	slider:SetValue(0)
	--Path, not a texture object: 1.12 accepts only the path reliably, and the
	--object form fails silently, leaving an invisible thumb on a list that still
	--scrolls -- a mistake that survives testing.
	slider:SetThumbTexture(E.media.normTex)
	local thumb = slider:GetThumbTexture()
	if thumb then
		thumb:SetVertexColor(unpack(E.media.rgbvaluecolor))
		E:Size(thumb, 8, 24)
	end
	slider:SetScript("OnValueChanged", function()
		listing.offset = floor(this:GetValue() + 0.5)
		listing:UpdateRows()
	end)
	listing.slider = slider

	listing:EnableMouseWheel(true)
	listing:SetScript("OnMouseWheel", function()
		--arg1 is 1 up and -1 down.
		listing:Scroll(-arg1 * 3)
	end)

	function listing:SetData(rows)
		self.data = rows
		self.offset = 0
		self:Refresh()
	end

	function listing:Scroll(delta)
		local total = self.data and getn(self.data) or 0
		local maxOffset = max(0, total - self.visibleRows)
		self.offset = min(maxOffset, max(0, self.offset + delta))
		self.slider:SetValue(self.offset)
		self:UpdateRows()
	end

	function listing:UpdateRows()
		local data = self.data or {}
		for r = 1, self.visibleRows do
			local row = self.rows[r]
			local entry = data[r + self.offset]
			row.entry = entry

			if entry then
				for index, column in ipairs(self.columns) do
					local value = entry[column.key]
					if column.format then value = column.format(value, entry) end
					row.cells[index]:SetText(value ~= nil and value or "")
					if column.color then
						local cr, cg, cb = column.color(entry)
						row.cells[index]:SetTextColor(cr or 1, cg or 1, cb or 1)
					else
						row.cells[index]:SetTextColor(0.9, 0.9, 0.9)
					end
				end
				row:Show()
			else
				for index = 1, getn(self.columns) do
					row.cells[index]:SetText("")
				end
				row.highlight:Hide()
			end
		end
	end

	function listing:Refresh()
		SortRows(self)
		LayoutColumns(self)

		for index, column in ipairs(self.columns) do
			local arrow = ""
			if index == self.sortColumn then
				arrow = self.sortDescending and " |cffffcc00v|r" or " |cffffcc00^|r"
			end
			self.headers[index].text:SetText((column.label or "")..arrow)
		end

		local total = self.data and getn(self.data) or 0
		local maxOffset = max(0, total - self.visibleRows)
		if self.offset > maxOffset then self.offset = maxOffset end
		self.slider:SetMinMaxValues(0, maxOffset)
		self.slider:SetValue(self.offset)

		self:UpdateRows()
	end

	return listing
end

--Money as g/s/c, the one formatter every auction column needs.
function A:Money(copper)
	if not copper or copper <= 0 then return "" end

	local gold = floor(copper / 10000)
	local silver = floor(mod(copper, 10000) / 100)
	local bronze = mod(copper, 100)
	local parts = {}

	if gold > 0 then tinsert(parts, format("|cffffd700%d|rg", gold)) end
	if silver > 0 then tinsert(parts, format("|cffc7c7cf%d|rs", silver)) end
	if bronze > 0 or getn(parts) == 0 then
		tinsert(parts, format("|cffeda55f%d|rc", bronze))
	end

	local text = parts[1]
	for i = 2, getn(parts) do text = text.." "..parts[i] end
	return text
end
