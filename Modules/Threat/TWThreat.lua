local _G, _ = _G or getfenv()

--[[
	Ported from TWThreat v1.2.3 by Xerron/Er (CosminPOP), the Turtle WoW threat
	meter. The server-side threat API (TWTv4=/TMTv1=/TWT_UDTSv4 addon messages)
	is spoken by the OctoWoW server too, so the protocol strings must never
	change. Adopted into OctoUI: media paths moved under the ElvUI addon,
	initialization runs through E:RegisterModule instead of ADDON_LOADED, and
	the pfUI target-frame integration was repointed at ElvUI's target unitframe
	(the config keys and frame names use "UF" where upstream said "PFUI").
]]

local E = unpack(ElvUI)

-- todo tankmode messages to send if guid is target, for tankmode highlight
-- todo save OctoTWT_SPEC per sender so it caches from other people's inspects

local __lower = string.lower
local __repeat = string.rep
local __strlen = string.len
local __find = string.find
local __substr = string.sub
local __parseint = tonumber
local __parsestring = tostring
local __getn = table.getn
local __tinsert = table.insert
local __tsort = table.sort
local __pairs = pairs
local __floor = math.floor
local __abs = abs

local TWT = CreateFrame("Frame")

TWT.addonVer = '1.2.3'

TWT.threatApi = 'TWTv4=';
TWT.tankModeApi = 'TMTv1=';
TWT.UDTS = 'TWT_UDTSv4';

TWT.showedUpdateNotification = false
TWT.addonName = '|cffabd473Octo|cffcdfe00UI Threatmeter'

TWT.prefix = 'TWT'
TWT.channel = 'RAID'

TWT.name = UnitName('player')
local _, cl = UnitClass('player')
TWT.class = __lower(cl)

TWT.lastAggroWarningSoundTime = 0
TWT.lastAggroWarningGlowTime = 0

TWT.AGRO = '-Pull Aggro at-'
TWT.threatsFrames = {}

TWT.threats = {}

TWT.targetName = ''
TWT.relayTo = {}
TWT.shouldRelay = false
TWT.healerMasterTarget = ''

TWT.updateSpeed = 1

TWT.targetFrameVisible = false
TWT.UFtargetFrameVisible = false

TWT.nameLimit = 30
TWT.windowStartWidth = 300
TWT.windowWidth = 300
TWT.minBars = 5
TWT.maxBars = 11

--Mirrors minValue/maxValue on OctoTWTMainSettingsFrameHeightSlider in the XML. Named
--here so the clamp in TWT.init and the one in the slider handler cannot drift apart from
--each other or from the widget they are protecting.
TWT.minBarHeight = 20
TWT.maxBarHeight = 30

TWT.roles = {}
TWT.spec = {}

TWT.tankModeThreats = {}

TWT.custom = {
    ['The Prophet Skeram'] = 0
}

TWT.withAddon = 0
TWT.addonStatus = {}

TWT.classColors = {
    ["warrior"] = { r = 0.78, g = 0.61, b = 0.43, c = "|cffc79c6e" },
    ["mage"] = { r = 0.41, g = 0.8, b = 0.94, c = "|cff69ccf0" },
    ["rogue"] = { r = 1, g = 0.96, b = 0.41, c = "|cfffff569" },
    ["druid"] = { r = 1, g = 0.49, b = 0.04, c = "|cffff7d0a" },
    ["hunter"] = { r = 0.67, g = 0.83, b = 0.45, c = "|cffabd473" },
    ["shaman"] = { r = 0.14, g = 0.35, b = 1.0, c = "|cff0070de" },
    ["priest"] = { r = 1, g = 1, b = 1, c = "|cffffffff" },
    ["warlock"] = { r = 0.58, g = 0.51, b = 0.79, c = "|cff9482c9" },
    ["paladin"] = { r = 0.96, g = 0.55, b = 0.73, c = "|cfff58cba" },
    ["agro"] = { r = 0.96, g = 0.1, b = 0.1, c = "|cffff1111" }
}

TWT.classCoords = {
    ["priest"] = { 0.52, 0.73, 0.27, 0.48 },
    ["mage"] = { 0.23, 0.48, 0.02, 0.23 },
    ["warlock"] = { 0.77, 0.98, 0.27, 0.48 },
    ["rogue"] = { 0.48, 0.73, 0.02, 0.23 },
    ["druid"] = { 0.77, 0.98, 0.02, 0.23 },
    ["hunter"] = { 0.02, 0.23, 0.27, 0.48 },
    ["shaman"] = { 0.27, 0.48, 0.27, 0.48 },
    ["warrior"] = { 0.02, 0.23, 0.02, 0.23 },
    ["paladin"] = { 0.02, 0.23, 0.52, 0.73 },
}

TWT.fonts = {
    'BalooBhaina', 'BigNoodleTitling',
    'Expressway', 'Homespun', 'Hooge', 'LondrinaSolid',
    'Myriad-Pro', 'PT-Sans-Narrow-Bold', 'PT-Sans-Narrow-Regular',
    'Roboto', 'Share', 'ShareBold',
    'Sniglet', 'SquadaOne',
}

TWT.updateSpeeds = {
    ['warrior'] = { 0.7, 0.5, 0.5 },
    ['paladin'] = { 1, 0.5, 0.7 },
    ['hunter'] = { 0.7, 0.7, 0.7 },
    ['rogue'] = { 0.5, 0.5, 0.5 },
    ['priest'] = { 1, 1, 0.6 },
    ['shaman'] = { 0.7, 0.5, 1 },
    ['mage'] = { 1, 0.5, 0.7 },
    ['warlock'] = { 0.8, 1, 0.6 },
    ['druid'] = { 0.8, 0.5, 1 },
}

function OctoTWTPrint(a)
    if a == nil then
        DEFAULT_CHAT_FRAME:AddMessage('[TWT]|cff0070de:' .. GetTime() .. '|cffffffff attempt to print a nil value.')
        return false
    end
    DEFAULT_CHAT_FRAME:AddMessage(TWT.classColors[TWT.class].c .. "[TWT] |cffffffff" .. a)
end

function OctoTWTDebug(a)
    local time = GetTime() + 0.0001
    if not OctoTWT_CONFIG.debug then
        return false
    end
    if a == nil then
        OctoTWTPrint('|cff0070de[OctoTWTDEBUG:' .. time .. ']|cffffffff attempt to print a nil value.')
        return
    end
    if type(a) == 'boolean' then
        if a then
            OctoTWTPrint('|cff0070de[OctoTWTDEBUG:' .. time .. ']|cffffffff[true]')
        else
            OctoTWTPrint('|cff0070de[OctoTWTDEBUG:' .. time .. ']|cffffffff[false]')
        end
        return true
    end
    OctoTWTPrint('|cff0070de[D:' .. time .. ']|cffffffff[' .. a .. ']')
end

--The SLASH_ and SlashCmdList keys carry the Octo prefix like every other global this
--module owns, but the commands people actually type stay as they were: /twt is what the
--upstream addon's own documentation says and what anyone coming from it will reach for.
--A second spelling is registered alongside for when both addons are installed and the
--standalone wins the /twt registration -- it loads second, so it does.
SLASH_OCTOTWT1 = "/twt"
SLASH_OCTOTWT2 = "/octotwt"
SlashCmdList["OCTOTWT"] = function(cmd)
    if not TWT.enabled then
        OctoTWTPrint('Threat meter is disabled. Enable it under /oc -> General.')
        return false
    end
    if cmd then
        if __substr(cmd, 1, 4) == 'show' then
            _G['OctoTWTMain']:Show()
            OctoTWT_CONFIG.visible = true
            return true
        end
        if __substr(cmd, 1, 8) == 'tankmode' then
            if OctoTWT_CONFIG.tankMode then
                OctoTWTPrint('Tank Mode is already enabled.')
                return false
            else
                OctoTWT_CONFIG.tankMode = true
                OctoTWTPrint('Tank Mode enabled.')
            end
            return true
        end
        if __substr(cmd, 1, 6) == 'skeram' then
            if OctoTWT_CONFIG.skeram then
                OctoTWT_CONFIG.skeram = false
                OctoTWTPrint('Skeram module disabled.')
                return true
            end
            OctoTWT_CONFIG.skeram = true
            OctoTWTPrint('Skeram module enabled.')
            return true
        end
        if __substr(cmd, 1, 5) == 'debug' then
            if OctoTWT_CONFIG.debug then
                OctoTWT_CONFIG.debug = false
                _G['OctoTWTpps']:Hide()
                OctoTWTPrint('Debugging disabled')
                return true
            end
            OctoTWT_CONFIG.debug = true
            _G['OctoTWTpps']:Show()
            OctoTWTDebug('Debugging enabled')
            return true
        end

        if __substr(cmd, 1, 3) == 'who' then
            TWT.queryWho()
            return true
        end

        OctoTWTPrint(TWT.addonName .. ' |cffabd473v' .. TWT.addonVer .. '|cffffffff available commands:')
        OctoTWTPrint('/twt show - shows the main window (also /twtshow)')
    end
end

SLASH_OCTOTWTSHOW1 = "/twtshow"
SLASH_OCTOTWTSHOW2 = "/octotwtshow"
SlashCmdList["OCTOTWTSHOW"] = function(cmd)
    if not TWT.enabled then
        OctoTWTPrint('Threat meter is disabled. Enable it under /oc -> General.')
        return false
    end
    if cmd then
        _G['OctoTWTMain']:Show()
        OctoTWT_CONFIG.visible = true
    end
end

SLASH_OCTOTWTDEBUG1 = "/twtdebug"
SLASH_OCTOTWTDEBUG2 = "/octotwtdebug"
SlashCmdList["OCTOTWTDEBUG"] = function(cmd)
    if not TWT.enabled then
        return false
    end
    if cmd then
        if OctoTWT_CONFIG.debug then
            OctoTWT_CONFIG.debug = false
            OctoTWTPrint('Debugging disabled')
            return true
        end
        OctoTWT_CONFIG.debug = true
        OctoTWTDebug('Debugging enabled')
        return true
    end
end

TWT:RegisterEvent("CHAT_MSG_ADDON")
TWT:RegisterEvent("PLAYER_REGEN_DISABLED")
TWT:RegisterEvent("PLAYER_REGEN_ENABLED")
TWT:RegisterEvent("PLAYER_TARGET_CHANGED")
TWT:RegisterEvent("PLAYER_ENTERING_WORLD")
TWT:RegisterEvent("PARTY_MEMBERS_CHANGED")

TWT.threatQuery = CreateFrame("Frame")
TWT.threatQuery:Hide()

local timeStart = GetTime()
local totalPackets = 0
local totalData = 0
local uiUpdates = 0

TWT:SetScript("OnEvent", function()
    --Nothing may run before TM:Initialize has set up OctoTWT_CONFIG
    if not TWT.enabled then
        return
    end
    if event then
        if event == "PARTY_MEMBERS_CHANGED" then
            return TWT.getClasses()
        end
        if event == "PLAYER_ENTERING_WORLD" then
            TWT.sendMyVersion()
            TWT.combatEnd()
            if UnitAffectingCombat('player') then
                TWT.combatStart()
            end
            return true
        end
        if event == 'CHAT_MSG_ADDON' and __find(arg2, TWT.threatApi, 1, true) then

            totalPackets = totalPackets + 1
            totalData = totalData + __strlen(arg2)

            --counted separately from totalPackets, which resets every fight; these two
            --are what /octoui-threat needs to tell an unanswered request from an
            --unasked one
            TWT.repliesSeen = (TWT.repliesSeen or 0) + 1
            TWT.lastReply = GetTime()

            local threatData = arg2
            if __find(threatData, '#') and __find(threatData, TWT.tankModeApi) then
                local packetEx = OctoTWTExplode(threatData, '#')
                if packetEx[1] and packetEx[2] then
                    threatData = packetEx[1]
                    TWT.handleTankModePacket(packetEx[2])
                end
            end

            return TWT.handleThreatPacket(threatData)
        end
        if event == 'CHAT_MSG_ADDON' and arg1 == TWT.prefix then

            if __substr(arg2, 1, 11) == 'TWTVersion:' and arg4 ~= TWT.name then
                --Upstream nagged about newer TWThreat versions here. This fork
                --tracks OctoUI, not CosminPOP's Turtle releases, so version
                --broadcasts from standalone users are consumed silently. We
                --still answer with our own version for their roster display.
                return true
            end

            if __substr(arg2, 1, 7) == 'TWT_WHO' then
                TWT.send('TWT_ME:' .. TWT.addonVer)
                return true
            end

            if __substr(arg2, 1, 15) == 'TWTRoleTexture:' then
                local tex = OctoTWTExplode(arg2, ':')[2] or ''
                TWT.roles[arg4] = tex
                return true
            end

            if __substr(arg2, 1, 7) == 'TWT_ME:' then

                if TWT.addonStatus[arg4] then

                    local msg = OctoTWTExplode(arg2, ':')[2]
                    local verColor = ""
                    if TWT.version(msg) == TWT.version(TWT.addonVer) then
                        verColor = TWT.classColors['hunter'].c
                    end
                    if TWT.version(msg) < TWT.version(TWT.addonVer) then
                        verColor = '|cffff1111'
                    end
                    if TWT.version(msg) + 1 == TWT.version(TWT.addonVer) then
                        verColor = '|cffff8810'
                    end

                    TWT.addonStatus[arg4]['v'] = '    ' .. verColor .. msg
                    TWT.withAddon = TWT.withAddon + 1

                    TWT.updateWithAddon()

                    return true
                end

                return false
            end

            return false

        end
        if event == "PLAYER_REGEN_DISABLED" then
            return TWT.combatStart()
        end
        if event == "PLAYER_REGEN_ENABLED" then
            return TWT.combatEnd()
        end
        if event == "PLAYER_TARGET_CHANGED" then

            if not TWT.targetChanged() then
                TWT.hideThreatFrames(true)
            end

            return true

        end
    end
end)

