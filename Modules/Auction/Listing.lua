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

--Rows were 14 tall with 10pt text, which is small enough that a long item name
--wrapped onto a second line and spilled into the row below it. Height and font go
--together: raising one without the other just centres small text in a big gap.
local ROW_HEIGHT = 18
local HEADER_HEIGHT = 18

local function SortRows(listing)
	local column = listing.columns[listing.sortColumn]
	if not (column and listing.data) then return end

	local key, descending = column.key, listing.sortDescending
	local compare = column.compare

	sort(listing.data, function(a, b)
		local av, bv = a[key], b[key]

		if compare then return compare(a, b, descending) end

		--[[
			Nothing sorts last, whichever way the column points, so an auction with no
			buyout never displaces a real price at the top of the list.

			"Nothing" means nil OR zero on a column marked emptyLast. The original code
			only handled nil, and prices are stored as 0 rather than nil precisely so
			that "no buyout" cannot read as "free" -- with the result that sorting by
			cheapest buyout put every unbuyable auction FIRST, which is the exact
			failure the zero was chosen to avoid.
		]]
		if column.emptyLast then
			local aEmpty = (av == nil or av == 0)
			local bEmpty = (bv == nil or bv == 0)
			if aEmpty and bEmpty then return false end
			if aEmpty then return false end
			if bEmpty then return true end
		end

		if av == nil and bv == nil then return false end
		if av == nil then return false end
		if bv == nil then return true end

		if descending then return av > bv end
		return av < bv
	end)
end

local function LayoutColumns(listing)
	--[[
		THE WIDEST OF THE THREE ANSWERS WINS, and that is not paranoia.

		Measured on this client: a window 780 wide, a page anchored inside it at +8/-8,
		and a listing anchored to that page at 0/0 -- and the listing reports a width of
		382. Exactly half. So does its parent. Whatever causes that, GetWidth cannot be
		trusted as the authority here, and trusting it laid every column into the left
		half of the frame with the prices truncated and the right half empty.

		The CALLER knows the answer. It anchored the frame, so it knows the space the
		listing occupies, and it passes that in as fallbackWidth. Taking the largest of
		measured, parent and caller means a genuine measurement still wins when the frame
		is bigger than expected, while a short reading cannot squash the layout.
	]]
	local width = listing:GetWidth() or 0

	local parent = listing:GetParent()
	local parentWidth = (parent and parent.GetWidth and parent:GetWidth()) or 0
	if parentWidth > width then width = parentWidth end

	local declared = listing.fallbackWidth or 600
	if declared > width then width = declared end

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
		E:FontTemplate(button.text, nil, 11, "NONE")
		button.text:SetAllPoints()
		button.text:SetJustifyH(column.justify or "LEFT")
		button.text:SetText(column.label or "")
		button.text:SetTextColor(0.8, 0.8, 0.8)
		button.index = index

		--[[
			The column is looked up by index, NOT captured from the loop.

			Capturing it read nil by the time the handler ran, so clicking any header
			other than the current sort threw "attempt to index a nil value" from
			`column.defaultDescending`. Clicking the CURRENT one took the toggle branch
			and never touched it, which is why sorting appeared to work at all.

			`this.index` is set on the button itself and is always right, and the columns
			table is the listing's own. Neither depends on what a closure created inside
			a loop body kept hold of.
		]]
		button:SetScript("OnClick", function()
			local col = listing.columns[this.index]

			if listing.sortColumn == this.index then
				listing.sortDescending = not listing.sortDescending
			else
				listing.sortColumn = this.index
				listing.sortDescending = (col and col.defaultDescending) and true or false
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

		--Buttons only listen for the left button by default, so a right click never
		--reached OnClick and the second action on a row was unreachable.
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		row.highlight = row:CreateTexture(nil, "BACKGROUND")
		row.highlight:SetAllPoints()
		row.highlight:SetTexture(E.media.normTex)
		row.highlight:SetVertexColor(0.3, 0.3, 0.3, 0.4)
		row.highlight:Hide()

		row.cells = {}
		for index, column in ipairs(columns) do
			local cell = row:CreateFontString(nil, "OVERLAY")
			E:FontTemplate(cell, nil, 12, "NONE")
			cell:SetJustifyH(column.justify or "LEFT")
			--Fixed height, so a name too long for its column is clipped rather than
			--wrapped onto a second line that overlaps the next row.
			E:Height(cell, ROW_HEIGHT)
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

	--[[
		Same data, new rows appended, WITHOUT jumping back to the top.

		A scan that only shows its results at the end is twenty seconds of empty list
		on a forty-page search, and the answer is usually on the first page. So each
		page refreshes the listing as it lands -- but SetData resets the scroll offset,
		and a list that snapped back to the top every 0.4s while somebody was reading
		it would be worse than showing nothing at all.

		Refresh re-sorts, so a row can still move under the cursor as cheaper auctions
		arrive. That is the list being correct rather than the list being unstable:
		the sort is the entire point of it, and a scan is over in seconds.
	]]
	function listing:UpdateData(rows)
		self.data = rows
		self:Refresh()
	end

	function listing:Scroll(delta)
		local total = self.view and getn(self.view) or 0
		local maxOffset = max(0, total - self.visibleRows)
		self.offset = min(maxOffset, max(0, self.offset + delta))
		self.slider:SetValue(self.offset)
		self:UpdateRows()
	end

	--[[
		The rows actually on screen, after `filter`.

		Kept as a separate array rather than by pruning `data`, because the scan owns
		`data` and keeps appending to it while a scan runs -- and because the price
		database is fed from every row scanned, not merely the ones being displayed. A
		filter is a view of the results, never a decision about what was collected.

		Reused in place across refreshes. A search that refreshes on every page would
		otherwise throw away and rebuild an array of two thousand entries forty times.
	]]
	local function BuildView(self)
		local data = self.data
		if not data then self.view = nil return end

		if not self.filter then
			self.view = data
			return
		end

		local view = (self.view ~= data) and self.view or {}
		local n = 0

		for i = 1, getn(data) do
			local entry = data[i]
			if self.filter(entry) then
				n = n + 1
				view[n] = entry
			end
		end

		for i = getn(view), n + 1, -1 do view[i] = nil end

		self.view = view
	end

	function listing:UpdateRows()
		local data = self.view or {}
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
		BuildView(self)
		LayoutColumns(self)

		for index, column in ipairs(self.columns) do
			local arrow = ""
			if index == self.sortColumn then
				arrow = self.sortDescending and " |cffffcc00v|r" or " |cffffcc00^|r"
			end
			self.headers[index].text:SetText((column.label or "")..arrow)
		end

		local total = self.view and getn(self.view) or 0
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
