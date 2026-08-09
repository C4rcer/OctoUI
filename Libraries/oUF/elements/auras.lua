--[[
# Element: Auras

Handles creation and updating of aura icons.

## Widget

Auras   - A Frame to hold `Button`s representing both buffs and debuffs.
Buffs   - A Frame to hold `Button`s representing buffs.
Debuffs - A Frame to hold `Button`s representing debuffs.

## Notes

At least one of the above widgets must be present for the element to work.

## Options

.disableMouse       - Disables mouse events (boolean)
.size               - Aura icon size. Defaults to 16 (number)
.spacing            - Spacing between each icon. Defaults to 0 (number)
.['spacing-x']      - Horizontal spacing between each icon. Takes priority over `spacing` (number)
.['spacing-y']      - Vertical spacing between each icon. Takes priority over `spacing` (number)
.['growth-x']       - Horizontal growth direction. Defaults to 'RIGHT' (string)
.['growth-y']       - Vertical growth direction. Defaults to 'UP' (string)
.initialAnchor      - Anchor point for the icons. Defaults to 'BOTTOMLEFT' (string)
.filter             - Custom filter list for auras to display. Defaults to 'HELPFUL' for buffs and 'HARMFUL' for
                      debuffs (string)

## Options Auras

.numBuffs     - The maximum number of buffs to display. Defaults to 32 (number)
.numDebuffs   - The maximum number of debuffs to display. Defaults to 40 (number)
.numTotal     - The maximum number of auras to display. Prioritizes buffs over debuffs. Defaults to the sum of
                .numBuffs and .numDebuffs (number)
.gap          - Controls the creation of an invisible icon between buffs and debuffs. Defaults to false (boolean)
.buffFilter   - Custom filter list for buffs to display. Takes priority over `filter` (string)
.debuffFilter - Custom filter list for debuffs to display. Takes priority over `filter` (string)

## Options Buffs

.num - Number of buffs to display. Defaults to 32 (number)

## Options Debuffs

.num - Number of debuffs to display. Defaults to 40 (number)

## Attributes

button.filter   - the filter list used to determine the visibility of the aura (string)
button.isDebuff - indicates if the button holds a debuff (boolean)

## Examples

    -- Position and size
    local Buffs = CreateFrame('Frame', nil, self)
    Buffs:SetPoint('RIGHT', self, 'LEFT')
    Buffs:SetSize(16 * 2, 16 * 16)

    -- Register with oUF
    self.Buffs = Buffs
--]]

local ns = oUF
local oUF = ns.oUF

local tinsert, getn, tsort = table.insert, table.getn, table.sort
local floor, min, mod = math.floor, math.min, math.mod

local CreateFrame = CreateFrame
local UnitAura = UnitAura
local GetPlayerBuff = GetPlayerBuff
local GetPlayerBuffTexture = GetPlayerBuffTexture
local GetPlayerBuffApplications = GetPlayerBuffApplications
local GetPlayerBuffDispelType = GetPlayerBuffDispelType
local GetPlayerBuffTimeLeft = GetPlayerBuffTimeLeft
local GetTime = GetTime

local VISIBLE = 1
local HIDDEN = 0

--1.12 has no aura duration for any unit but the player: UnitBuff/UnitDebuff simply do
--not return one, so this addon's UnitAura polyfill hands back texture, count and
--dispel type and nothing else. LibDebuff reconstructs durations for debuffs *the
--player applied* out of the combat log plus the bundled duration tables, haste
--adjusted -- the same source the nameplate DoT timers run on. Borrowing it here is the
--only way a target frame can show a debuff timer at all.
--
--It cannot recover anything for buffs on another unit, or for a debuff somebody else
--applied. That information is not on the client, and a plausible-looking number in its
--place would be worse than none.
--
--Resolved on demand rather than cached: this file loads long before the NamePlates
--module exists.
--ONE SCAN PER DEBUFF PER PASS.
--
--lib:UnitDebuff resolves the spell name through a tooltip scan, which is the expensive call
--in this file. Both consumers below want it for the same debuff in the same update -- the
--ordering pass to find out whose it is, and the icon update to get its timer -- so the
--result is held for the length of one filterIcons call and handed to whichever asks second.
--Without this, ordering would double the scan count on every aura update.
--
--Cleared at the top of filterIcons rather than keyed by time: auras change between passes
--and a stale entry would show the wrong timer, which is worse than scanning again.
local scanCache = {}