function OctoTWTQueryWho_OnClick()
    TWT.queryWho()
end

function TWT.queryWho()
    TWT.withAddon = 0
    TWT.addonStatus = {}
    for i = 0, GetNumRaidMembers() do
        if GetRaidRosterInfo(i) then
            local n, _, _, _, _, _, z = GetRaidRosterInfo(i);
            local _, class = UnitClass('raid' .. i)

            TWT.addonStatus[n] = {
                ['class'] = __lower(class),
                ['v'] = '|cff888888   -   '
            }
            if z == 'Offline' then
                TWT.addonStatus[n]['v'] = '|cffff0000offline'
            end
        end
    end
    OctoTWTPrint('Sending who query...')
    _G['OctoTWTWithAddonList']:Show()
    TWT.send('TWT_WHO')
end

function TWT.updateWithAddon()

    local rosterList = ''
    local i = 0
    for n, data in next, TWT.addonStatus do
        i = i + 1
        rosterList = rosterList .. TWT.classColors[data['class']].c .. n .. __repeat(' ', 12 - __strlen(n)) .. ' ' .. data['v'] .. ' |cff888888'
        if i < 4 then
            rosterList = rosterList .. '| '
        end
        if i == 4 then
            rosterList = rosterList .. '\n'
            i = 0
        end
    end
    _G['OctoTWTWithAddonListText']:SetText(rosterList)
    _G['OctoTWTWithAddonListTitle']:SetText('Addon Raid Status ' .. TWT.withAddon .. '/' .. GetNumRaidMembers())
end

TWT.glowFader = CreateFrame('Frame')
TWT.glowFader:Hide()

TWT.glowFader:SetScript("OnShow", function()
    this.startTime = GetTime() - 1
    this.dir = 10
    _G['OctoTWTFullScreenGlow']:SetAlpha(0.01)
    _G['OctoTWTFullScreenGlow']:Show()
end)
TWT.glowFader:SetScript("OnHide", function()
    this.startTime = GetTime()
end)
TWT.glowFader:SetScript("OnUpdate", function()
    local plus = 0.04
    local gt = GetTime() * 1000
    local st = (this.startTime + plus) * 1000
    if gt >= st then
        this.startTime = GetTime()

        if _G['OctoTWTFullScreenGlow']:GetAlpha() >= 0.6 then
            this.dir = -1
        end

        _G['OctoTWTFullScreenGlow']:SetAlpha(_G['OctoTWTFullScreenGlow']:GetAlpha() + 0.03 * this.dir)

        if _G['OctoTWTFullScreenGlow']:GetAlpha() <= 0 then
            TWT.glowFader:Hide()
        end


    end
end)

function TWT.init()

    --This saved variable used to be called TWT_CONFIG, which is also the name the
    --standalone TWThreat addon uses -- the reason for the rename. Anyone upgrading has
    --their settings under the old name, so the old one is still declared in the toc
    --purely to be read here and copied across once. The copy is one-way and only
    --happens when there is nothing under the new name, so it cannot undo a later
    --change; TWT_CONFIG can come out of the toc entirely a version or two from now.
    if not OctoTWT_CONFIG and type(TWT_CONFIG) == "table" then
        OctoTWT_CONFIG = TWT_CONFIG
    end

    if not OctoTWT_CONFIG then
        OctoTWT_CONFIG = {
            visible = true,
            colTPS = true,
            colThreat = true,
            colPerc = true,
            labelRow = true,
        }
    end

    OctoTWT_CONFIG.windowScale = OctoTWT_CONFIG.windowScale or 1
    OctoTWT_CONFIG.glow = OctoTWT_CONFIG.glow or false
    OctoTWT_CONFIG.perc = OctoTWT_CONFIG.perc or false
    OctoTWT_CONFIG.glowUF = OctoTWT_CONFIG.glowUF or false
    OctoTWT_CONFIG.percUF = OctoTWT_CONFIG.percUF or false
    OctoTWT_CONFIG.percUFtop = OctoTWT_CONFIG.percUFtop or false
    OctoTWT_CONFIG.percUFbottom = OctoTWT_CONFIG.percUFbottom or false
    OctoTWT_CONFIG.showInCombat = OctoTWT_CONFIG.showInCombat or false
    OctoTWT_CONFIG.hideOOC = OctoTWT_CONFIG.hideOOC or false
    OctoTWT_CONFIG.font = OctoTWT_CONFIG.font or 'Roboto'
    --Clamped rather than merely defaulted. The slider that owns this is minValue 20,
    --maxValue 30, valueStep 2, so anything outside that range did not come from the
    --slider -- and a live character was found carrying barHeight 2, which is exactly the
    --valueStep. At two pixels a row every bar is invisible whether or not threat data
    --ever arrives, which reads as "the meter does not work" rather than as a bad number.
    --`or 20` alone could never catch it, because 2 is not nil.
    OctoTWT_CONFIG.barHeight = tonumber(OctoTWT_CONFIG.barHeight) or 20
    if OctoTWT_CONFIG.barHeight < TWT.minBarHeight or OctoTWT_CONFIG.barHeight > TWT.maxBarHeight then
        OctoTWT_CONFIG.barHeight = 20
    end
    OctoTWT_CONFIG.visibleBars = OctoTWT_CONFIG.visibleBars or TWT.minBars

    --Ask the server for threat while solo too. Defaults on: it is the case a pet class
    --most wants an answer for, and it costs one request per update tick from one client.
    --Set false to restore upstream's grouped-only behaviour. See TWT.ThreatWanted.
    if OctoTWT_CONFIG.soloThreat == nil then
        OctoTWT_CONFIG.soloThreat = true
    end
    OctoTWT_CONFIG.fullScreenGlow = OctoTWT_CONFIG.fullScreenGlow or false
    OctoTWT_CONFIG.aggroSound = OctoTWT_CONFIG.aggroSound or false
    OctoTWT_CONFIG.aggroThreshold = OctoTWT_CONFIG.aggroThreshold or 85
    OctoTWT_CONFIG.tankMode = OctoTWT_CONFIG.tankMode or false
    OctoTWT_CONFIG.tankModeStick = OctoTWT_CONFIG.tankModeStick or 'Free' -- Top, Right, Left, Right, Free
    OctoTWT_CONFIG.lock = OctoTWT_CONFIG.lock or false
    OctoTWT_CONFIG.visible = OctoTWT_CONFIG.visible or false
    OctoTWT_CONFIG.colTPS = OctoTWT_CONFIG.colTPS or false
    OctoTWT_CONFIG.colThreat = OctoTWT_CONFIG.colThreat or false
    OctoTWT_CONFIG.colPerc = OctoTWT_CONFIG.colPerc or false
    OctoTWT_CONFIG.labelRow = OctoTWT_CONFIG.labelRow or false
    OctoTWT_CONFIG.skeram = OctoTWT_CONFIG.skeram or false

    OctoTWT_CONFIG.combatAlpha = OctoTWT_CONFIG.combatAlpha or 1
    OctoTWT_CONFIG.oocAlpha = OctoTWT_CONFIG.oocAlpha or 1

    if TWT.class ~= 'paladin' and TWT.class ~= 'warrior' and TWT.class ~= 'druid' then
        _G['OctoTWTMainSettingsTankMode']:Disable()
        OctoTWT_CONFIG.tankMode = false
    end

    OctoTWT_CONFIG.debug = OctoTWT_CONFIG.debug or false

    if OctoTWT_CONFIG.visible then
        _G['OctoTWTMain']:Show()
    else
        _G['OctoTWTMain']:Hide()
    end

    if OctoTWT_CONFIG.tankMode then
        _G['OctoTWTMainSettingsFullScreenGlow']:SetChecked(OctoTWT_CONFIG.fullScreenGlow)
        _G['OctoTWTMainSettingsFullScreenGlow']:Disable()
        _G['OctoTWTMainSettingsAggroSound']:SetChecked(OctoTWT_CONFIG.fullScreenGlow)
        _G['OctoTWTMainSettingsAggroSound']:Disable()
    end

    if OctoTWT_CONFIG.lock then
        _G['OctoTWTMainLockButton']:SetNormalTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\icon_locked')
    else
        _G['OctoTWTMainLockButton']:SetNormalTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\icon_unlocked')
    end

    _G['OctoTWTFullScreenGlowTexture']:SetWidth(GetScreenWidth())
    _G['OctoTWTFullScreenGlowTexture']:SetHeight(GetScreenHeight())

    _G['OctoTWTMain']:SetHeight(OctoTWT_CONFIG.barHeight * OctoTWT_CONFIG.visibleBars + (OctoTWT_CONFIG.labelRow and 40 or 20))

    _G['OctoTWTMainSettingsFrameHeightSlider']:SetValue(OctoTWT_CONFIG.barHeight) -- calls OctoTWTFrameHeightSlider_OnValueChanged()
    _G['OctoTWTMainSettingsWindowScaleSlider']:SetValue(OctoTWT_CONFIG.windowScale) -- calls OctoTWTFrameHeightSlider_OnValueChanged()

    _G['OctoTWTMainSettingsCombatAlphaSlider']:SetValue(OctoTWT_CONFIG.combatAlpha) -- calls OctoTWTCombatOpacitySlider_OnValueChanged()
    _G['OctoTWTMainSettingsOOCAlphaSlider']:SetValue(OctoTWT_CONFIG.oocAlpha) -- calls OctoTWTOOCombatSlider_OnValueChanged()

    _G['OctoTWTMainSettingsAggroThresholdSlider']:SetValue(OctoTWT_CONFIG.aggroThreshold) -- calls OctoTWTAggroThresholdSlider_OnValueChanged()

    _G['OctoTWTMainSettingsFontButton']:SetText(OctoTWT_CONFIG.font)

    _G['OctoTWTMainSettingsTargetFrameGlow']:SetChecked(OctoTWT_CONFIG.glow)
    _G['OctoTWTMainSettingsTargetFrameGlowUF']:SetChecked(OctoTWT_CONFIG.glowUF)
    _G['OctoTWTMainSettingsPercNumbers']:SetChecked(OctoTWT_CONFIG.perc)
    _G['OctoTWTMainSettingsPercNumbersUF']:SetChecked(OctoTWT_CONFIG.percUF)
    _G['OctoTWTMainSettingsPercNumbersUFtop']:SetChecked(OctoTWT_CONFIG.percUFtop)
    _G['OctoTWTMainSettingsPercNumbersUFbottom']:SetChecked(OctoTWT_CONFIG.percUFbottom)
    _G['OctoTWTMainSettingsShowInCombat']:SetChecked(OctoTWT_CONFIG.showInCombat)
    _G['OctoTWTMainSettingsHideOOC']:SetChecked(OctoTWT_CONFIG.hideOOC)
    _G['OctoTWTMainSettingsFullScreenGlow']:SetChecked(OctoTWT_CONFIG.fullScreenGlow)
    _G['OctoTWTMainSettingsAggroSound']:SetChecked(OctoTWT_CONFIG.aggroSound)
    _G['OctoTWTMainSettingsTankMode']:SetChecked(OctoTWT_CONFIG.tankMode)

    _G['OctoTWTMainSettingsColumnsTPS']:SetChecked(OctoTWT_CONFIG.colTPS)
    _G['OctoTWTMainSettingsColumnsThreat']:SetChecked(OctoTWT_CONFIG.colThreat)
    _G['OctoTWTMainSettingsColumnsPercent']:SetChecked(OctoTWT_CONFIG.colPerc)

    _G['OctoTWTMainSettingsLabelRow']:SetChecked(OctoTWT_CONFIG.labelRow)

    TWT.setColumnLabels()

    if OctoTWT_CONFIG.labelRow then
        _G['OctoTWTMainBarsBG']:SetPoint('TOPLEFT', 1, -40)
        _G['OctoTWTMainNameLabel']:Show()
    else
        _G['OctoTWTMainBarsBG']:SetPoint('TOPLEFT', 1, -20)
        _G['OctoTWTMainNameLabel']:Hide()
        _G['OctoTWTMainTPSLabel']:Hide()
        _G['OctoTWTMainThreatLabel']:Hide()
        _G['OctoTWTMainPercLabel']:Hide()
    end

    _G['OctoTWTMainSettingsFontButtonNT']:SetVertexColor(0.4, 0.4, 0.4)

    local color = TWT.classColors[TWT.class]

    _G['OctoTWTMainTitleBG']:SetVertexColor(color.r, color.g, color.b)
    _G['OctoTWTMainSettingsTitleBG']:SetVertexColor(color.r, color.g, color.b)
    _G['OctoTWTMainTankModeWindowTitleBG']:SetVertexColor(color.r, color.g, color.b)

    _G['OctoTWThreatDisplayTarget']:SetScale(UIParent:GetScale())

    -- fonts
    local fontFrames = {}

    for i, font in TWT.fonts do
        fontFrames[i] = CreateFrame('Button', 'Font_' .. font, _G['OctoTWTMainSettingsFontList'], 'OctoTWTFontFrameTemplate')

        fontFrames[i]:SetPoint("TOPLEFT", _G["OctoTWTMainSettingsFontList"], "TOPLEFT", 0, 17 - i * 17)

        _G['Font_' .. font]:SetID(i)
        _G['Font_' .. font .. 'Name']:SetFont("Interface\\AddOns\\OctoUI\\Modules\\Threat\\fonts\\" .. font .. ".ttf", 15)
        _G['Font_' .. font .. 'Name']:SetText(font)
        _G['Font_' .. font .. 'HT']:SetVertexColor(1, 1, 1, 0.5)

        fontFrames[i]:Show()
    end

    --UnitPopupButtons["INSPECT_TALENTS"] = { text = 'Inspect Talents', dist = 0 }
    --
    --TWT.addInspectMenu("PARTY")
    --TWT.addInspectMenu("PLAYER")
    --TWT.addInspectMenu("RAID")
    --
    --TWT.hooksecurefunc("UnitPopup_OnClick", function()
    --    local button = this.value
    --    if button == "INSPECT_TALENTS" then
    --
    --        _G['OctoTWTTalentFrame']:Hide()
    --
    --        OctoTWT_SPEC = {
    --            class = UnitClass('target'),
    --            {
    --                name = 'Arms',
    --                iconTexture = 'interface\\icons\\ability_warrior_cleave',
    --                pointsSpent = 27,
    --                numTalents = 18
    --            },
    --            {
    --                name = 'Fury',
    --                iconTexture = 'interface\\icons\\ability_warrior_cleave',
    --                pointsSpent = 24,
    --                numTalents = 17
    --            },
    --            {
    --                name = 'Protection',
    --                iconTexture = 'interface\\icons\\ability_warrior_cleave',
    --                pointsSpent = 0,
    --                numTalents = 17
    --            }
    --        }
    --
    --        TWT.send('TWTShowTalents:' .. UnitName('target'))
    --
    --    end
    --end)
    --
    --UIParentLoadAddOn("Blizzard_TalentUI")

    TWT.updateTitleBarText()
    TWT.updateSettingsTabs(1)

    TWT.checkTargetFrames()

    OctoTWTPrint(TWT.addonName .. ' |cffabd473v' .. TWT.addonVer .. '|cffffffff loaded.')
    return true
