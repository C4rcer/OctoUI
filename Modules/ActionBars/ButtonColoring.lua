--[[
	tullaRange
		Adds out of range coloring to action buttons
		Derived from RedRange with negligable improvements to CPU usage
--]]

local E, L, V, P, G = unpack(ElvUI)

local _G = _G
local UPDATE_DELAY = 0.1

local ActionHasRange = ActionHasRange
local IsActionInRange = IsActionInRange
local IsUsableAction = IsUsableAction
local HasAction = HasAction

local tullaRange = CreateFrame("Frame", "tullaRange", UIParent)

--[[
	MACRO BUTTONS, whose range this client will not answer for.

	ActionHasRange is false for every macro -- a macro has no inherent range, only whatever
	it happens to cast -- so UpdateButtonStatus never registered one and the icon stayed at
	its normal colour whatever the target was doing. Reported 2026-08-14: three macro
	buttons that never showed out of range while the spell buttons beside them did.

	SuperCleveRoidMacros already solves the hard half. It resolves which spell a macro's
	conditionals actually land on and tracks that spell's range and usability, which is the
	part no vanilla API will give us for a macro. CleveRoids.GetAction(slot) hands it over:

		active.usable   1 usable, 2 out of power, nil unusable
		active.oom      out of power
		active.inRange  0 out of range, 1 in range, -1 not known

	Read through pcall and behind a full set of nil checks, because this is another addon's
	internal state and it is not there at all when that addon is not installed -- in which
	case everything below behaves exactly as it did before.
]]
local function MacroActionState(action)
	if not action then return nil end

	local CleveRoids = _G.CleveRoids
	if not (CleveRoids and CleveRoids.GetAction) then return nil end

	local ok, actions = pcall(CleveRoids.GetAction, action)
	if not ok or type(actions) ~= "table" then return nil end

	local active = actions.active
	--No resolved spell means the macro's conditionals matched nothing this instant, and
	--there is no range to speak of. Left to the normal path rather than guessed at.
	if type(active) ~= "table" or not active.action then return nil end

	return active
end

function tullaRange:Load()
	self:SetScript("OnUpdate", self.OnUpdate)
	self:SetScript("OnHide", self.OnHide)
	self:SetScript("OnEvent", self.OnEvent)
	self.elapsed = 0

	self:RegisterEvent("PLAYER_LOGIN")
end

function tullaRange:OnEvent()
	local action = this[event]
	if action then
		action(this, event)
	end
end

function tullaRange:OnUpdate()
	if this.elapsed < UPDATE_DELAY then
		this.elapsed = this.elapsed + arg1
	else
		this:Update()
	end
end

function tullaRange:OnHide()
	this.elapsed = 0
end

function tullaRange:PLAYER_LOGIN()
	if not TULLARANGE_COLORS then
		self:LoadDefaults()
	end
	self.colors = TULLARANGE_COLORS

	self.buttonsToUpdate = {}

	hooksecurefunc("ActionButton_OnUpdate", self.RegisterButton)
	hooksecurefunc("ActionButton_UpdateUsable", self.OnUpdateButtonUsable)
	hooksecurefunc("ActionButton_Update", self.OnButtonUpdate)
end

function tullaRange:Update()
	self:UpdateButtons(self.elapsed)
	self.elapsed = 0
end

function tullaRange:ForceColorUpdate()
	for button in pairs(self.buttonsToUpdate) do
		tullaRange.OnUpdateButtonUsable(button)
	end
end

function tullaRange:UpdateShown()
	if next(self.buttonsToUpdate) then
		self:Show()
	else
		self:Hide()
	end
end

function tullaRange:UpdateButtons(elapsed)
	if not next(self.buttonsToUpdate) then
		self:Hide()
		return
	end

	for button in pairs(self.buttonsToUpdate) do
		self:UpdateButton(button, elapsed)
	end
end