local function ClearScanCache()
	for index in pairs(scanCache) do
		scanCache[index] = nil
	end
end

local function ScanDebuff(unit, index)
	local cached = scanCache[index]
	if cached then return cached end

	local engine = _G.ElvUI and _G.ElvUI[1]
	local module = engine and engine.GetModule and engine:GetModule("NamePlates", true)
	local lib = module and module.LibDebuff
	if not (lib and lib.UnitDebuff) then return nil end

	--Mirrors the modern UnitAura shape: effect, rank, texture, stacks, dtype, duration,
	--timeleft, caster. pcall's status sits in front, so the effect is second and the caster
	--ninth. Wrapped because this runs on every aura update, and a fault here should cost one
	--icon rather than the whole aura display.
	local ok, effect, _, _, _, _, duration, timeleft, caster = pcall(lib.UnitDebuff, lib, unit, index)
	if not ok then return nil end

	cached = {effect = effect, duration = duration, timeleft = timeleft, caster = caster}
	scanCache[index] = cached

	return cached
end

local function TrackedDebuff(unit, index)
	local scan = ScanDebuff(unit, index)
	if not scan then return end

	if scan.duration and scan.timeleft and scan.timeleft > 0 then
		return scan.duration, GetTime() + scan.timeleft
	end
end

local function UpdateTooltip(self)
	if self:GetParent().__owner.unit == "player" then
		local index = GetPlayerBuff(self:GetID() - 1, self.filter)
		GameTooltip:SetPlayerBuff(index)
	elseif self.filter == 'HELPFUL' then
		GameTooltip:SetUnitBuff(self:GetParent().__owner.unit, self:GetID(), self.filter)
	else
		GameTooltip:SetUnitDebuff(self:GetParent().__owner.unit, self:GetID(), self.filter)
	end
end

local function onEnter(self)
	if not self:IsVisible() then return end

	GameTooltip:SetOwner(self, 'ANCHOR_BOTTOMRIGHT')
	self:UpdateTooltip()
end

local function onLeave()
	GameTooltip:Hide()
end

local function createAuraIcon(element, index)
	local button = CreateFrame('Button', '$parentButton' .. index, element)
	button:RegisterForClicks('RightButtonUp')

	local icon = button:CreateTexture(nil, 'BORDER')
	icon:SetAllPoints()

	local count = button:CreateFontString(nil, 'OVERLAY', 'NumberFontNormal')
	count:SetPoint('BOTTOMRIGHT', button, 'BOTTOMRIGHT', -1, 0)

	local overlay = button:CreateTexture(nil, 'OVERLAY')
	overlay:SetTexture([[Interface\Buttons\UI-Debuff-Overlays]])
	overlay:SetAllPoints()
	overlay:SetTexCoord(.296875, .5703125, 0, .515625)
	button.overlay = overlay

	button.UpdateTooltip = UpdateTooltip
	button:SetScript('OnEnter', function() onEnter(this) end)
	button:SetScript('OnLeave', onLeave)

	button.icon = icon
	button.count = count

	--[[ Callback: Auras:PostCreateIcon(button)
	Called after a new aura button has been created.

	* self   - the widget holding the aura buttons
	* button - the newly created aura button (Button)
	--]]
	if element.PostCreateIcon then element:PostCreateIcon(button) end

	return button
end