end

function TWT.updateSettingsTabs(tab)
    local color = TWT.classColors[TWT.class]
    _G['OctoTWTMainSettingsTabsUnderline']:SetVertexColor(color.r, color.g, color.b)

    for i = 1, 3 do
        _G['OctoTWTMainSettingsTab' .. i]:Hide()
        _G['OctoTWTMainSettingsTab' .. i .. 'ButtonNT']:SetVertexColor(color.r, color.g, color.b, 0.4)
        _G['OctoTWTMainSettingsTab' .. i .. 'ButtonHT']:SetVertexColor(color.r, color.g, color.b, 0.4)
        _G['OctoTWTMainSettingsTab' .. i .. 'ButtonPT']:SetVertexColor(color.r, color.g, color.b, 0.4)
        _G['OctoTWTMainSettingsTab' .. i .. 'ButtonText']:SetTextColor(0.4, 0.4, 0.4)
    end

    _G['OctoTWTMainSettingsTab' .. tab .. 'ButtonNT']:SetVertexColor(color.r, color.g, color.b, 1)
    _G['OctoTWTMainSettingsTab' .. tab .. 'ButtonText']:SetTextColor(1, 1, 1)

    _G['OctoTWTMainSettingsTab' .. tab]:Show()

end

function OctoTWTSettingsTab_OnClick(tab)
    TWT.updateSettingsTabs(tab)
end

function OctoTWTHealerMasterTarget_OnClick()

    TWT.getClasses()

    if not UnitExists('target') or not UnitIsPlayer('target')
            or UnitName('target') == TWT.name then

        if TWT.healerMasterTarget == '' then
            OctoTWTPrint('Please target a tank.')
        else
            TWT.removeHealerMasterTarget()
        end

        return false
    end

    if UnitName('target') == TWT.healerMasterTarget then
        return TWT.removeHealerMasterTarget()
    end

    TWT.send('TWT_HMT:' .. UnitName('target'))

    local color = TWT.classColors[TWT.getClass(UnitName('target'))]

    OctoTWTPrint('Trying to set Healer Master Target to ' .. color.c .. UnitName('target'))

end

function TWT.removeHealerMasterTarget()
    TWT.send('TWT_HMT_REM:' .. TWT.healerMasterTarget)

    OctoTWTPrint('Healer Master Target cleared.')

    TWT.healerMasterTarget = ''
    TWT.targetName = ''

    TWT.threats = TWT.wipe(TWT.threats)

    _G['OctoTWTMainSettingsHealerMasterTargetButton']:SetText('From Target')
    _G['OctoTWTMainSettingsHealerMasterTargetButtonNT']:SetVertexColor(1, 1, 1, 1)

    TWT.updateUI('removeHealerMasterTarget')

    return true
end

function TWT.addInspectMenu(to)
    local found = 0
    for i, j in UnitPopupMenus[to] do
        if j == "TRADE" then
            found = i
        end
    end
    if found ~= 0 then
        UnitPopupMenus[to][__getn(UnitPopupMenus[to]) + 1] = UnitPopupMenus[to][__getn(UnitPopupMenus[to])]
        for i = __getn(UnitPopupMenus[to]) - 1, found, -1 do
            UnitPopupMenus[to][i] = UnitPopupMenus[to][i - 1]
        end
    end
    UnitPopupMenus[to][found] = "INSPECT_TALENTS"
end

TWT.classes = {}

function TWT.getClass(name)
    return TWT.classes[name] or 'priest'
end

function TWT.getClasses()
    if TWT.channel == 'RAID' then
        for i = 0, GetNumRaidMembers() do
            if GetRaidRosterInfo(i) then
                local name = GetRaidRosterInfo(i)
                local _, raidCls = UnitClass('raid' .. i)
                TWT.classes[name] = __lower(raidCls)
            end
        end
    end
    if TWT.channel == 'PARTY' then
        if GetNumPartyMembers() > 0 then
            for i = 1, GetNumPartyMembers() do
                if UnitName('party' .. i) and UnitClass('party' .. i) then
                    local name = UnitName('party' .. i)
                    local _, raidCls = UnitClass('party' .. i)
                    TWT.classes[name] = __lower(raidCls)
                end
            end
        end
    end
    OctoTWTDebug('classes saved')
    return true
end

TWT.history = {}

TWT.tankName = ''

function TWT.handleThreatPacket(packet)

    --OctoTWTDebug(packet)

    local playersString = __substr(packet, __find(packet, TWT.threatApi) + __strlen(TWT.threatApi), __strlen(packet))

    TWT.threats = TWT.wipe(TWT.threats)
    TWT.tankName = ''

    local players = OctoTWTExplode(playersString, ';')

    for _, tData in players do

        local msgEx = OctoTWTExplode(tData, ':')

        -- udts handling
        if msgEx[1] and msgEx[2] and msgEx[3] and msgEx[4] and msgEx[5] then

            local player = msgEx[1]
            local tank = msgEx[2] == '1'
            local threat = __parseint(msgEx[3])
            local perc = __parseint(msgEx[4])
            local melee = msgEx[5] == '1'

            if UnitName('target') and not UnitIsPlayer('target') and TWT.shouldRelay then
                --relay
                for i, name in TWT.relayTo do
                    OctoTWTDebug('relaying to ' .. i .. ' ' .. name)
                end
                TWT.send('TWTRelayV1' ..
                        ':' .. UnitName('target') ..
                        ':' .. player ..
                        ':' .. msgEx[3] ..
                        ':' .. threat ..
                        ':' .. perc ..
                        ':' .. msgEx[6]);
            end

            local time = time()

            if TWT.history[player] then
                TWT.history[player][time] = threat
            else
                TWT.history[player] = {}
            end

            TWT.threats[player] = {
                threat = threat,
                tank = tank,
                perc = perc,
                melee = melee,
                tps = TWT.calcTPS(player),
                class = TWT.getClass(player)
            }

            if tank then
                TWT.tankName = player
            end
        end
    end

    TWT.calcAGROPerc()

    TWT.updateUI()

end

function TWT.handleTankModePacket(packet)

    --OctoTWTDebug(msg)

    local playersString = __substr(packet, __find(packet, TWT.tankModeApi) + __strlen(TWT.tankModeApi), __strlen(packet))

    TWT.tankModeThreats = TWT.wipe(TWT.tankModeThreats)

    local players = OctoTWTExplode(playersString, ';')

    for _, tData in players do

        local msgEx = OctoTWTExplode(tData, ':')

        if msgEx[1] and msgEx[2] and msgEx[3] and msgEx[4] then

            local creature = msgEx[1]
            local guid = msgEx[2] --keep it string
            local name = msgEx[3]
            local perc = __parseint(msgEx[4])

            TWT.tankModeThreats[guid] = {
                creature = creature,
                name = name,
                perc = perc
            }

            --TWT.updateUI('handleTMServerMSG')

        end

    end

end

function TWT.calcAGROPerc()

    local tankThreat = 0
    for _, data in next, TWT.threats do
        if data.tank then
            tankThreat = data.threat
            break
        end
    end

    TWT.threats[TWT.AGRO] = {
        class = 'agro',
        threat = 0,
        perc = 100,
        tps = '',
        history = {},
        tank = false,
        melee = false
    }

    if not TWT.threats[TWT.name] then
        OctoTWTDebug('threats de name is bad')
        return false
    end

    TWT.threats[TWT.AGRO].threat = tankThreat * (TWT.threats[TWT.name].melee and 1.1 or 1.3)
    if TWT.threats[TWT.AGRO].threat == 0 then
        TWT.threats[TWT.AGRO].threat = 1
    end
    TWT.threats[TWT.AGRO].perc = TWT.threats[TWT.name].melee and 110 or 130

end

