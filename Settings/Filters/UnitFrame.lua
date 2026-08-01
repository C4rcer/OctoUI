--[[
	Unit frame aura filters.

	This file was empty, and several things quietly did nothing as a result:

	  * oUF_RaidDebuffs had no list to match against, so its whole priority half was dead
	    and only a dispellable debuff could ever be selected. UF:UpdateAllHeaders had the
	    RegisterDebuffs call commented out for that reason.
	  * Shift + Right-Click on an aura indexes aurafilters.Blacklist.spells and raised.
	  * The default nameplate profiles name Blacklist, CCDebuffs and RaidDebuffs in their
	    aura priority strings, and every one of them resolved to nil.
	  * E.DEFAULT_FILTER is built from this table, so E:DBConversions had nothing to do.

	Shape, as read by Modules/NamePlates/Elements/Auras.lua (PassesFilter) and by
	Libraries/oUF_Plugins/oUF_RaidDebuffs (RegisterDebuffs):

		[name] = {type = "Whitelist"|"Blacklist", spells = {[spellName] = {enable, priority, stackThreshold}}}

	Keys are spell NAMES, not ids -- oUF_RaidDebuffs looks a debuff up by the name
	LibDebuff reconstructs from a tooltip scan. There is no id to match on, because this
	client's UnitAura returns texture, count and dispel type and nothing else.

	Priority is added to oUF_RaidDebuffs' base of 10, and a dispellable Magic debuff scores
	14, so anything meant to outrank "something you could dispel" needs to be above 4.

	A name that does not match anything is inert -- it never matches, raises nothing, and
	says nothing. So a typo here fails exactly the way a missing entry does. These are
	vanilla names and are UNVERIFIED against OctoWoW; anything that turns out not to fire
	is one line.
]]
local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB

local filters = G["unitframe"]["aurafilters"]

--Every entry is the same three fields and there are a couple of hundred of them.
local function debuff(priority, stackThreshold)
	return {["enable"] = true, ["priority"] = priority, ["stackThreshold"] = stackThreshold or 0}
end

--Populated by the user: Shift + Right-Click an aura on a unit frame adds it here.
filters["Blacklist"] = {
	["type"] = "Blacklist",
	["spells"] = {}
}

filters["Whitelist"] = {
	["type"] = "Whitelist",
	["spells"] = {}
}

--Used outside dungeons and raids by the RaidDebuff Indicator, and available to the
--nameplate aura filters by name.
filters["CCDebuffs"] = {
	["type"] = "Whitelist",
	["spells"] = {
		--Mage
		["Polymorph"] = debuff(80),
		["Frost Nova"] = debuff(50),
		["Counterspell - Silenced"] = debuff(60),
		--Druid
		["Hibernate"] = debuff(80),
		["Entangling Roots"] = debuff(60),
		["Bash"] = debuff(60),
		["Pounce"] = debuff(60),
		["Maim"] = debuff(60),
		--Rogue
		["Sap"] = debuff(80),
		["Blind"] = debuff(80),
		["Gouge"] = debuff(60),
		["Cheap Shot"] = debuff(60),
		["Kidney Shot"] = debuff(60),
		--Hunter
		["Freezing Trap Effect"] = debuff(80),
		["Wyvern Sting"] = debuff(80),
		["Scatter Shot"] = debuff(60),
		["Intimidation"] = debuff(60),
		--Warlock
		["Fear"] = debuff(80),
		["Howl of Terror"] = debuff(80),
		["Death Coil"] = debuff(70),
		["Seduction"] = debuff(80),
		["Banish"] = debuff(80),
		["Enslave Demon"] = debuff(80),
		--Priest
		["Psychic Scream"] = debuff(80),
		["Shackle Undead"] = debuff(80),
		["Mind Control"] = debuff(90),
		["Silence"] = debuff(60),
		--Paladin
		["Hammer of Justice"] = debuff(60),
		["Repentance"] = debuff(80),
		["Turn Undead"] = debuff(70),
		--Warrior
		["Intimidating Shout"] = debuff(80),
		["Charge Stun"] = debuff(50),
		["Concussion Blow"] = debuff(60),
		--Racial
		["War Stomp"] = debuff(50)
	}
}