local function customFilter(element, unit, button, texture)
	if texture then return true end
end

local function updateIcon(element, unit, index, offset, filter, isDebuff, visible)
	local texture, count, dispelType, duration, expiration

	if unit == "player" then
		local idx = GetPlayerBuff(index - 1, filter)
		--if idx < 0 then return end
		--index = idx
		texture = GetPlayerBuffTexture(idx)
		count = GetPlayerBuffApplications(idx)
		dispelType = GetPlayerBuffDispelType(idx)

		--GetPlayerBuffTimeLeft is the time *remaining*; 1.12 has no API for an aura's
		--full duration, and the consumers here only ever test duration against zero,
		--so remaining is fine for it. The timer is a different matter: UpdateAuraTimer
		--counts down from an absolute expiry, and this branch never set one, so player
		--auras got no countdown at all. This is the only unit the client will give a
		--time for -- everything else depends on the LibDebuff fallback below.
		duration = GetPlayerBuffTimeLeft(idx)
		expiration = (duration and duration > 0) and (GetTime() + duration) or 0
	else
		texture, count, dispelType, duration, expiration = UnitAura(unit, index, filter)

		--Only debuffs, and only when the polyfill gave us nothing, so this costs a
		--tooltip scan just where there is something to gain
		if texture and isDebuff and not duration then
			duration, expiration = TrackedDebuff(unit, index)
		end
	end

	if element.forceShow then
		texture = 'Interface\\Icons\\Spell_Holy_DivineSpirit'
		count, dispelType = 5, 'Magic'
	end

	if texture then
		local position = visible + offset + 1
		local button = element[position]
		if not button then
			--[[ Override: Auras:CreateIcon(position)
			Used to create the aura button at a given position.

			* self     - the widget holding the aura buttons
			* position - the position at which the aura button is to be created (number)

			## Returns

			* button - the button used to represent the aura (Button)
			--]]
			button = (element.CreateIcon or createAuraIcon) (element, position)

			tinsert(element, button)
			element.createdIcons = element.createdIcons + 1
		end

		button.filter = filter
		button.isDebuff = isDebuff
		--Needed by any CustomFilter that has to resolve a name: this client's UnitAura
		--does not return one, so the only route is a tooltip scan, and that takes the
		--aura's index.
		button.index = index

		--Stashed on the button here as well as in UF:AuraFilter. The filter is the natural
		--home for them, but it only runs when one is installed -- and never in forceShow --
		--while PostUpdateAura reads them unconditionally. Without the duration and
		--expiration its timer block, `if button.expiration and button.duration`, is
		--unreachable and auras lose their countdown; without dtype every debuff border
		--draws in the "none" colour, which in the config preview is exactly the case the
		--fabricated 'Magic' below is meant to be demonstrating.
		button.duration = duration
		button.expiration = expiration
		button.dtype = dispelType

		--The player is the one unit the client will quote a live remaining time for, and
		--GetPlayerBuffTimeLeft wants the GetPlayerBuff id, not this loop's display index.
		--Stashed so the timer can re-read it instead of counting down a snapshot: a buff
		--refreshed without the aura set changing fires no event, so nothing would ever
		--correct that snapshot. Nil for every other unit, which has no such API.
		button.playerBuffIndex = (unit == "player") and GetPlayerBuff(index - 1, filter) or nil

		--[[ Override: Auras:CustomFilter(unit, button, ...)
		Defines a custom filter that controls if the aura button should be shown.

		* self   - the widget holding the aura buttons
		* unit   - the unit on which the aura is cast (string)
		* button - the button displaying the aura (Button)
		* ...    - the return values from [UnitAura](http://wowprogramming.com/docs/api/UnitAura)

		## Returns

		* show - indicates whether the aura button should be shown (boolean)
		--]]
		local show = true
		if not element.forceShow then
			show = (element.CustomFilter or customFilter) (element, unit, button, texture, count, dispelType, duration, expiration)
		end

		if show then
			if button.overlay then
				if (isDebuff and element.showDebuffType) or (not isDebuff and element.showBuffType) or element.showType then
					local color = DebuffTypeColor[dispelType] or DebuffTypeColor.none

					button.overlay:SetVertexColor(color.r, color.g, color.b)
					button.overlay:Show()
				else
					button.overlay:Hide()
				end
			end

			if button.icon then button.icon:SetTexture(texture) end
			if button.count then button.count:SetText(count > 1 and count) end

			local size = element.size or 16
			button:SetWidth(size)
			button:SetHeight(size)

			button:EnableMouse(not element.disableMouse)
			button:SetID(index)
			button:Show()

			--[[ Callback: Auras:PostUpdateIcon(unit, button, index, position)
			Called after the aura button has been updated.

			* self     - the widget holding the aura buttons
			* unit     - the unit on which the aura is cast (string)
			* button   - the updated aura button (Button)
			* index    - the index of the aura (number)
			* position - the actual position of the aura button (number)
			--]]
			if element.PostUpdateIcon then
				element:PostUpdateIcon(unit, button, index, position)
			end

			return VISIBLE
		else
			return HIDDEN
		end
	end
end

local function SetPosition(element, from, to)
	local sizex = (element.size or 16) + (element['spacing-x'] or element.spacing or 0)
	local sizey = (element.size or 16) + (element['spacing-y'] or element.spacing or 0)
	local anchor = element.initialAnchor or 'BOTTOMLEFT'
	local growthx = (element['growth-x'] == 'LEFT' and -1) or 1
	local growthy = (element['growth-y'] == 'DOWN' and -1) or 1
	local cols = floor(element:GetWidth() / sizex + 0.5)

	for i = from, to do
		local button = element[i]

		-- Bail out if the to range is out of scope.
		if(not button) then break end
		local col = mod((i - 1), cols)
		local row = floor((i - 1) / cols)

		button:ClearAllPoints()
		button:SetPoint(anchor, element, anchor, col * sizex * growthx, row * sizey * growthy)
	end
end

--[[
	WHICH AURAS SURVIVE THE SLOT LIMIT.

	The loop below used to walk aura indices 1, 2, 3... and stop the moment it had filled its
	slots, so the frame showed the first N auras in the CLIENT'S index order and nothing else
	was considered. Put more debuffs on a mob than there are slots and whichever of the
	player's own sat at a higher index were never drawn at all -- reported as DoTs vanishing
	once enough debuffs are up. Sorting afterwards cannot fix that: an aura that lost the race
	never became a button to sort.

	So when, and ONLY when, there are more auras than slots, the indices are ranked first and
	the player's own go to the front. Ranking costs a tooltip scan per aura to resolve a name
	for LibDebuff, which is why it is skipped entirely while everything fits -- the common
	case pays nothing, and the cost only appears in the case the player is complaining about.

	Ownership comes from LibDebuff's caster, the same source the nameplate timers use. It is
	only available for DEBUFFS on a unit, because this client's UnitAura returns texture,
	count and dispel type and no caster at all. Buffs, and everything on the player frame,
	therefore keep index order -- see the note in TrackedDebuff above.
]]
local MAX_SCAN = 40

--Returns the spell name when the player cast this debuff, and nil otherwise. The NAME is
--what the ordering below needs, not merely a yes/no; see PriorityOrder.
local function PlayerAuraName(unit, index)
	local scan = ScanDebuff(unit, index)
	if not (scan and scan.caster == "player") then return nil end

	return scan.effect or ""
end

local function PriorityOrder(unit, filter, isDebuff, limit)
	--NEVER THE PLAYER. updateIcon addresses player auras through GetPlayerBuff(index - 1),
	--a different index space from UnitAura's, and mixing the two is what made the aura
	--blacklist hide the wrong icon once already. There is also no caster for anything on the
	--player, so there is nothing to rank by even if the indices lined up.
	if unit == "player" then return nil end

	--Only debuffs carry a caster on this client, so a buff row cannot be ranked either.
	if not isDebuff then return nil end

	local present = 0
	for index = 1, MAX_SCAN do
		if not UnitAura(unit, index, filter) then break end
		present = present + 1
	end

	--NO "everything fits" SHORTCUT, deliberately. Ordering matters even when nothing is
	--dropped: the client's aura list is contiguous, so a debuff expiring at index 1 renumbers
	--every debuff after it and the icons all slide one place left. Ranking on every pass is
	--what keeps ours in the same spot while other people's come and go, which is the whole
	--request. The scan is shared with TrackedDebuff, so this costs no extra tooltip work.
	if present == 0 then return nil end

	local mine, theirs, name = {}, {}, {}
	for index = 1, present do
		local effect = PlayerAuraName(unit, index)
		if effect then
			name[index] = effect
			tinsert(mine, index)
		else
			tinsert(theirs, index)
		end
	end

	--[[
		SORTED BY SPELL NAME, which is the only key here that does not move.

		The obvious key is aura index, and it is wrong: the client renumbers its aura list
		whenever anything is added or removed, so somebody else's debuff falling off renum-
		bers ours and the icons swap places under the cursor.

		The next idea is application order, computed from duration minus time left. That
		appends a new DoT to the right of the group, which is exactly what was asked for --
		but a REFRESH resets the start time, so re-applying Corruption would fling it from
		the left of the group to the right. For a warlock refreshing constantly that is the
		worst possible behaviour, and it is the behaviour being complained about.

		A name is stable across refreshes, across other people's auras coming and going, and
		across the client renumbering. Corruption is always left of Curse of Agony. The cost
		is that a newly applied DoT inserts alphabetically rather than on the right-hand end,
		so it lands in a fixed place instead of the newest place. Say if you would rather
		have application order and accept the refresh jump; it is one comparator.
	]]
	tsort(mine, function(a, b)
		if name[a] == name[b] then return a < b end
		return name[a] < name[b]
	end)

	--Ours first, then everyone else's in the client's own order -- so their debuffs are the
	--ones that shuffle to make room, which is the point.
	for i = 1, getn(theirs) do
		tinsert(mine, theirs[i])
	end

	return mine
end

local function filterIcons(element, unit, filter, limit, isDebuff, offset, dontHide)
	if not offset then offset = 0 end

	--Both passes below read the same debuffs; see ScanDebuff.
	ClearScanCache()

	local order = PriorityOrder(unit, filter, isDebuff, limit)
	local index = 1
	local visible = 0
	local hidden = 0
	while visible < limit do
		--`order` is nil whenever everything fits, and the walk is then exactly what it was.
		local auraIndex
		if order then
			auraIndex = order[index]
		else
			auraIndex = index
		end

		if not auraIndex then break end

		local result = updateIcon(element, unit, auraIndex, offset, filter, isDebuff, visible)
		if not result then
			break
		elseif result == VISIBLE then
			visible = visible + 1
		elseif result == HIDDEN then
			hidden = hidden + 1
		end

		index = index + 1
	end

	if not dontHide then
		for i = visible + offset + 1, getn(element) do
			element[i]:Hide()
		end
	end

	return visible, hidden
end

local function UpdateAuras(self, event, unit)
	if event == "PLAYER_AURAS_CHANGED" then unit = "player" end

	if self.unit ~= unit then return end

	local auras = self.Auras
	if auras then
		--[[ Callback: Auras:PreUpdate(unit)
		Called before the element has been updated.

		* self - the widget holding the aura buttons
		* unit - the unit for which the update has been triggered (string)
		--]]
		if auras.PreUpdate then auras:PreUpdate(unit) end

		local numBuffs = auras.numBuffs or 32
		local numDebuffs = auras.numDebuffs or 40
		local max = auras.numTotal or numBuffs + numDebuffs

		local visibleBuffs, hiddenBuffs = filterIcons(auras, unit, auras.buffFilter or auras.filter or 'HELPFUL', min(numBuffs, max), nil, 0, true)

		local hasGap
		if visibleBuffs ~= 0 and auras.gap then
			hasGap = true
			visibleBuffs = visibleBuffs + 1

			local button = auras[visibleBuffs]
			if not button then
				button = (auras.CreateIcon or createAuraIcon) (auras, visibleBuffs)
				tinsert(auras, button)
				auras.createdIcons = auras.createdIcons + 1
			end

			-- Prevent the button from displaying anything.
			if button.icon then button.icon:SetTexture() end
			if button.overlay then button.overlay:Hide() end
			if button.stealable then button.stealable:Hide() end
			if button.count then button.count:SetText() end

			button:EnableMouse(false)
			button:Show()

			--[[ Callback: Auras:PostUpdateGapIcon(unit, gapButton, visibleBuffs)
			Called after an invisible aura button has been created. Only used by Auras when the `gap` option is enabled.

			* self         - the widget holding the aura buttons
			* unit         - the unit that has the invisible aura button (string)
			* gapButton    - the invisible aura button (Button)
			* visibleBuffs - the number of currently visible aura buttons (number)
			--]]
			if(auras.PostUpdateGapIcon) then
				auras:PostUpdateGapIcon(unit, button, visibleBuffs)
			end
		end

		local visibleDebuffs, hiddenDebuffs = filterIcons(auras, unit, auras.debuffFilter or auras.filter or 'HARMFUL', min(numDebuffs, max - visibleBuffs), true, visibleBuffs)
		auras.visibleDebuffs = visibleDebuffs

		if hasGap and visibleDebuffs == 0 then
			auras[visibleBuffs]:Hide()
			visibleBuffs = visibleBuffs - 1
		end

		auras.visibleBuffs = visibleBuffs
		auras.visibleAuras = auras.visibleBuffs + auras.visibleDebuffs

		local fromRange, toRange
		--[[ Callback: Auras:PreSetPosition(max)
		Called before the aura buttons have been (re-)anchored.

		* self - the widget holding the aura buttons
		* max  - the maximum possible number of aura buttons (number)

		## Returns

		* from - the offset of the first aura button to be (re-)anchored (number)
		* to   - the offset of the last aura button to be (re-)anchored (number)
		--]]
		if auras.PreSetPosition then
			fromRange, toRange = auras:PreSetPosition(max)
		end

		if fromRange or auras.createdIcons > auras.anchoredIcons then
			--[[ Override: Auras:SetPosition(from, to)
			Used to (re-)anchor the aura buttons.
			Called when new aura buttons have been created or if :PreSetPosition is defined.

			* self - the widget that holds the aura buttons
			* from - the offset of the first aura button to be (re-)anchored (number)
			* to   - the offset of the last aura button to be (re-)anchored (number)
			--]]
			(auras.SetPosition or SetPosition) (auras, fromRange or auras.anchoredIcons + 1, toRange or auras.createdIcons)
			auras.anchoredIcons = auras.createdIcons
		end

		--[[ Callback: Auras:PostUpdate(unit)
		Called after the element has been updated.

		* self - the widget holding the aura buttons
		* unit - the unit for which the update has been triggered (string)
		--]]
		if auras.PostUpdate then auras:PostUpdate(unit) end
	end

	local buffs = self.Buffs
	if buffs then
		if buffs.PreUpdate then buffs:PreUpdate(unit) end

		local numBuffs = buffs.num or 32
		local visibleBuffs, hiddenBuffs = filterIcons(buffs, unit, buffs.filter or 'HELPFUL', numBuffs)
		buffs.visibleBuffs = visibleBuffs

		local fromRange, toRange
		if buffs.PreSetPosition then
			fromRange, toRange = buffs:PreSetPosition(numBuffs)
		end

		if fromRange or buffs.createdIcons > buffs.anchoredIcons then
			(buffs.SetPosition or SetPosition) (buffs, fromRange or buffs.anchoredIcons + 1, toRange or buffs.createdIcons)
			buffs.anchoredIcons = buffs.createdIcons
		end

		if buffs.PostUpdate then buffs:PostUpdate(unit) end
	end

	local debuffs = self.Debuffs
	if debuffs then
		if debuffs.PreUpdate then debuffs:PreUpdate(unit) end

		local numDebuffs = debuffs.num or 40
		local visibleDebuffs, hiddenDebuffs = filterIcons(debuffs, unit, debuffs.filter or 'HARMFUL', numDebuffs, true)
		debuffs.visibleDebuffs = visibleDebuffs

		local fromRange, toRange
		if debuffs.PreSetPosition then
			fromRange, toRange = debuffs:PreSetPosition(numDebuffs)
		end

		if fromRange or debuffs.createdIcons > debuffs.anchoredIcons then
			(debuffs.SetPosition or SetPosition) (debuffs, fromRange or debuffs.anchoredIcons + 1, toRange or debuffs.createdIcons)
			debuffs.anchoredIcons = debuffs.createdIcons
		end

		if debuffs.PostUpdate then debuffs:PostUpdate(unit) end
	end
end

local function Update(self, event, unit)
	if self.unit ~= unit then return end

	UpdateAuras(self, event, unit)

	-- Assume no event means someone wants to re-anchor things. This is usually
	-- done by UpdateAllElements and :ForceUpdate.
	if event == 'ForceUpdate' or not event then
		local buffs = self.Buffs
		if buffs then
			(buffs.SetPosition or SetPosition) (buffs, 1, buffs.createdIcons)
		end

		local debuffs = self.Debuffs
		if debuffs then
			(debuffs.SetPosition or SetPosition) (debuffs, 1, debuffs.createdIcons)
		end

		local auras = self.Auras
		if auras then
			(auras.SetPosition or SetPosition) (auras, 1, auras.createdIcons)
		end
	end
end

local function ForceUpdate(element)
	return Update(element.__owner, 'ForceUpdate', element.__owner.unit)
end

local function Enable(self)
	if self.Buffs or self.Debuffs or self.Auras then
		self:RegisterEvent('PLAYER_AURAS_CHANGED', UpdateAuras)
		self:RegisterEvent('UNIT_AURA', UpdateAuras)

		local buffs = self.Buffs
		if buffs then
			buffs.__owner = self
			buffs.ForceUpdate = ForceUpdate

			buffs.createdIcons = buffs.createdIcons or 0
			buffs.anchoredIcons = 0

			--buffs:Show()
		end

		local debuffs = self.Debuffs
		if debuffs then
			debuffs.__owner = self
			debuffs.ForceUpdate = ForceUpdate

			debuffs.createdIcons = debuffs.createdIcons or 0
			debuffs.anchoredIcons = 0

			--debuffs:Show()
		end

		local auras = self.Auras
		if auras then
			auras.__owner = self
			auras.ForceUpdate = ForceUpdate

			auras.createdIcons = auras.createdIcons or 0
			auras.anchoredIcons = 0

			--auras:Show()
		end

		return true
	end
end

local function Disable(self)
	if self.Buffs or self.Debuffs or self.Auras then
		self:UnregisterEvent('PLAYER_AURAS_CHANGED', UpdateAuras)
		self:UnregisterEvent('UNIT_AURA', UpdateAuras)

		if self.Buffs then self.Buffs:Hide() end
		if self.Debuffs then self.Debuffs:Hide() end
		if self.Auras then self.Auras:Hide() end
	end
end

oUF:AddElement('Auras', Update, Enable, Disable)