function TWT.combatStart()

    TWT.updateTargetFrameThreatIndicators(-1, '')
    timeStart = GetTime()
    totalPackets = 0
    totalData = 0

    --OctoTWTDebug('wipe threats combatstart')
    --TWT.threats = TWT.wipe(TWT.threats)
    --TWT.tankModeThreats = TWT.wipe(TWT.tankModeThreats)
    TWT.hideThreatFrames(true)
    TWT.shouldRelay = TWT.checkRelay()

    --Was an unconditional "solo means stop here", which returned before threatQuery was
    --ever shown -- so solo play never ran the loop that asks the server for threat, and
    --the window sat empty and blameless. See TWT.ThreatWanted.
    if not TWT.ThreatWanted() then
        return false
    end

    if OctoTWT_CONFIG.showInCombat then
        _G['OctoTWTMain']:Show()
    end

    TWT.spec = {}
    for t = 1, GetNumTalentTabs() do
        TWT.spec[t] = {
            talents = 0,
            texture = ''
        }
        for i = 1, GetNumTalents(t) do
            local _, _, _, _, currRank = GetTalentInfo(t, i);
            TWT.spec[t].talents = TWT.spec[t].talents + currRank
        end
    end

    local specIndex = 1
    for i = 2, 4 do
        local name, texture = GetSpellTabInfo(i);
        if name and texture then
            TWT.spec[specIndex].name = name
            texture = OctoTWTExplode(texture, '\\')
            texture = texture[__getn(texture)]
            TWT.spec[specIndex].texture = texture
            specIndex = specIndex + 1
        end
    end

    local sendTex = TWT.spec[1].texture
    TWT.updateSpeed = TWT.updateSpeeds[TWT.class][1]
    if TWT.spec[2].talents > TWT.spec[1].talents and TWT.spec[2].talents > TWT.spec[3].talents then
        sendTex = TWT.spec[2].texture
        TWT.updateSpeed = TWT.updateSpeeds[TWT.class][2]
    end
    if TWT.spec[3].talents > TWT.spec[1].talents and TWT.spec[3].talents > TWT.spec[2].talents then
        sendTex = TWT.spec[3].texture
        TWT.updateSpeed = TWT.updateSpeeds[TWT.class][3]
    end

    if TWT.class == 'warrior' and __lower(sendTex) == 'ability_rogue_eviscerate' then
        sendTex = 'ability_warrior_savageblow' --ms
    end

    TWT.send('TWTRoleTexture:' .. sendTex)

    TWT.getClasses()

    TWT.updateUI('combatStart')

    TWT.threatQuery:Show()
    TWT.barAnimator:Show()

    OctoTWTTankModeWindowChangeStick_OnClick()

    _G['OctoTWTMain']:SetAlpha(OctoTWT_CONFIG.combatAlpha)

    return true
end

function TWT.combatEnd()

    TWT.updateTargetFrameThreatIndicators(-1, '')

    OctoTWTDebug('time = ' .. (TWT.round(GetTime() - timeStart)) .. 's packets = ' .. totalPackets .. ' ' ..
            totalPackets / (GetTime() - timeStart) .. ' packets/s')

    timeStart = GetTime()
    totalPackets = 0
    totalData = 0

    OctoTWTDebug('wipe threats combat end')

    TWT.threats = TWT.wipe(TWT.threats)
    TWT.tankModeThreats = TWT.wipe(TWT.tankModeThreats)
    TWT.history = TWT.wipe(TWT.history)

    if OctoTWT_CONFIG.hideOOC then
        _G['OctoTWTMain']:Hide()
    end

    TWT.updateUI('combatEnd')

    TWT.threatQuery:Hide()
    TWT.barAnimator:Hide()

    if OctoTWT_CONFIG.tankMode then
        _G['OctoTWTMainTankModeWindow']:Hide()
    end

    _G['OctoTWTWarning']:Hide()

    TWT.updateTitleBarText()

    _G['OctoTWTMain']:SetAlpha(OctoTWT_CONFIG.oocAlpha)

    TWT.hideThreatFrames(true)

    return true

end

function TWT.checkRelay()

    if GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0 then
        return false
    end

    if __getn(TWT.relayTo) == 0 then
        return false
    end

    -- in raid
    if TWT.channel == 'RAID' and GetNumRaidMembers() > 0 then
        for index, name in TWT.relayTo do
            local found = false
            for i = 0, GetNumRaidMembers() do
                if GetRaidRosterInfo(i) and UnitName('raid' .. i) == name then
                    found = true
                end
            end
            if not found then
                TWT.relayTo[index] = nil
                OctoTWTDebug(name .. ' removed from relay')
            end
        end
    end
    if TWT.channel == 'PARTY' and GetNumPartyMembers() > 0 then
        for index, name in TWT.relayTo do
            local found = false
            for i = 1, GetNumPartyMembers() do
                if UnitName('party' .. i) == name then
                    found = true
                end
            end
            if not found then
                TWT.relayTo[index] = nil
                OctoTWTDebug(name .. ' removed from relay')
            end
        end
    end

    if __getn(TWT.relayTo) == 0 then
        return false
    end

    return true
end

function TWT.checkTargetFrames()
    if _G['TargetFrame']:IsVisible() ~= nil then
        TWT.targetFrameVisible = true
    else
        TWT.targetFrameVisible = false
    end

    --ElvUF_Target is spawned at runtime by the UnitFrames module, so the
    --display frame cannot be anchored to it from XML; do it on first sight
    if _G['ElvUF_Target'] and not TWT.ufAnchored then
        _G['OctoTWThreatDisplayTargetUF']:ClearAllPoints()
        _G['OctoTWThreatDisplayTargetUF']:SetPoint('TOPLEFT', _G['ElvUF_Target'], 'TOPLEFT', 0, 0)
        _G['OctoTWThreatDisplayTargetUF']:SetPoint('BOTTOMRIGHT', _G['ElvUF_Target'], 'BOTTOMRIGHT', 0, 0)
        TWT.ufAnchored = true
    end

    if _G['ElvUF_Target'] and _G['ElvUF_Target']:IsVisible() ~= nil then
        TWT.UFtargetFrameVisible = true
    else
        TWT.UFtargetFrameVisible = false
    end
end

function TWT.hideThreatFrames(force)
    if TWT.tableSize(TWT.threats) > 0 or force then
        for name in next, TWT.threatsFrames do
            TWT.threatsFrames[name]:Hide()
        end
    end
end

function TWT.targetChanged()

    if not UnitAffectingCombat('player') and _G['OctoTWTMainSettings']:IsVisible() == 1 then
        return true
    end

    TWT.channel = (GetNumRaidMembers() > 0) and 'RAID' or 'PARTY'

    if UIParent:GetScale() ~= _G['OctoTWThreatDisplayTarget']:GetScale() then
        _G['OctoTWThreatDisplayTarget']:SetScale(UIParent:GetScale())
    end

    if TWT.healerMasterTarget ~= '' then
        return true
    end

    TWT.targetName = ''
    TWT.updateTargetFrameThreatIndicators(-1)

    -- lost target
    if not UnitExists('target') then
        return false
    end

    -- target is dead, dont show anything
    if UnitIsDead('target') then
        return false
    end

    -- dont show anything
    if UnitIsPlayer('target') then
        return false
    end

    -- non interesting target. Grouped only: solo play is nearly all ordinary mobs, and
    -- the filter exists to stop a raid asking about every trash pull, not to stop one
    -- player asking about the one thing they are fighting.
    if not TWT.Solo()
            and UnitClassification('target') ~= 'worldboss'
            and UnitClassification('target') ~= 'elite' then
        return false
    end

    -- solo is allowed now, unless the option turns it off
    if not TWT.ThreatWanted() then
        return false
    end

    -- not in combat
    if not UnitAffectingCombat('player') or not UnitAffectingCombat('target') then
        return false
    end

    OctoTWTDebug('wipe target changed')
    TWT.threats = TWT.wipe(TWT.threats)
    TWT.history = TWT.wipe(TWT.history)

    if OctoTWT_CONFIG.skeram then
        -- skeram hax
        --The Prophet Skeram
        --_G['OctoTWTWarning']:Hide()
        --if UnitAffectingCombat('player') then
        --    if UnitName('target') == 'The Prophet Skeram' and TWT.custom['The Prophet Skeram'] ~= 0 then

        --            _G['OctoTWTWarningText']:SetText("|cff00ff00- REAL -");
        --            _G['OctoTWTWarning']:Show()
        --        else
        --            _G['OctoTWTWarningText']:SetText("- CLONE -");
        --            _G['OctoTWTWarning']:Show()
        --        end
        --    end
        --end
    end

    TWT.targetName = TWT.unitNameForTitle(UnitName('target'))

    TWT.updateTitleBarText(TWT.targetName)

    return true
end

--[[ solo threat ]]--
--
--Upstream never asked the server for threat unless you were grouped, so playing solo
--showed an empty window for ever -- which is what "the threat meter does not track
--anything" turned out to mean. It is a real gap and not a quirk: for a warlock or a
--hunter the whole question is whether the pet is holding aggro, and solo is precisely
--when there is no one else to ask.
--
--Two things stood in the way. The request needs somewhere to go, and SendAddonMessage to
--PARTY with no party never leaves the client, so the server never sees it; whispering
--yourself is the one distribution that always sends. And the elite/worldboss filter has
--to relax, because solo play is nearly all ordinary mobs.
--
--That filter stays for grouped play, where it is doing real work: forty raid members
--asking the server about every trash pull is load nobody needs. Solo is one client
--asking about one mob it is already fighting.
function TWT.Solo()
    return GetNumRaidMembers() == 0 and GetNumPartyMembers() == 0
end

local function SoloThreatEnabled()
    return OctoTWT_CONFIG and OctoTWT_CONFIG.soloThreat ~= false
end

--True when this situation should be asking the server for threat at all.
function TWT.ThreatWanted()
    if not TWT.Solo() then return true end

    return SoloThreatEnabled()
end

--Distribution, and for a whisper who to. In one place because four call sites used to
--work this out separately and only one of them was ever right when solo.
local function ThreatChannel()
    if GetNumRaidMembers() > 0 then return 'RAID' end
    if GetNumPartyMembers() > 0 then return 'PARTY' end

    return 'WHISPER', TWT.name
end

function TWT.send(msg)
    local channel, target = ThreatChannel()
    SendAddonMessage(TWT.prefix, msg, channel, target)
end

--Counted so /octoui-threat can tell "we never asked" from "we asked and the server said
--nothing" -- which are completely different faults and look identical from the outside.
TWT.requestsSent = 0
TWT.repliesSeen = 0
TWT.lastReply = nil

function TWT.UnitDetailedThreatSituation(limit)
    local channel, target = ThreatChannel()
    TWT.requestsSent = TWT.requestsSent + 1
    SendAddonMessage(TWT.UDTS .. (OctoTWT_CONFIG.tankMode and '_TM' or ''), "limit=" .. limit, channel, target)
end