--Used inside dungeons and raids by the RaidDebuff Indicator. Grouped by where they come
--from so an instance can be checked off as a whole once someone has run it.
filters["RaidDebuffs"] = {
	["type"] = "Whitelist",
	["spells"] = {
		--Generic, seen across several instances
		["Mortal Strike"] = debuff(40),
		["Mortal Wound"] = debuff(40),
		["Curse of Tongues"] = debuff(30),
		["Curse of Weakness"] = debuff(20),
		["Impale"] = debuff(40),
		["Hex"] = debuff(60),

		--Zul'Gurub
		["Sonic Burst"] = debuff(40),
		["Mind Flay"] = debuff(40),
		["Cause Insanity"] = debuff(70),
		["Corrupted Blood"] = debuff(70),
		["Poison Volley"] = debuff(40),
		["Enveloping Webs"] = debuff(50),
		["Blinding Poison"] = debuff(50),
		["Delusions of Jin'do"] = debuff(70),
		["Shadow Shock"] = debuff(30),
		["Venom Spit"] = debuff(40),
		["Frost Breath"] = debuff(40),

		--Molten Core
		["Elemental Fire"] = debuff(60),
		["Living Bomb"] = debuff(80),
		["Ignite Mana"] = debuff(60),
		["Magma Shackles"] = debuff(40),
		["Magma Splash"] = debuff(30),
		["Antimagic Pulse"] = debuff(30),
		["Shazzrah's Curse"] = debuff(50),
		["Gehennas' Curse"] = debuff(50),
		["Lucifron's Curse"] = debuff(50),
		["Impending Doom"] = debuff(60),
		["Panic"] = debuff(40),

		--Blackwing Lair
		["Burning Adrenaline"] = debuff(90),
		["Shadow Flame"] = debuff(70),
		["Shadow of Ebonroc"] = debuff(60),
		["Veil of Shadow"] = debuff(60),
		["Brood Affliction: Blue"] = debuff(60),
		["Brood Affliction: Black"] = debuff(60),
		["Brood Affliction: Red"] = debuff(60),
		["Brood Affliction: Bronze"] = debuff(60),
		["Brood Affliction: Green"] = debuff(60),
		["Corrosive Acid"] = debuff(60),
		["Ignite Flesh"] = debuff(60),
		["Frost Burn"] = debuff(60),
		["Time Lapse"] = debuff(50),
		["Bellowing Roar"] = debuff(40),
		["Wing Buffet"] = debuff(20),

		--Ruins of Ahn'Qiraj
		["Creeping Plague"] = debuff(60),
		["Dampen Magic"] = debuff(40),
		["Paralyze"] = debuff(70),
		["Thundercrash"] = debuff(40),
		["Trample"] = debuff(30),

		--Temple of Ahn'Qiraj
		["True Fulfillment"] = debuff(90),
		["Toxic Volley"] = debuff(50),
		["Poison Cloud"] = debuff(60),
		["Noxious Poison"] = debuff(60),
		["Acid Spit"] = debuff(50),
		["Toxin"] = debuff(60),
		["Poison Shock"] = debuff(50),
		["Digestive Acid"] = debuff(70),
		["Sand Blast"] = debuff(50),

		--Naxxramas
		["Locust Swarm"] = debuff(60),
		["Rain of Fire"] = debuff(50),
		["Poison Bolt Volley"] = debuff(60),
		["Web Wrap"] = debuff(80),
		["Web Spray"] = debuff(60),
		["Necrotic Poison"] = debuff(70),
		["Curse of the Plaguebringer"] = debuff(80),
		["Cripple"] = debuff(60),
		["Decrepit Fever"] = debuff(70),
		["Corrupted Mind"] = debuff(60),
		["Inevitable Doom"] = debuff(70),
		["Necrotic Aura"] = debuff(50),
		["Mutating Injection"] = debuff(90),
		["Decimate"] = debuff(50),
		["Polarity Shift"] = debuff(60),
		["Positive Charge"] = debuff(60),
		["Negative Charge"] = debuff(60),
		["Unbalancing Strike"] = debuff(60),
		["Disrupting Shout"] = debuff(40),
		["Mark of Blaumeux"] = debuff(70),
		["Mark of Korth'azz"] = debuff(70),
		["Mark of Mograine"] = debuff(70),
		["Mark of Zeliek"] = debuff(70),
		["Life Drain"] = debuff(70),
		["Chill"] = debuff(50),
		["Frost Blast"] = debuff(90),
		["Chains of Kel'Thuzad"] = debuff(90),
		["Mana Detonation"] = debuff(70),
		["Shadow Fissure"] = debuff(70)
	}
}
