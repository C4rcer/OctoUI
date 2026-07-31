local E, L, V, P, G = unpack(ElvUI)
local mod = E:GetModule("NamePlates")

--[[
	Casting speed, for the nameplate DoT timers.

	OctoWoW scales damage over time with casting speed and vanilla does not: haste in
	1.12 only shortens cast time, and ticks are fixed. This server's talents (the
	warlock's Rapid Deterioration is the confirmed one) read "casting speed increase
	effects increase the tick speed of your damage over time and channeled spells with
	100% efficiency, reducing their duration", which makes

		duration = base / (1 + castingSpeed)

	The number itself comes from Core\LibStats.lua, which scans gear, buffs and talents
	once for every stat rather than once per caller. This file is only the DoT-facing
	view of it, kept separate because that arithmetic is a nameplate concern and the
	scanner is not.
]]

local lib = {}
mod.LibHaste = lib

--Fraction, so 0.06 for 6%. LibStats reports percentages as whole numbers.
--Both stats are summed here because both raise casting speed: "haste" is the general
--kind that speeds attacks and casting alike, "castingSpeed" the spell-only kind. They
--are kept apart in LibStats because a character sheet must not conflate them, but for
--how fast a DoT ticks only the total matters.
function lib:GetCastingSpeed()
	return (E.Stats:Get("haste") + E.Stats:Get("castingSpeed")) / 100
end

--Whether this character has a talent making casting speed shorten DoTs. Without one,
--casting speed does nothing to duration and the base values stand.
function lib:ScalesDots()
	return E.Stats:ScalesDots()
end

--Base duration adjusted for the tick speed increase, at the 100% efficiency the
--talent describes. Returns the duration untouched when nothing applies.
function lib:AdjustDuration(duration)
	if not duration or duration <= 0 then return duration end
	if not lib:ScalesDots() then return duration end

	local speed = lib:GetCastingSpeed()
	if speed <= 0 then return duration end

	return duration / (1 + speed)
end