function TWT.updateUI(from)

    --OctoTWTDebug('update ui call from [' .. (from or '') .. ']')

    TWT.checkTargetFrames()

    if OctoTWT_CONFIG.debug then
        _G['OctoTWTpps']:SetText('Traffic: ' .. TWT.round((totalPackets / (GetTime() - timeStart)) * 10) / 10
                .. 'packets/s (' .. TWT.round(totalData / (GetTime() - timeStart)) .. ' cps)'
                .. TWT.round(uiUpdates / (GetTime() - timeStart)) .. ' ups ')
        _G['OctoTWTpps']:Show()
    else
        _G['OctoTWTpps']:Hide()
    end

    uiUpdates = uiUpdates + 1

    if not TWT.barAnimator:IsVisible() then
        TWT.barAnimator:Show()
    end

    TWT.hideThreatFrames()

    if not UnitAffectingCombat('player') and not _G['OctoTWTMainSettings']:IsVisible() then
        TWT.updateTargetFrameThreatIndicators(-1)
        return false
    end

    if TWT.targetName == '' then
        return false
    end

    if _G['OctoTWTMainSettings']:IsVisible() and not UnitAffectingCombat('player') then
        TWT.tankName = 'Tenk'
    end

    local index = 0

    for name, data in TWT.ohShitHereWeSortAgain(TWT.threats, true) do

        if data and TWT.threats[TWT.name] and index < OctoTWT_CONFIG.visibleBars then

            index = index + 1
            if not TWT.threatsFrames[index] then
                TWT.threatsFrames[index] = CreateFrame('Frame', 'OctoTWThreat' .. index, _G["OctoTWTMain"], 'OctoTWThreat')
            end

            _G['OctoTWThreat' .. index]:SetAlpha(OctoTWT_CONFIG.combatAlpha)
            _G['OctoTWThreat' .. index]:SetWidth(TWT.windowWidth - 2)

            _G['OctoTWThreat' .. index .. 'Name']:SetFont("Interface\\AddOns\\OctoUI\\Modules\\Threat\\fonts\\" .. OctoTWT_CONFIG.font .. ".ttf", 15, "OUTLINE")
            _G['OctoTWThreat' .. index .. 'TPS']:SetFont("Interface\\AddOns\\OctoUI\\Modules\\Threat\\fonts\\" .. OctoTWT_CONFIG.font .. ".ttf", 15, "OUTLINE")
            _G['OctoTWThreat' .. index .. 'Threat']:SetFont("Interface\\AddOns\\OctoUI\\Modules\\Threat\\fonts\\" .. OctoTWT_CONFIG.font .. ".ttf", 15, "OUTLINE")
            _G['OctoTWThreat' .. index .. 'Perc']:SetFont("Interface\\AddOns\\OctoUI\\Modules\\Threat\\fonts\\" .. OctoTWT_CONFIG.font .. ".ttf", 15, "OUTLINE")

            _G['OctoTWThreat' .. index]:SetHeight(OctoTWT_CONFIG.barHeight - 1)
            _G['OctoTWThreat' .. index .. 'BG']:SetHeight(OctoTWT_CONFIG.barHeight - 2)

            TWT.threatsFrames[index]:ClearAllPoints()
            TWT.threatsFrames[index]:SetPoint("TOPLEFT", _G["OctoTWTMain"], "TOPLEFT", 0,
                    (OctoTWT_CONFIG.labelRow and -40 or -20) +
                            OctoTWT_CONFIG.barHeight - 1 - index * OctoTWT_CONFIG.barHeight)


            -- icons
            _G['OctoTWThreat' .. index .. 'AGRO']:Hide()
            _G['OctoTWThreat' .. index .. 'Role']:Show()
            if name ~= TWT.AGRO then

                _G['OctoTWThreat' .. index .. 'Role']:SetWidth(OctoTWT_CONFIG.barHeight - 2)
                _G['OctoTWThreat' .. index .. 'Role']:SetHeight(OctoTWT_CONFIG.barHeight - 2)
                _G['OctoTWThreat' .. index .. 'Name']:SetPoint('LEFT', _G['OctoTWThreat' .. index .. 'Role'], 'RIGHT', 1 + (OctoTWT_CONFIG.barHeight / 15), -1)
                if TWT.roles[name] then
                    _G['OctoTWThreat' .. index .. 'Role']:SetTexture('Interface\\Icons\\' .. TWT.roles[name])
                    _G['OctoTWThreat' .. index .. 'Role']:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    _G['OctoTWThreat' .. index .. 'Role']:Show()
                else
                    _G['OctoTWThreat' .. index .. 'Role']:SetTexture('Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes')
                    _G['OctoTWThreat' .. index .. 'Role']:SetTexCoord(unpack(TWT.classCoords[data.class]))
                end

            else
                _G['OctoTWThreat' .. index .. 'AGRO']:Show()
                _G['OctoTWThreat' .. index .. 'Role']:Hide()
            end


            -- tps
            _G['OctoTWThreat' .. index .. 'TPS']:SetText(data.tps)

            -- labels
            TWT.setBarLabels(_G['OctoTWThreat' .. index .. 'Perc'], _G['OctoTWThreat' .. index .. 'Threat'], _G['OctoTWThreat' .. index .. 'TPS'])

            -- perc
            _G['OctoTWThreat' .. index .. 'Perc']:SetText(TWT.round(data.perc) .. '%')

            if TWT.name ~= TWT.tankName and name == TWT.AGRO then
                _G['OctoTWThreat' .. index .. 'Perc']:SetText(100 - TWT.round(TWT.threats[TWT.name].perc) .. '%')
            end

            -- name
            _G['OctoTWThreat' .. index .. 'Name']:SetText(TWT.classColors['priest'].c .. name)

            -- bar width and color
            local color = TWT.classColors[data.class]

            if name == TWT.name then

                if OctoTWT_CONFIG.aggroSound and data.perc >= OctoTWT_CONFIG.aggroThreshold and time() - TWT.lastAggroWarningSoundTime > 5
                        and not OctoTWT_CONFIG.fullScreenGlow then
                    PlaySoundFile('Interface\\AddOns\\OctoUI\\Modules\\Threat\\sounds\\warn.ogg')
                    TWT.lastAggroWarningSoundTime = time()
                end

                if OctoTWT_CONFIG.fullScreenGlow and data.perc >= OctoTWT_CONFIG.aggroThreshold and time() - TWT.lastAggroWarningGlowTime > 5 then
                    TWT.glowFader:Show()
                    TWT.lastAggroWarningGlowTime = time()
                    if OctoTWT_CONFIG.aggroSound then
                        PlaySoundFile('Interface\\AddOns\\OctoUI\\Modules\\Threat\\sounds\\warn.ogg')
                    end
                end

                TWT.updateTitleBarText(TWT.targetName .. ' (' .. TWT.round(data.perc) .. '%)')

                _G['OctoTWThreat' .. index .. 'Threat']:SetText(TWT.formatNumber(data.threat))

                TWT.barAnimator:animateTo(index, data.perc)

            elseif name == TWT.AGRO then

                TWT.barAnimator:animateTo(index, nil)

                _G['OctoTWThreat' .. index .. 'BG']:SetWidth(TWT.windowWidth - 2)
                _G['OctoTWThreat' .. index .. 'Threat']:SetText('+' .. TWT.formatNumber(data.threat - TWT.threats[TWT.name].threat))

                local colorLimit = 50

                if TWT.threats[TWT.name].perc >= 0 and TWT.threats[TWT.name].perc < colorLimit then
                    _G['OctoTWThreat' .. index .. 'BG']:SetVertexColor(TWT.threats[TWT.name].perc / colorLimit, 1, 0, 0.9)
                elseif TWT.threats[TWT.name].perc >= colorLimit then
                    _G['OctoTWThreat' .. index .. 'BG']:SetVertexColor(1, 1 - (TWT.threats[TWT.name].perc - colorLimit) / colorLimit, 0, 0.9)
                end

                if TWT.tankName == TWT.name then
                    _G['OctoTWThreat' .. index .. 'BG']:SetVertexColor(1, 0, 0, 1)
                    _G['OctoTWThreat' .. index .. 'Perc']:SetText('')
                end

            else

                TWT.barAnimator:animateTo(index, data.perc)

                _G['OctoTWThreat' .. index .. 'Threat']:SetText(TWT.formatNumber(data.threat))
                _G['OctoTWThreat' .. index .. 'BG']:SetVertexColor(color.r, color.g, color.b, 0.9)
            end

            if data.tank then

                TWT.barAnimator:animateTo(index, 100, true)

            end

            if name == TWT.name then
                _G['OctoTWThreat' .. index .. 'BG']:SetVertexColor(1, 0.2, 0.2, 1)
                TWT.updateTargetFrameThreatIndicators(data.perc)
            end

            TWT.threatsFrames[index]:Show()

        end

    end

    if OctoTWT_CONFIG.tankMode then

        _G['OctoTMEF1']:Hide()
        _G['OctoTMEF2']:Hide()
        _G['OctoTMEF3']:Hide()
        _G['OctoTMEF4']:Hide()
        _G['OctoTMEF5']:Hide()

        _G['OctoTWTMainTankModeWindow']:SetHeight(0)

        if TWT.tableSize(TWT.tankModeThreats) > 1 then

            local i = 0
            for guid, data in next, TWT.tankModeThreats do

                i = i + 1
                if i > 5 then
                    break
                end
                _G['OctoTWTMainTankModeWindow']:SetHeight(i * 25 + 23)

                _G['OctoTMEF' .. i .. 'Target']:SetText(data.creature)
                _G['OctoTMEF' .. i .. 'Player']:SetText(TWT.classColors[TWT.getClass(data.name)].c .. data.name)
                _G['OctoTMEF' .. i .. 'Perc']:SetText(TWT.round(data.perc) .. '%')
                _G['OctoTMEF' .. i .. 'TargetButton']:SetID(guid)
                _G['OctoTMEF' .. i]:SetPoint("TOPLEFT", _G["OctoTWTMainTankModeWindow"], "TOPLEFT", 0, -21 + 24 - i * 25)

                _G['OctoTMEF' .. i .. 'RaidTargetIcon']:Hide()

                if data.perc >= 0 and data.perc < 50 then
                    _G['OctoTMEF' .. i .. 'BG']:SetVertexColor(data.perc / 50, 1, 0, 0.5)
                else
                    _G['OctoTMEF' .. i .. 'BG']:SetVertexColor(1, 1 - (data.perc - 50) / 50, 0, 0.5)
                end

                _G['OctoTMEF' .. i]:Show()

                _G['OctoTWTMainTankModeWindow']:Show()

            end

        else
            _G['OctoTWTMainTankModeWindow']:Hide()
        end
    else
        _G['OctoTWTMainTankModeWindow']:Hide()
    end

end

TWT.barAnimator = CreateFrame('Frame')
TWT.barAnimator:Hide()
TWT.barAnimator.frames = {}

function TWT.barAnimator:animateTo(index, perc, instant)

    if perc == nil then
        TWT.barAnimator.frames['OctoTWThreat' .. index .. 'BG'] = perc
        return false
    end

    perc = TWT.round(perc)
    perc = perc > 100 and 100 or perc

    local width = TWT.round((TWT.windowWidth - 2) * perc / 100)
    if instant then
        _G['OctoTWThreat' .. index .. 'BG']:SetWidth(width)
        return true
    end
    TWT.barAnimator.frames['OctoTWThreat' .. index .. 'BG'] = width
end

TWT.barAnimator:SetScript("OnShow", function()
    this.startTime = GetTime()
    TWT.barAnimator.frames = {}
end)
TWT.barAnimator:SetScript("OnUpdate", function()
    local currentW, step, diff
    for frame, w in TWT.barAnimator.frames do
        currentW = TWT.round(_G[frame]:GetWidth())

        diff = currentW - w

        if diff ~= 0 then

            step = 12
            --if __abs(diff) > 50 then
            --    step = 9
            --elseif __abs(diff) > 100 then
            --    step = 12
            --elseif __abs(diff) > 200 then
            --    step = 15
            --end

            -- grow
            if diff < 0 then
                if __abs(diff) < step then
                    step = __abs(diff)
                end
                _G[frame]:SetWidth(currentW + step)
            else
                if diff < step then
                    step = diff
                end
                _G[frame]:SetWidth(currentW - step)
            end
        end
    end
end)

TWT.threatQuery:SetScript("OnShow", function()
    this.startTime = GetTime()
end)
TWT.threatQuery:SetScript("OnHide", function()
end)
TWT.threatQuery:SetScript("OnUpdate", function()
    local plus = TWT.updateSpeed
    local gt = GetTime() * 1000
    local st = (this.startTime + plus) * 1000
    if gt >= st then
        this.startTime = GetTime()
        if not TWT.ThreatWanted() then
            return false
        end
        if UnitAffectingCombat('player') and UnitAffectingCombat('target') then

            if TWT.targetName == '' then
                OctoTWTDebug('threatQuery target = blank ')
                -- try to re-get target
                TWT.targetChanged()
                return false
            end

            if OctoTWT_CONFIG.glow or OctoTWT_CONFIG.perc or
                    OctoTWT_CONFIG.glowUF or OctoTWT_CONFIG.percUF or
                    OctoTWT_CONFIG.fullScreenGlow or OctoTWT_CONFIG.tankmode or
                    OctoTWT_CONFIG.visible then
                if TWT.healerMasterTarget == '' then
                    TWT.UnitDetailedThreatSituation(OctoTWT_CONFIG.visibleBars - 1)
                end
            else
                OctoTWTDebug('not asking threat situation')
            end

        end
    end
end)

function TWT.calcTPS(name)

    local data = TWT.history[name]

    if not data then
        return 0
    end

    local older = time()
    for t in next, data do
        if t < older then
            older = t
        end
    end

    if TWT.tableSize(data) > 10 then
        TWT.history[name][older] = nil
    end

    local tps = 0
    local mean = 0

    local time = time()

    for i = 0, TWT.tableSize(data) - 1 do
        if TWT.history[name][time - i] and TWT.history[name][time - i - 1] then
            tps = tps + TWT.history[name][time - i] - TWT.history[name][time - i - 1]
            mean = mean + 1
        end
    end

    if mean > 0 and tps > 0 then
        return TWT.round(tps / mean)
    end

    return 0

end

