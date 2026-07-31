local ns = oUF
local oUF = ns.oUF

local pairs, type, next = pairs, type, next
local format = string.format
local floor, mod = math.floor, math.mod

local GetTime = GetTime
local UnitAura = UnitAura
local GetPlayerBuff = GetPlayerBuff
local GetPlayerBuffTexture = GetPlayerBuffTexture
local GetPlayerBuffApplications = GetPlayerBuffApplications
local GetPlayerBuffDispelType = GetPlayerBuffDispelType
local GetPlayerBuffTimeLeft = GetPlayerBuffTimeLeft

local addon = {}
ns.oUF_RaidDebuffs = addon
oUF_RaidDebuffs = ns.oUF_RaidDebuffs
if(not _G.oUF_RaidDebuffs) then
	_G.oUF_RaidDebuffs = addon
end

local debuff_data = {}
addon.DebuffData = debuff_data

addon.ShowDispellableDebuff = true
addon.FilterDispellableDebuff = true

addon.priority = 10

local function add(spell, priority, stackThreshold)
	if(spell) then
		debuff_data[spell] = {
			priority = (addon.priority + priority),
			stackThreshold = (stackThreshold or 0)
		}
	end
end

--Nothing calls this today. UF:UpdateAllHeaders has the call commented out because it
--reads E.global.unitframe.aurafilters.RaidDebuffs, and Settings/Filters/UnitFrame.lua is
--empty -- so there is no filter list on this fork and debuff_data stays empty. Until one
--exists, only the dispel-type path in Update can select anything, and Update skips the
--tooltip name scan entirely on the strength of that. Registering a list turns both back
--on with no further change.
function addon:RegisterDebuffs(t)
	if not t then return end

	for spell, value in pairs(t) do
		if(type(t[spell]) == 'boolean') then
			local oldValue = t[spell]
			t[spell] = {
				['enable'] = oldValue,
				['priority'] = 0,
				['stackThreshold'] = 0
			}
		else
			if(t[spell].enable) then
				add(spell, t[spell].priority, t[spell].stackThreshold)
			end
		end
	end
end

function addon:ResetDebuffData()
	wipe(debuff_data)
end

local DispellColor = {
	['Magic'] = {.2, .6, 1},
	['Curse'] = {.6, 0, 1},
	['Disease'] = {.6, .4, 0},
	['Poison'] = {0, .6, 0}
}

local DispellPriority = {
	['Magic'] = 4,
	['Curse'] = 3,
	['Disease'] = 2,
	['Poison'] = 1
}

local DispellFilter
do
	local dispellClasses = {
		['PRIEST'] = {
			['Magic'] = true,
			['Disease'] = true
		},
		['SHAMAN'] = {
			['Poison'] = true,
			['Disease'] = true
		},
		['PALADIN'] = {
			['Poison'] = true,
			['Magic'] = true,
			['Disease'] = true
		},
		['MAGE'] = {
			['Curse'] = true
		},
		['DRUID'] = {
			['Curse'] = true,
			['Poison'] = true
		}
	}

	DispellFilter = dispellClasses[select(2, UnitClass('player'))] or {}
end

--1.12 has no real UnitAura. The polyfill in Compatibility/api/wowAPI.lua hands back
--texture, count and dispel type and nothing else, but upstream read seven values back
--out of it -- so `name` received the *texture*, `icon` received the *dispel type*, and
--every field after that was nil. `if not (name and icon) then break end` then abandoned
--the scan on the first debuff that is not dispellable, which is most of them, so this
--element has never shown anything in normal play.
--
--LibDebuff carries the same signature as the modern UnitAura and reconstructs both the
--name (tooltip scan) and the duration (combat log plus the bundled duration tables) for
--debuffs the player applied. It is the same source the nameplate DoT timers and the
--unit frame aura timers already run on. Resolved on demand rather than cached: this
--file loads long before the NamePlates module exists.
local function GetLibDebuff()
	local engine = _G.ElvUI and _G.ElvUI[1]
	local module = engine and engine.GetModule and engine:GetModule("NamePlates", true)
	local lib = module and module.LibDebuff
	if lib and lib.UnitDebuff then return lib end
end

