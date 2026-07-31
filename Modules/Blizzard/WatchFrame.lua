local E, L, V, P, G = unpack(ElvUI); --Import: Engine, Locales, PrivateDB, ProfileDB, GlobalDB
local B = E:GetModule("Blizzard");

--Cache global variables
--Lua functions
local min = math.min
--WoW API / Variables
local hooksecurefunc = hooksecurefunc

local WatchFrameHolder = CreateFrame("Frame", "WatchFrameHolder", E.UIParent)
WatchFrameHolder:SetWidth(150)
WatchFrameHolder:SetHeight(22)
WatchFrameHolder:SetPoint("TOPRIGHT", E.UIParent, "TOPRIGHT", -135, -300)

function B:SetWatchFrameHeight()
	local configured = E.db.general.watchFrameHeight
	local top = QuestWatchFrame:GetTop()

	--GetTop is nil for a frame that has not been laid out yet, and for a hidden one --
	--and QuestWatchFrame is hidden whenever nothing is being tracked. The `or 0` this
	--used to carry turned that into a height of zero, so the tracker came back from its
	--first tracked quest with no height at all and never appeared again. Nothing to
	--clamp against in that case, so take the configured height as-is.
	if not top then
		QuestWatchFrame:SetHeight(configured)
		return
	end

	--`top` is measured from the bottom of the screen, so it is exactly how tall the
	--frame can be before it runs off the bottom. The original spelled this out as
	--screenHeight - (screenHeight - top), which is the same number by a longer road.
	QuestWatchFrame:SetHeight(min(top, configured))
end

function B:MoveWatchFrame()
	E:CreateMover(WatchFrameHolder, "WatchFrameMover", L["Watch Frame"])
	WatchFrameHolder:SetAllPoints(WatchFrameMover)

	QuestWatchFrame:ClearAllPoints()
	QuestWatchFrame:SetPoint("TOP", WatchFrameHolder, "TOP")
	B:SetWatchFrameHeight()
	QuestWatchFrame:SetClampedToScreen(false)

	hooksecurefunc(QuestWatchFrame, "SetPoint", function(_, _, parent)
		if parent ~= WatchFrameHolder then
			QuestWatchFrame:ClearAllPoints()
			QuestWatchFrame:SetPoint("TOP", WatchFrameHolder, "TOP")
		end
	end)
end