function TWT.updateTargetFrameThreatIndicators(perc)

    if OctoTWT_CONFIG.fullScreenGlow then
        _G['OctoTWTFullScreenGlow']:Show()
    else
        _G['OctoTWTFullScreenGlow']:Hide()
    end

    if perc == -1 then
        TWT.updateTitleBarText()
        _G['OctoTWThreatDisplayTarget']:Hide()
        _G['OctoTWThreatDisplayTargetUF']:Hide()

        --TWT.hideThreatFrames()

        return false
    end

    if not OctoTWT_CONFIG.glow and not OctoTWT_CONFIG.perc and not TWT.targetFrameVisible then
        _G['OctoTWThreatDisplayTarget']:Hide()
    end

    if not OctoTWT_CONFIG.glowUF and not OctoTWT_CONFIG.percUF and not TWT.UFtargetFrameVisible then
        _G['OctoTWThreatDisplayTargetUF']:Hide()
    end

    if not TWT.targetFrameVisible and not TWT.UFtargetFrameVisible then
        return false
    end

    if TWT.targetFrameVisible then
        _G['OctoTWThreatDisplayTarget']:Show()
    end
    if TWT.UFtargetFrameVisible then
        _G['OctoTWThreatDisplayTargetUF']:Show()
    end

    perc = TWT.round(perc)

    if OctoTWT_CONFIG.glow then

        local unitClassification = UnitClassification('target')
        if unitClassification == 'worldboss' then
            unitClassification = 'elite'
        end

        _G['OctoTWThreatDisplayTargetGlow']:SetTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\' .. unitClassification)

        if perc >= 0 and perc < 50 then
            _G['OctoTWThreatDisplayTargetGlow']:SetVertexColor(perc / 50, 1, 0, perc / 50)
        elseif perc >= 50 then
            _G['OctoTWThreatDisplayTargetGlow']:SetVertexColor(1, 1 - (perc - 50) / 50, 0, 1)
        end

        _G['OctoTWThreatDisplayTargetGlow']:Show()
    else
        _G['OctoTWThreatDisplayTargetGlow']:Hide()
    end

    if OctoTWT_CONFIG.glowUF and _G['ElvUF_Target'] then

        if perc >= 0 and perc < 50 then
            _G['OctoTWThreatDisplayTargetUFGlow']:SetVertexColor(perc / 50, 1, 0, perc / 50)
        elseif perc >= 50 then
            _G['OctoTWThreatDisplayTargetUFGlow']:SetVertexColor(1, 1 - (perc - 50) / 50, 0, 1)
        end

        _G['OctoTWThreatDisplayTargetUFGlow']:Show()
    else
        _G['OctoTWThreatDisplayTargetUFGlow']:Hide()
    end

    if OctoTWT_CONFIG.perc then

        if OctoTWT_CONFIG.tankMode then
            _G['OctoTWThreatDisplayTargetNumericBG']:SetPoint('TOPLEFT', 24, -7)
            _G['OctoTWThreatDisplayTargetNumericBG']:SetWidth(79)
            _G['OctoTWThreatDisplayTargetNumericBorder']:SetPoint('TOPLEFT', 20, -3)
            _G['OctoTWThreatDisplayTargetNumericBorder']:SetWidth(128)
            _G['OctoTWThreatDisplayTargetNumericBorder']:SetTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\numericthreatborder_wide')
            _G['OctoTWThreatDisplayTargetNumericPerc']:SetPoint('TOPLEFT', -1, 3)
            _G['OctoTWThreatDisplayTargetNumericPerc']:SetWidth(128)
        else
            _G['OctoTWThreatDisplayTargetNumericBG']:SetPoint('TOPLEFT', 44, -7)
            _G['OctoTWThreatDisplayTargetNumericBG']:SetWidth(36)
            _G['OctoTWThreatDisplayTargetNumericBorder']:SetPoint('TOPLEFT', 38, -3)
            _G['OctoTWThreatDisplayTargetNumericBorder']:SetWidth(64)
            _G['OctoTWThreatDisplayTargetNumericBorder']:SetTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\numericthreatborder')
            _G['OctoTWThreatDisplayTargetNumericPerc']:SetPoint('TOPLEFT', 31, 3)
            _G['OctoTWThreatDisplayTargetNumericPerc']:SetWidth(64)
        end

        local tankModePerc = 0

        if OctoTWT_CONFIG.tankMode then
            local second = ''
            local index = 0
            for name, data in TWT.ohShitHereWeSortAgain(TWT.threats, true) do
                index = index + 1
                if index == 3 then
                    tankModePerc = TWT.round(data.perc)
                    second = TWT.unitNameForTitle(name, 6) .. ' ' .. tankModePerc .. '%'
                    break
                    --TWT.classColors[TWT.getClass(name)].c ..
                end
            end
            if second ~= '' then
                _G['OctoTWThreatDisplayTargetNumericPerc']:SetText(second)
            else
                _G['OctoTWThreatDisplayTargetNumericPerc']:SetText(perc .. '%')
            end
        else
            _G['OctoTWThreatDisplayTargetNumericPerc']:SetText(perc .. '%')
        end

        if tankModePerc ~= 0 then
            perc = tankModePerc
        end

        if perc >= 0 and perc < 50 then
            _G['OctoTWThreatDisplayTargetNumericBG']:SetVertexColor(perc / 50, 1, 0, 1)
        elseif perc >= 50 then
            _G['OctoTWThreatDisplayTargetNumericBG']:SetVertexColor(1, 1 - (perc - 50) / 50, 0)
        end

        _G['OctoTWThreatDisplayTargetNumericPerc']:Show()
        _G['OctoTWThreatDisplayTargetNumericBG']:Show()
        _G['OctoTWThreatDisplayTargetNumericBorder']:Show()
    else
        _G['OctoTWThreatDisplayTargetNumericPerc']:Hide()
        _G['OctoTWThreatDisplayTargetNumericBG']:Hide()
        _G['OctoTWThreatDisplayTargetNumericBorder']:Hide()
    end

    if OctoTWT_CONFIG.percUF and _G['ElvUF_Target'] then

        local offset = 0
        if OctoTWT_CONFIG.percUFbottom then
            offset = -_G['ElvUF_Target']:GetHeight() - 32 / 2
        end

        if OctoTWT_CONFIG.tankMode then
            _G['OctoTWThreatDisplayTargetUFNumericBG']:SetPoint('TOPLEFT', 0, 18 + offset)
            _G['OctoTWThreatDisplayTargetUFNumericBG']:SetWidth(76)
            _G['OctoTWThreatDisplayTargetUFNumericBorder']:SetPoint('TOPLEFT', -6, 19 + offset)
            _G['OctoTWThreatDisplayTargetUFNumericBorder']:SetTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\numericthreatborder_pfui_wide')
            _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetPoint('TOPLEFT', -26, 25 + offset)
            _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetWidth(128)
        else
            _G['OctoTWThreatDisplayTargetUFNumericBG']:SetPoint('TOPLEFT', 0, 18 + offset)
            _G['OctoTWThreatDisplayTargetUFNumericBG']:SetWidth(37)
            _G['OctoTWThreatDisplayTargetUFNumericBorder']:SetPoint('TOPLEFT', -6, 19 + offset)
            _G['OctoTWThreatDisplayTargetUFNumericBorder']:SetTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\numericthreatborder_pfui')
            _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetPoint('TOPLEFT', -12, 25 + offset)
            _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetWidth(64)
        end

        local tankModePerc = 0

        if OctoTWT_CONFIG.tankMode then
            local second = ''
            local index = 0
            for name, data in TWT.ohShitHereWeSortAgain(TWT.threats, true) do
                index = index + 1
                if index == 3 then
                    tankModePerc = TWT.round(data.perc)
                    second = TWT.unitNameForTitle(name, 6) .. ' ' .. tankModePerc .. '%'
                    break
                end
            end
            if second ~= '' then
                _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetText(second)
            else
                _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetText(perc .. '%')
            end
        else
            _G['OctoTWThreatDisplayTargetUFNumericPerc']:SetText(perc .. '%')
        end

        if tankModePerc ~= 0 then
            perc = tankModePerc
        end

        if perc >= 0 and perc < 50 then
            _G['OctoTWThreatDisplayTargetUFNumericBG']:SetVertexColor(perc / 50, 1, 0, 1)
        elseif perc >= 50 then
            _G['OctoTWThreatDisplayTargetUFNumericBG']:SetVertexColor(1, 1 - (perc - 50) / 50, 0)
        end

        _G['OctoTWThreatDisplayTargetUFNumericPerc']:Show()
        _G['OctoTWThreatDisplayTargetUFNumericBG']:Show()
        _G['OctoTWThreatDisplayTargetUFNumericBorder']:Show()
    else
        _G['OctoTWThreatDisplayTargetUFNumericPerc']:Hide()
        _G['OctoTWThreatDisplayTargetUFNumericBG']:Hide()
        _G['OctoTWThreatDisplayTargetUFNumericBorder']:Hide()
    end

end

function OctoTWTMainWindow_Resizing()
    _G['OctoTWTMain']:SetAlpha(0.4)
end

function OctoTWTMainMainWindow_Resized()
    _G['OctoTWTMain']:SetAlpha(UnitAffectingCombat('player') and OctoTWT_CONFIG.combatAlpha or OctoTWT_CONFIG.oocAlpha)

    OctoTWT_CONFIG.visibleBars = TWT.round((_G['OctoTWTMain']:GetHeight() - (OctoTWT_CONFIG.labelRow and 40 or 20)) / OctoTWT_CONFIG.barHeight)
    OctoTWT_CONFIG.visibleBars = OctoTWT_CONFIG.visibleBars < 4 and 4 or OctoTWT_CONFIG.visibleBars

    OctoTWTFrameHeightSlider_OnValueChanged()
end

function OctoTWTFrameHeightSlider_OnValueChanged()
    --The slider drives this during init, through the SetValue in TWT.init, and a widget
    --that has not finished being laid out can answer with something outside its own
    --declared range. Clamped on the way in so a value like that cannot reach the config
    --and shrink every bar to nothing; see the note beside the default in TWT.init.
    local value = tonumber(_G['OctoTWTMainSettingsFrameHeightSlider']:GetValue())
        or OctoTWT_CONFIG.barHeight or 20

    if value < TWT.minBarHeight then
        value = TWT.minBarHeight
    elseif value > TWT.maxBarHeight then
        value = TWT.maxBarHeight
    end

    OctoTWT_CONFIG.barHeight = value

    _G['OctoTWTMain']:SetHeight(OctoTWT_CONFIG.barHeight * OctoTWT_CONFIG.visibleBars + (OctoTWT_CONFIG.labelRow and 40 or 20))

    TWT.setMinMaxResize()
    TWT.updateUI('OctoTWTFrameHeightSlider_OnValueChanged')
end

--Upstream re-anchored both windows here so a scale change did not move whatever the
--user had dragged into place. That does not survive this port. OctoTWTMain is
--movable="false" in the XML and has no saved position of its own, so it is owned by
--an OctoUI mover instead (see TM:Initialize) -- re-anchoring it here fights the mover,
--and TWT.init drives this through SetValue before the frame's rect has resolved, at
--which point GetLeft()/GetTop() are meaningless and it parked the window below the
--bottom of the screen. Scale OctoTWTMain and leave its position to the mover.
function OctoTWTWindowScaleSlider_OnValueChanged()
    OctoTWT_CONFIG.windowScale = _G['OctoTWTMainSettingsWindowScaleSlider']:GetValue()

    _G['OctoTWTMain']:SetScale(OctoTWT_CONFIG.windowScale)

    --The tank mode window is still movable="true" and drag-positioned, so it does
    --need its position carried across the scale change -- but only once its rect
    --resolves. Before that GetLeft() is nil and the arithmetic below would throw.
    local tank = _G['OctoTWTMainTankModeWindow']
    local sx, sy = tank:GetLeft(), tank:GetTop()
    local ss = tank:GetEffectiveScale()

    tank:SetScale(OctoTWT_CONFIG.windowScale)

    if sx and sy and ss then
        local scaled = tank:GetEffectiveScale()
        tank:ClearAllPoints()
        tank:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", (sx * ss) / scaled, (sy * ss) / scaled)
    end

    if OctoTWT_CONFIG.tankModeStick ~= 'Free' then
        OctoTWTTankModeWindowChangeStick_OnClick(OctoTWT_CONFIG.tankModeStick)
    end
end