--Returns texture, count, dispelType -- the three fields this client will part with
--cheaply. The player is the one unit with a real timer behind it, and it reads through
--a different set of functions entirely; the unit frame auras element takes the same two
--branches for the same reason.
local function ScanDebuff(unit, index)
	if unit == 'player' then
		local idx = GetPlayerBuff(index - 1, 'HARMFUL')
		local texture = GetPlayerBuffTexture(idx)
		if not texture then return end

		return texture, GetPlayerBuffApplications(idx), GetPlayerBuffDispelType(idx), idx
	end

	return UnitAura(unit, index, 'HARMFUL')
end

--Only ever called for the one debuff that won the priority contest, not for all forty:
--the name comes out of a tooltip scan, which Modules/NamePlates/Elements/Auras.lua
--caches precisely because it is expensive. Returns duration, expiration.
--
--For the player this is the client's own remaining time, which is real. For anybody
--else it is LibDebuff, which reconstructs durations from the combat log -- and only for
--debuffs *the player applied*. A debuff a mob put on a party member is therefore
--untimed, and correctly shows no countdown rather than an invented one.
local function DebuffTime(unit, index, playerBuffIndex)
	if unit == 'player' then
		local timeleft = playerBuffIndex and GetPlayerBuffTimeLeft(playerBuffIndex)
		if timeleft and timeleft > 0 then
			return timeleft, GetTime() + timeleft
		end

		return
	end

	local lib = GetLibDebuff()
	if not lib then return end

	local _, _, _, _, _, duration, timeleft = lib:UnitDebuff(unit, index)
	if duration and timeleft and timeleft > 0 then
		return duration, GetTime() + timeleft
	end
end

--The name is only needed to look a debuff up in a registered filter list, and resolving
--one costs a tooltip scan per debuff per UNIT_AURA per frame. With no list registered
--there is nothing to look up, so the whole cost is skipped -- see RegisterDebuffs.
local function DebuffName(unit, index)
	local lib = GetLibDebuff()
	if not lib then return end

	return (lib:UnitDebuff(unit, index))
end

local function formatTime(s)
	if(s > 60) then
		--was string.mod, which does not exist in any Lua version and raised the moment a
		--debuff had more than a minute left. math.mod is safe here: s is always positive,
		--so the sign-of-the-dividend trap that broke the bank sort cannot apply.
		return format('%dm', s/60), mod(s, 60)
	elseif(s < 1) then
		return format('%.1f', s), s - floor(s)
	else
		return format('%d', s), s - floor(s)
	end
end

--Counts down against the expiration stashed when the debuff was picked, rather than
--re-reading it every frame: UnitAura has no time left to give on this client, so the
--original re-query returned nil and hid the timer on its first tick.
local function UpdateDebuffTimer(element, elapsed)
	element.elapsed = (element.elapsed or 0) + elapsed
	if element.elapsed < 0.1 then return end
	element.elapsed = 0

	local timeLeft = element.expiration and (element.expiration - GetTime())
	if timeLeft and timeLeft > 0 then
		--first return only: SetText takes one string and silently drops the rest
		local text = formatTime(timeLeft)
		element.time:SetText(text)
	else
		element:SetScript('OnUpdate', nil)
		element.time:Hide()
	end
end

--Wrapped, not passed raw: a 1.12 script handler receives no self and no elapsed, only
--the globals `this` and `arg1`. Same shape as the unit frame aura timers.
local function onUpdate()
	UpdateDebuffTimer(this, arg1 or 0)
end

--Gated on the icon rather than the name: the name is only knowable through LibDebuff,
--and a debuff still has to draw without one. `count` arrives normalised to a number for
--the same reason -- the client reports no stack count at all for a single application,
--and comparing nil against a number raised here.
local function UpdateDebuff(self, name, icon, count, debuffType, duration, expiration, stackThreshold)
	local element = self.RaidDebuffs

	if(icon and (count >= stackThreshold)) then
		element.icon:SetTexture(icon)
		element.icon:Show()
		element.duration = duration
		element.expiration = expiration

		if(element.count) then
			if(count and count > 1) then
				element.count:SetText(count)
				element.count:Show()
			else
				element.count:SetText('')
				element.count:Hide()
			end
		end

		if(element.time) then
			if(duration and duration > 0 and expiration) then
				element.elapsed = 0
				element:SetScript('OnUpdate', onUpdate)
				element.time:Show()
				--drawn once now; otherwise the field sits blank until the first tick
				UpdateDebuffTimer(element, 1)
			else
				element:SetScript('OnUpdate', nil)
				element.time:SetText('')
				element.time:Hide()
			end
		end

		if(element.cd) then
			if(duration and duration > 0 and expiration) then
				--expiration is a timestamp, so the cooldown starts at expiration - duration.
				--Upstream's GetTime() - (endTime - duration) subtracted a timestamp from a
				--timestamp and fed the result in as one.
				element.cd:SetCooldown(expiration - duration, duration)
				element.cd:Show()
			else
				element.cd:Hide()
			end
		end

		local c = DispellColor[debuffType] or ElvUI[1].media.bordercolor
		element:SetBackdropBorderColor(c[1], c[2], c[3])

		element:Show()
	else
		element:SetScript('OnUpdate', nil)
		element:Hide()
		element.index = nil
		element.expiration = nil
	end
