# Porting notes

Technical background on how OctoUI was built and what had to change to run on
the 1.12.1 client. Users do not need any of this; see [README.md](README.md).

## Lineage, and why this is not upstream ElvUI

This tree is based on [ElvUI-Vanilla/ElvUI](https://github.com/ElvUI-Vanilla/ElvUI),
the 1.12.1 backport (archived September 2019), **not** on current
[tukui-org/ElvUI](https://github.com/tukui-org/ElvUI).

That distinction matters. Current ElvUI's lowest target is `## Interface: 11509`,
which is Classic Era 1.15.x: a modern engine serving 1.12 *content*. OctoWoW runs
the actual 1.12.1 client, which is Lua 5.0 with the pre-2.0 UI API. Modern ElvUI
cannot be reduced to fit it, because the gap is not features but foundations:

| Modern ElvUI depends on | Status on 1.12.1 |
| --- | --- |
| `hooksecurefunc` (1,358 call sites) | Does not exist (added 2.0) |
| Secure templates, `SetAttribute` | Restricted environment added in 2.0 |
| `RegisterStateDriver`, `RegisterUnitWatch` | Do not exist |
| `InCombatLockdown` | Does not exist |
| `C_*` namespaces (637 uses) | Do not exist |
| Ace3 | Requires Lua 5.1 |
| Handler-parameter events | 1.12 delivers `arg1`..`arg9` globals |

Anything missing is supplied by the `Compatibility\` layer, which polyfills
`select`, `string.match`, `string.gmatch`, `strsplit`, `strmatch`, `math.fmod`,
`table.maxn`, `hooksecurefunc`, `UnitAura`, `GetInstanceInfo` and others. It is
listed first in the TOC and everything below assumes it has run.

## Repository layout

The OctoWoW launcher clones one git repo per addon, names the folder after the
repo, and requires `<repo-name>.toc` at the repo root. That forces a single
addon, so the original four folders were merged:

```
OctoUI.toc            the only TOC; load order lives here
Compatibility\        was !Compatibility, must load first
Config\               was ElvUI_Config, was load-on-demand
Core\ Modules\ ...    the engine
```

`!DebugTools` was moved out of the distributed repo into the dev folder; it is
optional and every call site is guarded (`reason == "MISSING"`).

Its TOC carried `## Dependencies: !Compatibility`, an addon that stopped existing
the moment the folders were merged, so `LoadAddOn("!DebugTools")` in
`Compatibility\errorHandler.lua` failed with `DEP_MISSING` and every Lua error fell
back to the bare Blizzard `ScriptErrors` popup with no stack trace. The dependency
is dropped; DebugTools ships its own `Compatibility.lua` and never needed it.

### Consequences of the merge

- **The options GUI is no longer load-on-demand.** It now loads at startup,
  which costs about 1.6 MB of always-resident memory. `IsAddOnLoaded("ElvUI_Config")`
  checks were replaced with `E.ConfigLoaded`, set at the bottom of `Config\Core.lua`.
- **Config files must stay last in the TOC.** They resolve modules with
  `E:GetModule(...)` at file scope, which needs every `E:NewModule` to have run.

### The load-order trap, and E:BuildDeferredOptions

This is the one genuinely dangerous consequence of the merge, and it bites
silently. As a load-on-demand addon the config did not run until the first
`/ec`, long after login, so its authors could freely execute code at file scope
that assumed a fully initialised engine. Merged in, those same lines run during
addon load, and the timeline is:

1. every file in the TOC executes  ← config files run **here**
2. `ADDON_LOADED` -> `AddOn:OnInitialize` creates `E.db`, `E.private`
3. `PLAYER_LOGIN` -> `E:Initialize` creates `E.data`, loads movers, starts modules

So at config file scope `E.db` is nil, `E.data` is nil, `E.CreatedMovers` is
empty and no datatext has registered. Worse, an error at file scope aborts the
**rest of that file** while every other file still loads, so the visible symptom
is usually a later "attempt to call a nil value" for a function whose definition
never got reached, several files away from the actual cause.

Everything of this kind is now deferred into `E:BuildDeferredOptions` in
`Config\Core.lua`, called from `ToggleConfig`, which is precisely the moment the
old addon used to load. It is idempotent. What had to move:

| Was at file scope | Needed |
| --- | --- |
| `E.Options.args.profiles = ...GetOptionsTable(E.data)` | `E.data` |
| `E.Options.args.profiles.handler` and three `copyfrom` fields in `ModuleControl.lua` | the table above |
| `CP:CreateMoversConfigGroup()` | `E.CreatedMovers`, filled by `E:LoadMovers` |
| `E:RefreshCustomTextsConfigs()` | `E.db.unitframe.units` |
| `DT:PanelLayoutOptions()` | `DT.RegisteredDataTexts` and the live panels |
| `values = GetChatWindowInfo()` | passed as a function now, not a snapshot |

Values inside `get`/`set`/`disabled`/`func` closures are always fine: they run
when the widget is drawn. `min`, `max` and `step` may be functions too (they are
not in AceConfigDialog's `allIsLiteral` set), which is how nine range bounds
reading `E.db.unitframe.thinBorders` and `...detachFromFrame` were fixed, and
which stops those bounds going stale as a bonus.

**Anything added to `Config\` from here on must be checked for this**, with:

```bash
python tools/loadorder.py Config
```

Grep is not sufficient here and gave three rounds of false confidence: the
offending reads sit inside table constructors, nested arbitrarily deep, and the
distinction that matters is "is this reachable without entering a function
body", which needs the AST. The tool parses each file and reports reads of
`.db`, `.data`, `.global`, `.private`, `CreatedMovers`, `DisabledMovers` and
`RegisteredDataTexts` that are not inside a function. It must report zero.

### What was deliberately NOT renamed

Only the addon **folder** is OctoUI. The Lua engine table is still `ElvUI`
(about 300 files open with `unpack(ElvUI)`), as are the saved variables
(`ElvDB`, `ElvPrivateDB`, `ElvCharacterDB`), the frame names (`ElvUF_*`,
`ElvUI_Bar*`, `ElvUIParent`) and the AceAddon/AceLocale/AceConfig registry keys.
Profiles and mover positions key off those names; renaming them would silently
reset everyone's UI. `Init.lua` sets `OctoUI = ElvUI` as an alias.

Things that *did* follow the folder rename: every `Interface\AddOns\...` media
path (174 of them) and `GetAddOnMetadata`/`IsAddOnLoaded`/`DisableAddOn` lookups.

Saved-variable *files* are named after the folder, so an existing install needs
`WTF\...\SavedVariables\ElvUI.lua` renamed to `OctoUI.lua`.
`octoui-dev\migrate-to-octoui.ps1` does that, with a backup, and refuses to run
while the game is open.

## The recurring bug shape

Nearly every runtime error in this port has been one thing: **the code assumes a
Blizzard FrameXML layout this client does not have.** Three variants, all seen
live:

1. name is nil, so `_G["Frame"]:Method()` gives "attempt to index a nil value"
2. name exists but is a different type, giving "attempt to call method 'SetTexture'"
3. name is a **table** iterated as `for _, v in SomeTable do`, giving "attempt to
   call a nil value", because Lua 5.0's table-iteration form calls the value as
   an iterator

The damage is disproportionate: an error aborts the rest of the enclosing
`LoadSkin()`, so every frame *after* the missing one is left unskinned too.
Twelve `S:Handle*` helpers and seven `E:` toolkit helpers now start with
`if not x then return end`, matching the idiom the backport authors were already
applying case by case.

**A new file needs a client restart, not `/reload`.** The 1.12 client indexes
`Interface\AddOns` at startup. `/reload` re-executes the files it already knows, so
edits to an existing file apply immediately — but a file created while the game is
running is not in that index, and the `<Script>` line referencing it is skipped in
silence. No error is raised, because from the client's side there is nothing to load.
The symptom is a brand-new module that behaves exactly as if its file were empty
while every edit to an existing file works, which reads like a code bug and is not
one. Add a file, restart the game.

Do not guess which globals are missing. Use the in-game probe:
`/octoui-missing` then `/reload`, which force-loads the twelve load-on-demand
Blizzard addons, checks 393 referenced globals and writes
`ElvDB.MissingGlobals` / `SeenGlobals` / `ClobberedGlobals`.

Turtle-patched FrameXML is the other half of this: its templates carry children
upstream ElvUI never knew about. `StaticPopupTemplate` here has a money-input
frame that starts visible and sat on top of the Accept/Cancel buttons, so the
show path now hides template children it did not ask for.

## Notable fixes

- **Mover positions.** `E:Point` received offsets as strings, because mover
  positions round-trip through `GetPoint` -> `format("%s,%s,%s,%d,%d")` ->
  `string.split`. 1.12's `SetPoint` accepts a frame *name* string as the anchor
  but not a numeric string as an offset. `E:Point` now coerces numeric strings
  back to numbers before the scale pass (safe, since `E:Scale` is idempotent).
- **`GetPoint` in `Core\Movers.lua`** guarded only `anchor`. A frame with no
  point returns five nils, which reached `E:Round` and died on the arithmetic.
- **`CH:UpdateChatKeywords`** re-split its string every iteration through the
  `select` polyfill and let a non-string into the table; since `CheckKeyword`
  runs `strlower` on every key for every word of every message, one bad key
  became unbounded error spam. Now iterates `gmatch(keywords, "[^,]+")`.
- **`GetMaxPlayersByType`** returned nil for known zones whose instance type was
  neither `pvp` nor `raid`, and `GetInstanceInfo` feeds that to `format("%d")`.
  Every OctoWoW-added raid hit this.
- **Dropped escape sequences.** `"Interface\Buttons\UI-PlusButton-Hilight"` with
  single backslashes: Lua 5.0 does not pass an unknown escape through, it drops
  the backslash, so the path became `InterfaceButtonsUI-PlusButton-Hilight` and
  the texture silently never loaded. One instance existed, in AceGUI's
  TreeGroup; a sweep confirmed it was the only one.
- **`E:StaticPopup_OnEvent`** used the modern `self` handler signature. 1.12
  passes the frame in the global `this`, so every popup errored on UI-scale
  change (four popups, hence "Count: 4").
- **Empty stance bar.** `AdjustMaxStanceButtons` hid the individual buttons when
  `GetNumShapeshiftForms()` was 0 but never set `bar.LastButton`, so the sizing
  code fell back to the full `NUM_SHAPESHIFT_SLOTS` and left an empty backdrop
  in the corner for mages, warlocks, hunters and shamans. The bar now hides.
- **Pet bar** shipped `buttonsPerRow = 1`, standing it on end as a vertical
  strip; and the install wizard positioned `ElvUF_PetMover` (the pet
  *unitframe*) while never placing `ElvBar_Pet` (the pet *action bar*) or
  `ShiftAB` (the stance bar), so both kept corner defaults.
- **A clobbered Blizzard global took the whole options table down.** AtlasLoot ships
  an `AceLocale-2.2` revision whose local list at line 25 is missing `NAME`, so its
  `NAME = self.NAME` writes `_G.NAME = {}` — and AtlasLoot loads before OctoUI. Every
  config file reading the bare global got a table, and AceConfig's validator rejects
  the entire tree with "expected a string or funcref, got 'table:'", so `/ec` opened
  to nothing. Bare CAPS globals now go through `E:SafeString(NAME, L["Name"])`, which
  falls back to our own locale string when another addon has left one holding
  something that is not a string. Third variant of the recurring bug shape above, and
  the one `/octoui-missing`'s `ClobberedGlobals` output exists to catch.
- **The EditBox backdrop, part two.** Hosting the backdrop on the grandparent when
  `CreateFrame` refuses the EditBox as a parent only moved the failure: this client
  will not take that object as a `SetPoint` **anchor** either, so `E:SetOutside`
  died in C with "Couldn't find region named '(null)'" and killed the rest of the
  skin function. `TryPoint` now `pcall`s the anchor and retries with the anchor's
  *name*, which 1.12 does resolve, and `E:Point` uses it too — `Bags.lua` anchors
  the bag search backdrop to the EditBox directly, so the raw `SetPoint` there hit
  the identical wall.

  Fixing that surfaced the bug behind it, because execution now got further. **On
  this client a frame that never received a backdrop answers `frame.backdrop` with
  an inherited function**, not nil. `Skins.lua` knew this and type-checked at one
  call site; everywhere else `if f.backdrop then` passes and the next index dies
  ("attempt to index local 'obj' (a function value)"). So: `E:CreateBackdrop` never
  bails silently any more — it parks an unanchorable backdrop on the host and hides
  it, so the field is always a real frame — and when it genuinely cannot build one
  it writes `f.backdrop = false`, which shadows the inherited function and is
  correctly falsy. The toolkit helpers gained an `IsWidget` guard in place of
  `if not x then return end`, since a truthy non-widget was the whole problem.

  These helpers now swallow `SetPoint` failures instead of letting one abort a skin
  function, so they report the real `pcall` error to chat, once per anchor. Without
  that a genuine bad-argument bug would simply vanish.

  The `assert(anchor)` `SetOutside`/`SetInside` opened with is gone for the same
  reason the other toolkit helpers lost theirs.
- **Nameplate auras never appeared.** The upstream element fed an aura cache from
  `COMBAT_LOG_EVENT_UNFILTERED`, which does not exist before 2.4, and the handler
  that would have filled it had its own argument unpack commented out; nothing was
  registered anyway, so `auraList` stayed empty and every icon stayed hidden. It
  now reads `UnitBuff`/`UnitDebuff` straight off the unit, addressed by the
  SuperWoW GUID on the plate's parent frame (`parent:GetName(1)`), falling back to
  `target`/`mouseover` when SuperWoW is absent. The old fallback — matching a plate
  by mob *name* — is what made same-name mobs mirror each other's debuffs; it is
  gone along with `SearchForFrame` and friends. There is no event for this, so a
  0.2s repeating timer polls visible plates. `Auras_SizeChanged` was registered as
  an `OnSizeChanged` script, which gets no `self` on 1.12, so icon sizing now
  happens in `UpdateAuraIcons` instead.
- **Nameplate DoT timers.** `UnitBuff`/`UnitDebuff` return texture and stack count
  only — no duration, and SuperWoW 2.2 does not extend them — so debuff timers are
  reconstructed the way every vanilla UI does it, by `Modules\NamePlates\LibDebuff.lua`:
  the combat log says when a debuff landed, `Settings\DebuffDurations\<locale>.lua`
  says how long that spell lasts. Durations that are not fixed at cast time (combo
  points, Booming Voice, Improved SW:P, Permafrost, Improved Gouge) are adjusted in
  `GetDuration`. A cast is held as *pending* and only becomes a timer once the "is
  afflicted by" message confirms it landed, so a resisted DoT never starts a
  countdown.

  The duration data is extracted from ShaguPlates by Eric Mauser (Shagu) under the
  MIT licence — 933 spells for enUS, seven locales, with the notice at the head of
  each generated file. Only the running client's locale builds its table; the other
  six parse and return. Buffs still get no timer: nothing here reports one.

  Durations are stored per unit *name and level*, because the 1.12 combat log only
  ever gives names. Two mobs sharing a name and level therefore share a countdown —
  the plate itself is still matched by GUID, so the icons are right even when the
  number on them is not. That is the one part GUIDs cannot fix.

  **OctoWoW scales DoTs with casting speed and vanilla does not.** Haste in 1.12
  only shortens cast time; ticks are fixed. This server adds talents (the warlock's
  `Rapid Deterioration` is the confirmed one) reading "casting speed increase effects
  increase the tick speed of your damage over time and channeled spells with 100%
  efficiency, reducing their duration", so `duration = base / (1 + castingSpeed)`.
  `Modules\NamePlates\LibHaste.lua` reconstructs casting speed the only way available
  — there is no haste API at all on this client — by scanning the tooltips of
  equipped gear, active buffs and taken talents for the client's own casting-speed
  wordings. It also decides *whether* to scale at all by looking for a talent whose
  tooltip mentions tick speed, rather than keeping a per-class spell list, so any
  class with an equivalent talent is handled without one. Applied to our own casts
  only: another caster's haste is unknowable.

  **BetterCharacterStats computes the same number** for its character sheet and is
  the addon to disable if you would rather only one thing scanned your gear. It is
  not a dependency and none of its code is used — it ships with no licence at all,
  so nothing of it could be reused regardless. The patterns matched are the game's
  own tooltip strings.

  Names are needed to key the store, so debuff names are always resolved now. They
  still come from the per-slot texture cache, so a tooltip scan only happens when the
  icon in a slot actually changes rather than on every plate five times a second.
- **Game menu buttons** were skinned from a hardcoded list of Blizzard names, so
  OctoWoW's own additions (Donation Rewards) kept the gold Blizzard look. The
  skin now sweeps `GameMenuFrame`'s actual children, guarded on `.template` so
  nothing is hooked twice.

## Defaults changed from upstream

- `pixelPerfect` **off**. At high resolutions its 1px borders and zero spacing
  make buttons look bare.
- All action bars default to **Backdrop on**.
- Pet bar horizontal, pet and stance bars placed above the main bars.

## Removed as unusable on this client

`Totem Bar` config entries and a dead 50-line block driving a `Totems` module
that does not exist here; `Arena Frames` module control and profile default;
nameplate `role`/`instanceType`/`instanceDifficulty` filters (roles arrived with
LFG in 3.3, `IsInInstance()` never returns `arena` here, and the polyfilled
`GetInstanceInfo` hardcodes difficulty to 1); dual-spec tutorial text;
`AceGUIContainer-BlizOptionsGroup.lua`, referenced by no loader; nameplate aura
`Personal Auras` and `Maximum Duration` filters, since `UnitBuff`/`UnitDebuff`
report neither the caster nor the duration of another unit's auras here. (Debuff
durations came back later via `LibDebuff` and a bundled duration table, but they are
reconstructed rather than reported, so those two filters stay gone.)

An obfuscated easter egg in TWThreat, which assembled a player name with
`string.char` and flashed "STOP DPS <name>" at anyone with that name above 95%
threat, was removed. The upstream version-nag was also dropped: this fork tracks
OctoUI, not CosminPOP's Turtle releases, so version broadcasts from standalone
TWThreat users are consumed silently.

## Verified as working, left alone

- **Custom races** (High Elf, Goblin). Race handling is entirely dynamic via
  `UnitRace`; the only hardcoded race is `NightElf` for base miss chance in
  `DataTexts/Avoidance.lua`, and unknown races fall through to the default.
- **Custom zones.** All zone text comes from live APIs.
- **`GameTimeFrame`** exists in 1.12, so the minimap calendar icon code is live.
- **Blizzard skins** all map to frames that exist in 1.12.

## Still needs live-client data

- `customZoneInfo` in `Compatibility\api\wowAPI.lua` is empty. Run `/ozd` inside
  each OctoWoW dungeon, raid and battleground and paste the emitted lines in.
  Until then unlisted raids report the 40-player fallback.
- **Jewelcrafting bags.** `B.BagIndice` maps bag families resolved through the
  `ItemFamilyDB` polyfill, a static item-ID table. A JC bag needs a new family
  value plus its item IDs.
- **Transmog.** No addon-facing API is known for OctoWoW's implementation.
- **Octo Shop skin.** The shop is client FrameXML, not an addon; its frame names
  need probing in game before a skin can be written.

## SuperWoW and VanillaFixes

**VanillaFixes** is a launcher and DLL loader (DXVK, client fixes). It does not
change the Lua API.

**SuperWoW** does extend the client, and has one setting worth knowing about:
*GUID in combat log/events*. With it on, combat log arguments carry GUIDs
instead of unit names, so any code comparing those args to a name silently stops
matching. If combat-driven features misbehave, check that first.

OctoUI uses one SuperWoW feature directly: a nameplate's parent frame answers
`GetName(1)` with the unit's GUID, and every `Unit*` function accepts that GUID
as a unit token. That is what lets nameplate auras read a mob that is neither the
target nor the mouseover, and what keeps two mobs of the same name apart. Without
SuperWoW loaded (`SUPERWOW_VERSION` is unset) nameplate auras degrade to the
target and mouseover plates only; nothing else changes.

Note that `Compatibility` installs its polyfills **unconditionally** rather than
testing whether the client already provides them. That is harmless today, but
would matter if a future client mod started providing better native versions.

## Verification

`octoui-dev\tools\` holds four checkers, all calibrated against pfUI as a
known-good 1.12 baseline:

```bash
python tools/luaparse.py .    # real Lua grammar: unbalanced end, stray brace
python tools/lua50check.py .  # constructs Lua 5.0 cannot run
python tools/checkrefs.py .   # dangling and orphaned loader references
python tools/deadblocks.py . 6
```

`luaparse.py` needs `pip install luaparser`. Current state: **0 syntax findings,
0 parse failures, 0 missing references, 0 orphans** across 305 Lua files.