function OctoTWTCombatOpacitySlider_OnValueChanged()
    OctoTWT_CONFIG.combatAlpha = _G['OctoTWTMainSettingsCombatAlphaSlider']:GetValue()
    _G['OctoTWTMain']:SetAlpha(UnitAffectingCombat('player') and OctoTWT_CONFIG.combatAlpha or OctoTWT_CONFIG.oocAlpha)
end

function OctoTWTOOCombatSlider_OnValueChanged()
    OctoTWT_CONFIG.oocAlpha = _G['OctoTWTMainSettingsOOCAlphaSlider']:GetValue()
    _G['OctoTWTMain']:SetAlpha(UnitAffectingCombat('player') and OctoTWT_CONFIG.combatAlpha or OctoTWT_CONFIG.oocAlpha)
end

function OctoTWTAggroThresholdSlider_OnValueChanged()
    OctoTWT_CONFIG.aggroThreshold = _G['OctoTWTMainSettingsAggroThresholdSlider']:GetValue()
end

function OctoTWTChangeSetting_OnClick(checked, code)
    if code == 'lock' then
        checked = not OctoTWT_CONFIG[code]
        if checked then
            _G['OctoTWTMainLockButton']:SetNormalTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\icon_locked')
        else
            _G['OctoTWTMainLockButton']:SetNormalTexture('Interface\\AddOns\\OctoUI\\Modules\\Threat\\images\\icon_unlocked')
        end
    end
    OctoTWT_CONFIG[code] = checked
    if code == 'tankMode' then
        if checked then
            TWT.testBars(true)
            OctoTWT_CONFIG.fullScreenGlow = false
            OctoTWT_CONFIG.aggroSound = false
            _G['OctoTWTMainSettingsFullScreenGlow']:SetChecked(OctoTWT_CONFIG.fullScreenGlow)
            _G['OctoTWTMainSettingsFullScreenGlow']:Disable()
            _G['OctoTWTMainSettingsAggroSound']:SetChecked(OctoTWT_CONFIG.fullScreenGlow)
            _G['OctoTWTMainSettingsAggroSound']:Disable()

            _G['OctoTWTMainTankModeWindowStickTopButton']:Show()
            _G['OctoTWTMainTankModeWindowStickRightButton']:Show()
            _G['OctoTWTMainTankModeWindowStickBottomButton']:Show()
            _G['OctoTWTMainTankModeWindowStickLeftButton']:Show()

            _G['OctoTWTMainTankModeWindow']:Show()
        else
            _G['OctoTWTMainSettingsFullScreenGlow']:Enable()
            _G['OctoTWTMainSettingsAggroSound']:Enable()
            _G['OctoTWTMainTankModeWindow']:Hide()
        end
    end
    if code == 'aggroSound' and checked and not UnitAffectingCombat('player') then
        PlaySoundFile('Interface\\AddOns\\OctoUI\\Modules\\Threat\\sounds\\warn.ogg')
    end

    if code == 'fullScreenGlow' and checked and not UnitAffectingCombat('player') then
        TWT.glowFader:Show()
    end

    if code == 'percUFtop' then
        OctoTWT_CONFIG.percUFbottom = false
        _G['OctoTWTMainSettingsPercNumbersUFbottom']:SetChecked(OctoTWT_CONFIG.percUFbottom)
    end
    if code == 'percUFbottom' then
        OctoTWT_CONFIG.percUFtop = false
        _G['OctoTWTMainSettingsPercNumbersUFtop']:SetChecked(OctoTWT_CONFIG.percUFtop)
    end

    TWT.setColumnLabels()

    if OctoTWT_CONFIG.labelRow then
        _G['OctoTWTMainBarsBG']:SetPoint('TOPLEFT', 1, -40)
        _G['OctoTWTMainNameLabel']:Show()
    else
        _G['OctoTWTMainBarsBG']:SetPoint('TOPLEFT', 1, -20)
        _G['OctoTWTMainNameLabel']:Hide()
        _G['OctoTWTMainTPSLabel']:Hide()
        _G['OctoTWTMainThreatLabel']:Hide()
        _G['OctoTWTMainPercLabel']:Hide()
    end

    OctoTWTFrameHeightSlider_OnValueChanged()

    TWT.updateUI('OctoTWTChangeSetting_OnClick')
end

function TWT.setColumnLabels()
    _G['OctoTWTMain']:SetWidth(TWT.windowStartWidth - 70 - 70 - 70)

    TWT.nameLimit = 5

    if OctoTWT_CONFIG.colPerc then
        _G['OctoTWTMainPercLabel']:Show()
        _G['OctoTWTMain']:SetWidth(_G['OctoTWTMain']:GetWidth() + 70)
        TWT.nameLimit = TWT.nameLimit + 8
    else
        _G['OctoTWTMainPercLabel']:Hide()
    end

    if OctoTWT_CONFIG.colThreat then
        _G['OctoTWTMain']:SetWidth(_G['OctoTWTMain']:GetWidth() + 70)
        TWT.nameLimit = TWT.nameLimit + 8

        if OctoTWT_CONFIG.colPerc then
            _G['OctoTWTMainThreatLabel']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], -10 - 70 - 5, -21)
        else
            _G['OctoTWTMainThreatLabel']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], -10, -21)
        end

        _G['OctoTWTMainThreatLabel']:Show()
    else
        _G['OctoTWTMainThreatLabel']:Hide()
    end

    if OctoTWT_CONFIG.colTPS then
        _G['OctoTWTMain']:SetWidth(_G['OctoTWTMain']:GetWidth() + 70)
        TWT.nameLimit = TWT.nameLimit + 8

        if OctoTWT_CONFIG.colThreat then
            if OctoTWT_CONFIG.colPerc then
                _G['OctoTWTMainTPSLabel']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], -10 - 70 - 70, -21)
            else
                _G['OctoTWTMainTPSLabel']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], -10 - 70, -21)
            end
        elseif OctoTWT_CONFIG.colPerc then
            _G['OctoTWTMainTPSLabel']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], -10 - 70, -21)
        else
            _G['OctoTWTMainTPSLabel']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], 'TOPRIGHT', -10, -21)
        end

        _G['OctoTWTMainTPSLabel']:Show()
    else
        _G['OctoTWTMainTPSLabel']:Hide()
    end

    if TWT.nameLimit < 14 then
        TWT.nameLimit = 14
    end

    if _G['OctoTWTMain']:GetWidth() < 190 then
        _G['OctoTWTMain']:SetWidth(190)
    end

    TWT.windowWidth = _G['OctoTWTMain']:GetWidth()

    TWT.setMinMaxResize()
end

function TWT.setMinMaxResize()
    _G['OctoTWTMain']:SetMinResize(TWT.windowWidth, OctoTWT_CONFIG.barHeight * TWT.minBars + (OctoTWT_CONFIG.labelRow and 40 or 20))
    _G['OctoTWTMain']:SetMaxResize(TWT.windowWidth, OctoTWT_CONFIG.barHeight * TWT.maxBars + (OctoTWT_CONFIG.labelRow and 40 or 20))
end

function TWT.setBarLabels(perc, threat, tps)

    if OctoTWT_CONFIG.colPerc then
        perc:Show()
    else
        perc:Hide()
    end

    if OctoTWT_CONFIG.colThreat then

        if OctoTWT_CONFIG.colPerc then
            threat:SetPoint('RIGHT', -10 - 70 + 4, 0)
        else
            threat:SetPoint('RIGHT', -10 + 4, 0)
        end

        threat:Show()
    else
        threat:Hide()
    end

    if OctoTWT_CONFIG.colTPS then

        if OctoTWT_CONFIG.colThreat then
            if OctoTWT_CONFIG.colPerc then
                tps:SetPoint('RIGHT', -10 - 70 - 70 + 4, 0)
            else
                tps:SetPoint('RIGHT', -10 - 70 + 4, 0)
            end
        elseif OctoTWT_CONFIG.colPerc then
            tps:SetPoint('RIGHT', -10 - 70 + 4, 0)
        else
            tps:SetPoint('RIGHT', -10 + 4, 0)
        end

        tps:Show()
    else
        tps:Hide()
    end

end

function TWT.testBars(show)

    if UnitAffectingCombat('player') then
        return false
    end

    if show then
        TWT.roles['Tenk'] = 'ability_warrior_defensivestance'
        TWT.roles['Chad'] = 'spell_holy_auraoflight'
        TWT.roles[TWT.name] = 'ability_hunter_pet_turtle'
        TWT.roles['Olaf'] = 'ability_racial_bearform'
        TWT.roles['Jimmy'] = 'ability_backstab'
        TWT.roles['Miranda'] = 'spell_shadow_shadowwordpain'
        TWT.roles['Karen'] = 'spell_holy_powerinfusion'
        TWT.roles['Felix'] = 'spell_fire_sealoffire'
        TWT.roles['Tom'] = 'spell_shadow_shadowbolt'
        TWT.roles['Bill'] = 'ability_marksmanship'
        TWT.threats = {
            [TWT.AGRO] = {
                class = 'agro', threat = 1100, perc = 110, tps = '',
                history = {}, melee = true, tank = false
            },
            ['Tenk'] = {
                class = 'warrior', threat = 1000, perc = 100, tps = 100,
                history = {}, melee = true, tank = true },
            ['Chad'] = {
                class = 'paladin', threat = 990, perc = 99, tps = 99,
                history = {}, melee = true, tank = false },
            [TWT.name] = {
                class = TWT.class, threat = 750, perc = 75, tps = 75,
                history = {}, melee = false, tank = false
            },
            ['Olaf'] = {
                class = 'druid', threat = 700, perc = 70, tps = 70,
                history = {}, melee = true, tank = false
            },
            ['Jimmy'] = {
                class = 'rogue', threat = 500, perc = 50, tps = 50,
                history = {}, melee = true, tank = false
            },
            ['Miranda'] = {
                class = 'priest', threat = 450, perc = 45, tps = 45,
                history = {}, melee = false, tank = false
            },
            ['Karen'] = {
                class = 'priest', threat = 400, perc = 40, tps = 40,
                history = {}, melee = true, tank = false
            },
            ['Felix'] = {
                class = 'mage', threat = 350, perc = 35, tps = 35,
                history = {}, melee = false, tank = false
            },
            ['Tom'] = {
                class = 'warlock', threat = 250, perc = 25, tps = 25,
                history = {}, melee = false, tank = false
            },
            ['Bill'] = {
                class = 'hunter', threat = 100, perc = 10, tps = 10,
                history = {}, melee = false, tank = false
            }
        }

        TWT.tankModeThreats = {
            [1] = {
                creature = 'Infectious Ghoul',
                name = 'Bob',
                perc = 78
            },
            [2] = {
                creature = 'Venom Stalker',
                name = 'Alice',
                perc = 95
            },
            [3] = {
                creature = 'Living Monstrosity',
                name = 'Chad',
                perc = 52
            },
            [4] = {
                creature = 'Deathknight Captain',
                name = 'Olaf',
                perc = 81
            },
            [5] = {
                creature = 'Patchwerk TEST',
                name = 'Jimmy',
                perc = 12
            },
        }

        TWT.targetChanged()

        TWT.targetName = "Patchwerk TEST"

        TWT.updateUI('testBars')
    else
        TWT.combatEnd()
    end
end
function OctoTWTCloseButton_OnClick()
    _G['OctoTWTMain']:Hide()
    OctoTWTPrint('Window closed. Type |cff69ccf0/twt show|cffffffff or |cff69ccf0/twtshow|cffffffff to restore it.')
    OctoTWT_CONFIG.visible = false
end

function OctoTWTTankModeWindowCloseButton_OnClick()
    OctoTWTPrint('Tank Mode disabled. Type |cff69ccf0/twt tankmode|cffffffff to enable it or go into settings.')
    OctoTWTChangeSetting_OnClick(false, 'tankMode')
    _G['OctoTWTMainSettingsTankMode']:SetChecked(false)
end