end

local function Update(self, event, unit)
	if(not unit or self.unit ~= unit) then return end

	local element = self.RaidDebuffs

	local name, icon, count, debuffType, playerBuffIndex
	local _name, _icon, _count, _dtype, _duration, _expiration, _playerBuffIndex
	local _priority, priority = 0, 0
	local _stackThreshold = 0

	--a filter list is what makes names worth their tooltip scan; with none registered
	--the dispel-type path is the only one that can select anything
	local needNames = next(debuff_data) ~= nil

	element.index = nil

	for i = 1, 40 do
		icon, count, debuffType, playerBuffIndex = ScanDebuff(unit, i)
		--the icon is the only field guaranteed to be there; a nil one is the end of the list
		if not icon then break end

		count = count or 0
		name = needNames and DebuffName(unit, i) or nil

		if(addon.ShowDispellableDebuff and (element.showDispellableDebuff ~= false) and debuffType) then
			if(addon.FilterDispellableDebuff) then
				DispellPriority[debuffType] = (DispellPriority[debuffType] or 0) + addon.priority
				priority = DispellFilter[debuffType] and DispellPriority[debuffType] or 0
				if(priority == 0) then
					debuffType = nil
				end
			else
				priority = DispellPriority[debuffType] or 0
			end

			if(priority > _priority) then
				_priority, _name, _icon, _count, _dtype, _playerBuffIndex = priority, name, icon, count, debuffType, playerBuffIndex
				element.index = i
			end
		end

		--only reachable once a filter list is registered; see the note on RegisterDebuffs
		priority = name and debuff_data[name] and debuff_data[name].priority
		if(priority and (priority > _priority)) then
			_priority, _name, _icon, _count, _dtype, _playerBuffIndex = priority, name, icon, count, debuffType, playerBuffIndex
			element.index = i
		end
	end

	--after the contest, not during it: one lookup for the debuff that is actually going
	--to be drawn instead of forty for debuffs that are not
	if(element.index) then
		_duration, _expiration = DebuffTime(unit, element.index, _playerBuffIndex)
	end

	if(element.forceShow) then
		--GetSpellInfo does not exist on this client, so the config preview raised here on
		--every party and raid frame the moment Display Auras was switched on. The auras
		--element solves the same problem with a literal texture path; match it.
		_name, _icon = nil, 'Interface\\Icons\\Spell_Holy_DivineSpirit'
		_count, _dtype, _duration, _expiration, _stackThreshold = 5, 'Magic', 0, nil, 0
	end

	if(_name) then
		_stackThreshold = debuff_data[_name] and debuff_data[_name].stackThreshold or _stackThreshold
	end

	UpdateDebuff(self, _name, _icon, _count or 0, _dtype, _duration, _expiration, _stackThreshold)

	--Reset the DispellPriority
	DispellPriority = {
		['Magic'] = 4,
		['Curse'] = 3,
		['Disease'] = 2,
		['Poison'] = 1
	}
end

local function Path(self, ...)
	--[[ Override: RaidDebuffs.Override(self, event, ...)
	Used to completely override the element's update process.

	* self  - the parent object
	* event - the event triggering the update (string)
	* ...   - the arguments accompanying the event (string)
	--]]
    return (self.RaidDebuffs.Override or Update) (self, unpack(arg))
end

local function ForceUpdate(element)
    return Path(element.__owner, 'ForceUpdate', element.__owner.unit)
end

local function Enable(self)
	local element = self.RaidDebuffs
	if(element) then
		element.__owner = self
		element.ForceUpdate = ForceUpdate

		self:RegisterEvent('UNIT_AURA', Update)
		return true
	end
end

local function Disable(self)
	local element = self.RaidDebuffs
	if(element) then
		element:Hide()

		self:UnregisterEvent('UNIT_AURA', Update)
	end
end

oUF:AddElement('RaidDebuffs', Update, Enable, Disable)