function tullaRange:UpdateButton(button, elapsed)
	tullaRange:UpdateButtonUsable(button)
end

function tullaRange:UpdateButtonStatus()
	local action = ActionButton_GetPagedID(this)
	--A macro qualifies on the strength of the spell it resolves to, since ActionHasRange
	--will never say yes for one.
	if not(this:IsVisible() and action and HasAction(action)
		and (ActionHasRange(action) or MacroActionState(action))) then
		self.buttonsToUpdate[this] = nil
	else
		self.buttonsToUpdate[this] = true
	end
	self:UpdateShown()
end

function tullaRange.RegisterButton()
	this:SetScript("OnShow", tullaRange.OnButtonShow)
	this:SetScript("OnHide", tullaRange.OnButtonHide)
	this:SetScript("OnUpdate", nil)

	tullaRange:UpdateButtonStatus(this)
end

function tullaRange.OnButtonShow()
	tullaRange:UpdateButtonStatus(this)
end

function tullaRange.OnButtonHide()
	tullaRange:UpdateButtonStatus(this)
end

function tullaRange:OnUpdateButtonUsable()
	this.tullaRangeColor = nil
	tullaRange:UpdateButtonUsable(this)
end

function tullaRange.OnButtonUpdate()
	tullaRange:UpdateButtonStatus(this)
end

function tullaRange:UpdateButtonUsable(button)
	local action = ActionButton_GetPagedID(button)

	--Taken from the macro's resolved spell when there is one. IsUsableAction answers for the
	--macro itself, which is always usable and never in range, so asking it about a macro is
	--how the icon came to sit at its normal colour permanently.
	local macro = MacroActionState(action)
	if macro then
		if macro.usable == 1 and not macro.oom then
			--Only 0 means out of range. -1 is "no target to measure against", which is not
			--the same thing and must not paint the icon red.
			if macro.inRange == 0 then
				tullaRange.SetButtonColor(button, "OOR")
			else
				tullaRange.SetButtonColor(button, "NORMAL")
			end
		elseif macro.oom or macro.usable == 2 then
			tullaRange.SetButtonColor(button, "OOM")
		else
			tullaRange.SetButtonColor(button, "UNUSABLE")
		end
		return
	end

	local isUsable, notEnoughMana = IsUsableAction(action)

	if isUsable then
		if IsActionInRange(action) == 0 then
			tullaRange.SetButtonColor(button, "OOR")
		else
			tullaRange.SetButtonColor(button, "NORMAL")
		end
	elseif notEnoughMana then
		tullaRange.SetButtonColor(button, "OOM")
	else
		tullaRange.SetButtonColor(button, "UNUSABLE")
	end
end

function tullaRange.SetButtonColor(button, colorType)
	if button.tullaRangeColor ~= colorType then
		button.tullaRangeColor = colorType

		local r, g, b = tullaRange:GetColor(colorType)

		local icon = _G[button:GetName() .. "Icon"]
		icon:SetVertexColor(r, g, b)
	end
end

function tullaRange:LoadDefaults()
	TULLARANGE_COLORS = {
		["OOR"] = E:GetColorTable(E.db.actionbar.noRangeColor),
		["OOM"] = E:GetColorTable(E.db.actionbar.noPowerColor),
		["NORMAL"] = E:GetColorTable(E.db.actionbar.usableColor),
		["UNUSABLE"] = E:GetColorTable(E.db.actionbar.notUsableColor)
	};
end

function tullaRange:Reset()
	self:LoadDefaults()
	self.colors = TULLARANGE_COLORS

	self:ForceColorUpdate()
end

function tullaRange:SetColor(index, r, g, b)
	local color = self.colors[index]
	color[1] = r
	color[2] = g
	color[3] = b

	self:ForceColorUpdate()
end

function tullaRange:GetColor(index)
	local color = self.colors[index]
	return color[1], color[2], color[3]
end

tullaRange:Load()