function OctoTWTTankModeWindowChangeStick_OnClick(to)
    if to then
        OctoTWT_CONFIG.tankModeStick = to
    end
    if OctoTWT_CONFIG.tankModeStick == 'Top' then
        _G['OctoTWTMainTankModeWindow']:ClearAllPoints()
        _G['OctoTWTMainTankModeWindow']:SetPoint('BOTTOMLEFT', _G['OctoTWTMain'], 'TOPLEFT', 0, 1)
    elseif OctoTWT_CONFIG.tankModeStick == 'Right' then
        _G['OctoTWTMainTankModeWindow']:ClearAllPoints()
        _G['OctoTWTMainTankModeWindow']:SetPoint('TOPLEFT', _G['OctoTWTMain'], 'TOPRIGHT', 1, 0)
    elseif OctoTWT_CONFIG.tankModeStick == 'Bottom' then
        _G['OctoTWTMainTankModeWindow']:ClearAllPoints()
        _G['OctoTWTMainTankModeWindow']:SetPoint('TOPLEFT', _G['OctoTWTMain'], 'BOTTOMLEFT', 0, -1)
    elseif OctoTWT_CONFIG.tankModeStick == 'Left' then
        _G['OctoTWTMainTankModeWindow']:ClearAllPoints()
        _G['OctoTWTMainTankModeWindow']:SetPoint('TOPRIGHT', _G['OctoTWTMain'], 'TOPLEFT', -1, 0)
    end
end

function OctoTWTSettingsToggle_OnClick()
    if _G['OctoTWTMainSettings']:IsVisible() == 1 then
        _G['OctoTWTMainSettings']:Hide()
        TWT.testBars(false)

        _G['OctoTWTMainTankModeWindowStickTopButton']:Hide()
        _G['OctoTWTMainTankModeWindowStickRightButton']:Hide()
        _G['OctoTWTMainTankModeWindowStickBottomButton']:Hide()
        _G['OctoTWTMainTankModeWindowStickLeftButton']:Hide()

    else
        _G['OctoTWTMainSettings']:Show()

        if OctoTWT_CONFIG.tankMode then
            OctoTWTTankModeWindowChangeStick_OnClick()
            _G['OctoTWTMainTankModeWindowStickTopButton']:Show()
            _G['OctoTWTMainTankModeWindowStickRightButton']:Show()
            _G['OctoTWTMainTankModeWindowStickBottomButton']:Show()
            _G['OctoTWTMainTankModeWindowStickLeftButton']:Show()
        end

        TWT.testBars(true)
    end
end

function OctoTWTFontButton_OnClick()
    if _G['OctoTWTMainSettingsFontList']:IsVisible() then
        _G['OctoTWTMainSettingsFontList']:Hide()
    else
        _G['OctoTWTMainSettingsFontList']:Show()
    end
end

function OctoTWTFontSelect(id)
    OctoTWT_CONFIG.font = TWT.fonts[id]
    _G['OctoTWTMainSettingsFontButton']:SetText(OctoTWT_CONFIG.font)
    TWT.updateUI('OctoTWTFontSelect')
end

function OctoTWTTargetButton_OnClick(index)

    if TWT.tankModeThreats[__parsestring(index)] then
        AssistByName(TWT.tankModeThreats[__parsestring(index)].name)
        return true
    end

    OctoTWTPrint('Cannot target tankmode target.')

    return false
end

function OctoTWTExplode(str, delimiter)
    local result = {}
    local from = 1
    local delim_from, delim_to = __find(str, delimiter, from, 1, true)
    while delim_from do
        __tinsert(result, __substr(str, from, delim_from - 1))
        from = delim_to + 1
        delim_from, delim_to = __find(str, delimiter, from, true)
    end
    __tinsert(result, __substr(str, from))
    return result
end

function TWT.ohShitHereWeSortAgain(t, reverse)
    local a = {}
    for n, l in __pairs(t) do
        __tinsert(a, { ['threat'] = l.threat, ['perc'] = l.perc, ['tps'] = l.tps, ['name'] = n })
    end
    if reverse then
        __tsort(a, function(b, c)
            return b['perc'] > c['perc']
        end)
    else
        __tsort(a, function(b, c)
            return b['perc'] < c['perc']
        end)
    end

    local i = 0 -- iterator variable
    local iter = function()
        -- iterator function
        i = i + 1
        if a[i] == nil then
            return nil
        else
            return a[i]['name'], t[a[i]['name']]
        end
    end
    return iter
end

function TWT.formatNumber(n)

    if n < 0 then
        n = 0
    end

    if n < 999 then
        return TWT.round(n)
    end
    if n < 999999 then
        return TWT.round(n / 10) / 100 .. 'K' or 0
    end
    --1,000,000
    return TWT.round(n / 10000) / 100 .. 'M' or 0
end

function TWT.tableSize(t)
    local size = 0
    for _, _ in next, t do
        size = size + 1
    end
    return size
end

function TWT.targetFromName(name)
    if name == TWT.name then
        return 'target'
    end
    if TWT.channel == 'RAID' then
        for i = 0, GetNumRaidMembers() do
            if GetRaidRosterInfo(i) then
                local n = GetRaidRosterInfo(i)
                if n == name then
                    return 'raid' .. i
                end
            end
        end
    end
    if TWT.channel == 'PARTY' then
        if GetNumPartyMembers() > 0 then
            for i = 1, GetNumPartyMembers() do
                if UnitName('party' .. i) then
                    if name == UnitName('party' .. i) then
                        return 'party' .. i
                    end
                end
            end
        end
    end

    return 'target'
end

function TWT.unitNameForTitle(name, limit)
    limit = limit or TWT.nameLimit
    if __strlen(name) > limit then
        return __substr(name, 1, limit) .. ' '
    end
    return name
end

function TWT.targetRaidIcon(iconIndex)

    for i = 1, GetNumRaidMembers() do
        if TWT.targetRaidSymbolFromUnit("raid" .. i, iconIndex) then
            return true
        end
    end
    for i = 1, GetNumPartyMembers() do
        if TWT.targetRaidSymbolFromUnit("party" .. i, iconIndex) then
            return true
        end
    end
    if TWT.targetRaidSymbolFromUnit("player", iconIndex) then
        return true
    end
    return false
end

function TWT.updateTitleBarText(text)
    if not text then
        _G['OctoTWTMainTitle']:SetText(TWT.addonName .. ' |cffabd473v' .. TWT.addonVer)
        return true
    end
    _G['OctoTWTMainTitle']:SetText(text)
end


-- https://github.com/shagu/pfUI/blob/master/api/api.lua#L596
function TWT.wipe(src)
    -- notes: table.insert, table.remove will have undefined behavior
    -- when used on tables emptied this way because Lua removes nil
    -- entries from tables after an indeterminate time.
    -- Instead of table.insert(t,v) use t[table.getn(t)+1]=v as table.getn collapses nil entries.
    -- There are no issues with hash tables, t[k]=v where k is not a number behaves as expected.
    local mt = getmetatable(src) or {}
    if mt.__mode == nil or mt.__mode ~= "kv" then
        mt.__mode = "kv"
        src = setmetatable(src, mt)
    end
    for k in __pairs(src) do
        src[k] = nil
    end
    return src
end

TWT.hooks = {}
--https://github.com/shagu/pfUI/blob/master/compat/vanilla.lua#L37
function TWT.hooksecurefunc(name, func, append)
    if not _G[name] then
        return
    end

    TWT.hooks[__parsestring(func)] = {}
    TWT.hooks[__parsestring(func)]["old"] = _G[name]
    TWT.hooks[__parsestring(func)]["new"] = func

    if append then
        TWT.hooks[__parsestring(func)]["function"] = function(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
            TWT.hooks[__parsestring(func)]["old"](a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
            TWT.hooks[__parsestring(func)]["new"](a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
        end
    else
        TWT.hooks[__parsestring(func)]["function"] = function(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
            TWT.hooks[__parsestring(func)]["new"](a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
            TWT.hooks[__parsestring(func)]["old"](a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
        end
    end

    _G[name] = TWT.hooks[__parsestring(func)]["function"]
end

function TWT.pairsByKeys(t, f)
    local a = {}
    for n in __pairs(t) do
        __tinsert(a, n)
    end
    __tsort(a, function(a, b)
        return a < b
    end)
    local i = 0 -- iterator variable
    local iter = function()
        -- iterator function
        i = i + 1
        if a[i] == nil then
            return nil
        else
            return a[i], t[a[i]]
        end
    end
    return iter
end

function TWT.round(num, numDecimalPlaces)
    local mult = 10 ^ (numDecimalPlaces or 0)
    return __floor(num * mult + 0.5) / mult
end

function TWT.version(ver)
    local verEx = OctoTWTExplode(ver, '.')

    if verEx[3] then
        -- new versioning with 3 numbers
        return __parseint(verEx[1]) * 100 +
                __parseint(verEx[2]) * 10 +
                __parseint(verEx[3]) * 1
    end

    -- old versioning
    return __parseint(verEx[1]) * 10 +
            __parseint(verEx[2]) * 1

end

function TWT.sendMyVersion()
    SendAddonMessage(TWT.prefix, "TWTVersion:" .. TWT.addonVer, "PARTY")
    SendAddonMessage(TWT.prefix, "TWTVersion:" .. TWT.addonVer, "GUILD")
    SendAddonMessage(TWT.prefix, "TWTVersion:" .. TWT.addonVer, "RAID")
    SendAddonMessage(TWT.prefix, "TWTVersion:" .. TWT.addonVer, "BATTLEGROUND")
end

--Adopted init: the standalone addon ran TWT.init() on its own ADDON_LOADED;
--here it waits for the ElvUI engine so the enable toggle can live in /ec
local TM = E:NewModule("ThreatMeter")
E.ThreatMeter = TM

--Requests sent, threat packets received, and when the last one arrived. Exposed because
--the counters live on TWT, which is a local to this file, and /octoui-threat is the one
--thing that can tell "we never asked" apart from "we asked and were ignored" -- the two
--causes of an empty window that look identical on screen.
function TM:ThreatTraffic()
    return TWT.requestsSent or 0, TWT.repliesSeen or 0, TWT.lastReply
end

--The frame-name collision this guard was written for is gone. Every global this port
--owns now carries an Octo prefix -- OctoTWTMain, OctoTWTFullScreenGlow, OctoTMEF1-5,
--every OctoTWTMainSettings* frame and OctoTWT_CONFIG -- so the standalone TWThreat
--addon can be installed alongside it and neither takes the other's _G keys.
--
--The guard stays anyway, because two threat meters drawing two windows and both
--answering the same addon channel is still not what anyone wants, and a deliberate
--"one of us stands down" is better than whichever half the user notices first. It is
--now a choice rather than a workaround, which is why the message says so differently.
local function StandaloneLoaded()
    return IsAddOnLoaded("TWThreat") and true or false
end

function TM:Initialize()
    if StandaloneLoaded() then
        E:Print("Built-in threat meter stayed off: the standalone TWThreat addon is loaded and there is no point running two. Disable TWThreat at character select to use this one instead.")
        return
    end
    if not E.private.general.threatMeter then
        return
    end
    TWT.enabled = true
    TWT.init()

    --Position is OctoUI's job, not the port's: the window is movable="false" and
    --nothing in here saves or restores a position, so without a mover it sits
    --wherever init happened to leave it with no way for anyone to move it. Anchor it
    --once, then hand it over -- CreateMover reads the current point as its default,
    --so the SetPoint has to come first. /moveui moves it from here on.
    local frame = _G["OctoTWTMain"]
    if frame then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", E.UIParent, "CENTER", 0, 200)
        E:CreateMover(frame, "ThreatMeterMover", L["Threat Meter"], nil, nil, nil, "ALL,GENERAL")

        --The window has a title bar and a padlock, so it looks draggable, but the port
        --dropped upstream's drag (movable="false", no StartMoving anywhere) and both
        --were left decorative -- which reads as the window refusing to remember where
        --you put it. Rather than reinstate a second position system that would fight
        --the mover, the drag moves the mover itself: same frame /moveui moves, same
        --E.db.movers entry, one source of truth. The padlock now means something.
        frame:RegisterForDrag("LeftButton")

        frame:SetScript("OnDragStart", function()
            if OctoTWT_CONFIG and OctoTWT_CONFIG.lock then return end

            local mover = _G["ThreatMeterMover"]
            if mover then mover:StartMoving() end
        end)

        frame:SetScript("OnDragStop", function()
            local mover = _G["ThreatMeterMover"]
            if not mover then return end

            mover:StopMovingOrSizing()

            --the tail of the mover's own drag handler in Core/Movers.lua: re-anchor to
            --whichever screen edge it now sits nearest, then persist that
            local x, y, point = E:CalculateMoverPoints(mover)
            mover:ClearAllPoints()
            E:Point(mover, point, E.UIParent, point, x, y)
            E:SaveMoverPosition("ThreatMeterMover")
        end)
    end
end

local function InitializeCallback()
    TM:Initialize()
end

E:RegisterModule(TM:GetName(), InitializeCallback)
