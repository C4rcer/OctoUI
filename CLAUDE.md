# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

# OctoUI

A full port of ElvUI to World of Warcraft **1.12 (Vanilla)**, running on a Turtle/OctoWoW
server. It is its own addon with its own name — call it OctoUI, not ElvUI. Upstream credit
lives in `README.md`, not in prose or comments.

The engine table is still called `ElvUI` internally (see `Init.lua` for why). `OctoUI` is
aliased to the same table, so `local E = unpack(ElvUI)` and `unpack(OctoUI)` are equivalent.

## The live addon folder is a COPY

The game loads `C:\Users\Carcer\Documents\WoW\Interface\Addons\OctoUI`. It is a plain copy,
not a symlink. **Editing this repo changes nothing in game.** Copy changed files across and
verify before asking for a test:

```bash
diff -rq --exclude=.git --exclude=.claude --exclude=.github --exclude=.gitattributes --exclude=.gitignore . "C:/Users/Carcer/Documents/WoW/Interface/Addons/OctoUI"
```

Two sibling addons follow the same pattern and are edited from their own repos:

| Repo | Live folder | What it is |
| --- | --- | --- |
| `Documents/GitHub/Atlas-OctoUI` | `Interface/Addons/Atlas-OctoUI` | Atlas/CFM fork, styles itself via `CFMAtlas/AtlasOctoStyle.lua` |
| `Documents/GitHub/octoui-dev/OctoProbe` | `Interface/Addons/OctoProbe` | Dev-only probe, `/oprobe`. Never ship inside OctoUI |

`Documents/GitHub/octoui-dev/HANDOFF.md` is the long-form project log — open items, measured
client facts, and dead ends. Read it before assuming anything about this client.

## Never commit unprompted

No `git commit`, `git push`, or remote changes unless asked in that message. The live repo
was deleted once over this.

## Architecture

### There is no build, no test runner, and no package manager

`.toc` and `.xml` files are the build system: the client reads them top to bottom and
executes the Lua. Nothing is compiled, bundled or installed. So there is no `npm test`
equivalent to reach for, and the checks that do exist are:

| What | Command |
| --- | --- |
| Static analysis (the only one) | `lua-language-server --check <DIRECTORY>` — see **Use the LSP** below |
| Repo vs. live addon folder | the `diff -rq` line above |
| Recipe DB regeneration | `python octoui-dev/tools/recipe-pipeline/build.py` then `validate.py` |
| Everything else | the game — see **In-game testing** |

`--check` also runs clean over the whole repo (263 files) in a few seconds, which is the
cheapest way to be sure an edit did not break a *different* file.

### Load order is the TOC, and it is strict

`OctoUI.toc` fixes the order and each stage assumes the previous one ran:

`Compatibility` (polyfills `select`, `string.match`, `strsplit`, `hooksecurefunc`) →
`Developer` → `Libraries` → `Locales` → `Media` → `Init.lua` (creates the engine table) →
`Settings` (the defaults tables) → `Core` (the engine's own methods) → `Layout` →
`Modules` → `Config` (the options GUI, **last**, because its files call `E:GetModule` at
file scope).

Every file after `Init.lua` opens with the same line, and the five upvalues are the whole
public surface:

```lua
local E, L, V, P, G = unpack(ElvUI) --Engine, Locales, PrivateDB, ProfileDB, GlobalDB
```

**A new `.lua` file does not load until `WoW.exe` fully exits.** `/reload` re-reads existing
files but does not pick up a file newly added to an XML, and it fails silently — the symptom
is a missing feature, not an error. Prefer appending to an existing file, and say which is
needed when asking for a test.

### A module, end to end

`Modules/<Name>/` holds the code, a `Load_<Name>.xml` lists its files in order, and
`Modules/Load_Modules.xml` includes that. The module itself:

```lua
local M = E:NewModule("Auction", "AceEvent-3.0")  -- first file only
local M = E:GetModule("Auction")                  -- every later file in the folder
...
function M:Initialize() ... end
E:RegisterModule(M:GetName(), function() M:Initialize() end)
```

`Initialize` runs in registration order, which is XML order. **Failures inside it are caught
and stashed in `E.ModuleLoadErrors` rather than raised**, so a module that errors on load is
indistinguishable from one that is switched off unless you go and look — `/oprobe` reports
them. `E:GetModule(name, true)` is the silent form and is what every slash command uses, so a
missing module prints a line instead of erroring.

Multi-file modules in this codebase register their own pieces into a table rather than having
one file enumerate the others — `A.tabBuilders` in `Modules/Auction/`, the column tables in
`Modules/Recipes/`. Adding a feature is then adding a file, not editing a dispatcher.

### The four settings layers

| Upvalue | Defaults live in | Read at runtime as | Scope | Saved variable |
| --- | --- | --- | --- | --- |
| `P` | `Settings/Profile.lua` | `E.db` | per profile | `ElvDB` |
| `V` | `Settings/Private.lua` | `E.private` | per character | `ElvPrivateDB` |
| `G` | `Settings/Global.lua` | `E.global` | per account | `ElvDB.global` |
| — | — | `E.charSettings` | per character | `ElvCharacterDB` |

A default added to `P`/`V`/`G` is merged into existing saved data on login, so new keys
appear for players who already have a profile. **Removing one does not delete the saved
value** — it only stops it being defaulted.

Anything per-account that describes the *world* rather than the player belongs in `G`: the
class cache, the ninja-looter blacklist, and the auction price database are all there because
they are the same on every alt.

### Building UI

`Core/toolkit.lua` is the vocabulary — `E:Size`, `E:Point`, `E:Width`/`E:Height`,
`E:SetTemplate`, `E:FontTemplate`, `E:CreateCloseButton`, `E:StripTextures` — and
`E.media` (`normTex`, `rgbvaluecolor`) is where colour comes from. Frames built with these
match the rest of the UI automatically; frames built with raw `SetBackdrop` do not, and stop
matching the moment someone changes their value colour.

`Modules/Skins/` restyles Blizzard and third-party frames. `Core/Movers.lua` provides
`E:CreateMover` — read the trap about it below before changing any anchor.

## Writing Lua for this client

1.12 is **Lua 5.0**. No `#` operator, no `string.gmatch` (`gfind`), no `select` or `strsplit`
except where `Compatibility/` polyfills them. Event handlers read the globals `event`,
`arg1..arg9` and `this` — they take no arguments.

### A closure made in a loop cannot rely on the loop variable

Measured here, not theorised: a handler created inside `for index, column in ipairs(columns)`
read `column` as **nil** when it later ran, throwing `attempt to index a nil value`. The
listing's column headers had this from the day they were written and it only ever showed when
clicking a header that was not already the sort column — the other branch never touched the
captured value, so sorting looked like it worked.

Capture nothing you can look up. `this` is always the widget the handler fired on, so store an
index on the widget and read the real thing back out of a table:

```lua
button.index = index
button:SetScript("OnClick", function()
    local col = listing.columns[this.index]   -- not the captured `column`
end)
```

The language server cannot see this: the closure is valid Lua and the upvalue exists.

### Use the LSP

**Check every edited file through the language server before deploying it.** Use LSP
diagnostics rather than reading the file back and eyeballing it, and use LSP navigation —
definitions, references, symbols — instead of `grep` when the question is "where is this
defined" or "what calls this". Grep is for text; the LSP is for code, and it does not
mistake a name in a comment or a string for a real reference.

This matters more here than in a typical project. Lua has no compile step, and this client
silently swallows load errors: a file that fails to parse simply does not load, and the
symptom shows up as a missing feature somewhere else entirely. Every regression of that shape
this project has had would have been caught by a diagnostic before it ever reached the game.

`lua-language-server` is installed (winget, `LuaLS.lua-language-server`). When no LSP tools are
exposed to the session, run it in check mode instead — same diagnostics, from the shell:

```bash
"$LOCALAPPDATA/Microsoft/WinGet/Packages/LuaLS.lua-language-server_Microsoft.Winget.Source_8wekyb3d8bbwe/bin/lua-language-server.exe" --check "$(pwd -W)/Modules/Threat" --checklevel=Error --logpath="$TEMP/lls"
```

**`--check` takes a DIRECTORY.** Handed a single file path it prints
`Diagnosis completed, no problems found` and exits clean **whatever is in the file** — verified
2026-08-08 against a file with an unbalanced `end`, which it passed. Point it at the folder
holding the edited file, or at the repo root. Treating that message as a pass on a file path is
worse than not running it at all.

`.luarc.json` configures it: Lua 5.1 runtime (the lowest it supports; 5.0-only rules like the
absence of `#` are therefore *not* caught), `Libraries/` ignored, and `undefined-global` off
because there is no WoW API definition set — add one and that check becomes worth enabling.

Last-resort fallback, catching an unbalanced `end` and nothing else:

```bash
python "$SCRATCH/luabal.py" Modules/Path/File.lua
```

Polyfills live in `Compatibility/api/`. Note `GetItemFamily` returns **nil** for any item id
above `LAST_ITEM_ID` (24283) — every item this server added.

## Verify against the client, never reason about it

The expensive mistakes have all been the same shape: assuming an API this client does not
have, or a global string that says something else. `RegisterEvent` accepts *any* string
without complaint, so "did it register" tests nothing.

`/oprobe` answers these directly — `api`, `stats`, `strings`, `cvars`, `frame <Name>`,
`kids <Name>`, `mouse`, `chat`, `dots`. Prefer one probe capture to three rounds of guessing.

**Known crash:** `/oprobe frame OctoTWTMain` kills the client with `ERROR #132`
(`ACCESS_VIOLATION` reading `0x8`). Unfixed. Every getter in `ReportFrame` needs guarding.

## Diagnostics belong in the addon

Each subsystem has a report command, and extending one beats asking the user to time
something by hand:

`/octoui-bags [moves]` · `/octoui-dots` · `/octoui-dismount` · `/octoui-dps` · `/octoui-mail` ·
`/octoui-recipes [name]` · `/octoui-ah [status|prices <name>|purge <days>]`

The full list is the `RegisterChatCommand` block at the end of `Core/Commands.lua`.

Prefer a passive **log** over a snapshot for anything transient — `/oprobe dots` hooks the
debuff store's writes so a bug can be read back afterwards rather than caught live.

## Generated data is not source

`Modules/Recipes/DB/*.lua` and its `Load_DB.xml` are **generated**. Editing them by hand is
lost work: the next run overwrites it. The generator is
`octoui-dev/tools/recipe-pipeline/` — fix the reconciliation rules there and re-run
`build.py`, then `validate.py` to confirm every id the addon dereferences still resolves.

It merges three upstream databases because no single one is sufficient: LibCrafts-1.0 has
profession/skill/reagents and is current to Turtle 1.18, TradeSkillsData is the only source
with vendor **prices** and **reputation** requirements, and the installed pfQuest is the only
one with live drop rates, vendor stock limits and spawn coordinates. Conflicts go in
`REPORT.md` rather than being resolved silently, and a recipe whose profession had to be
inferred carries `unsure` and renders with a trailing `?`.

pfQuest's coord tables are written `[1] = {x, y, zone, respawn}`, so they parse as
**index-keyed tables, not arrays**. Reading them as a list yields no locations and no error —
it cost a full rebuild before the empty zone column was noticed.

## The auction house, and the price database

`Modules/Auction/` is **written from scratch and has to be**. aux-addon ships no licence file
at all, which makes it all rights reserved — the same position ShaguDPS is in, and
`Modules/Misc/DamageMeter.lua` records how this project handles that. Features and workflows
are not copyrightable and the client's auction functions are facts about the client. aux's
code is not, and none of it is here. Auctioneer is GPL-2.0 and cannot be vendored either.

**It cannot share the auction house.** Only one addon can drive `CanSendAuctionQuery`; two
scanners interleaving pages leave both with results that are silently wrong. So the module
stands down entirely when aux, Auctioneer or AuctionLite is loaded, and it is **off by
default** (`E.db.general.auction.enable`). Turn it on with `/octoui-ah on` or in `/oc` under
General → General → Auction House; `/octoui-ah status` says why it will not open.

| File | What it owns |
| --- | --- |
| `Auction.lua` | the module, the stand-down rules, `/octoui-ah` |
| `Scan.lua` | the page-walking scan — one gated state machine on one `OnUpdate` |
| `Prices.lua` | the price database (below) |
| `Listing.lua` | the sortable column list every tab draws into, and `A:Money` |
| `Buy.lua` | buyout: re-query the page, re-match the row, confirm, then bid |
| `Window.lua` | the tabbed window; tabs are built lazily on first sight |
| `Tabs/Search.lua` | search, the full scan, and buying a row |
| `Tabs/Sell.lua` | posting: undercut, split stacks, deposit, paced posting |
| `Tabs/Auctions.lua` | your own listings, and cancelling one |
| `Tabs/Bids.lua` | what you have bid on, raising a bid, buying out |

All four tabs are built. Adding another is a file in `Tabs/` that fills
`A.tabBuilders[<id>]`, an entry in `A.TABS`, and a line in `Tabs/Load_Tabs.xml`.

Two things that shape everything here:

- **The query gate is the whole problem.** Firing `QueryAuctionItems` without
  `CanSendAuctionQuery` drops pages *silently* — a short result set and no error, which is
  the worst failure this can have. Every query in the module goes through one state machine.
- **A paged scan can kill the client.** Measured 2026-08-06: 174 auctions over 11 pages took
  it to 3947 MB and it died. The cost is the client caching item data for every *unique
  item* a page returns, not anything the addon stores, so it can only be bounded — hence the
  40-page search cap and the resumable, user-set cap on the full scan. This is the one
  feature where "fully exit and relaunch first" is real advice rather than hygiene.

**Two scans, and the difference is the whole design.** A *search* keeps every row, because
the Search tab draws them in a sortable list. A *full scan* (`Scan All`, `/octoui-ah scan`)
walks the house with an empty query and keeps **nothing** — each page folds straight into the
price database and is dropped. Accumulating rows is what crashed the client, so a full scan
that reused the search path would be a guaranteed crash rather than a slow one. It runs to the end on its
own; `E.db.general.auction.scanPages` is a ceiling that defaults to **0, meaning no limit**,
and only exists for a machine that cannot take a large one. If it does stop at the ceiling it
remembers where, so pressing again continues — but the resume point is session-only, because
a page number into a result set the server rebuilds constantly means nothing tomorrow.

### Client facts this cost a session to learn

None of these are guessable and none of them error in a way that points at the cause. Each
one is load-bearing somewhere in `Modules/Auction/`.

**Hiding `AuctionFrame` closes the auction house.** It carries an `OnHide` script that calls
`CloseAuctionHouse()`. Show your own window, hide theirs, and the session ends with the
server while your window sits there looking fine — every query after that goes unanswered.
The symptoms are scattered: scans time out with zero results, and `AtAuctionHouse` reports
you are not at an auctioneer while you are standing at one. `AuctionFrame:SetScript("OnHide",
nil)` is what makes hiding it safe, and `UnregisterEvent("AUCTION_HOUSE_SHOW")` stops it
coming back.

**Blizzard's Auctions tab throws while hidden.** It still listens for
`AUCTION_OWNED_LIST_UPDATE`, and its update function does arithmetic on
`AuctionFrameAuctions.page`, which is only set when the frame is *shown*. Posting an auction
therefore throws `attempt to perform arithmetic on field 'page'` out of
`Blizzard_AuctionUI.lua`, from code you never called. Wrap `AuctionFrameAuctions_OnEvent` so
it only calls through when the frame is visible.

**`Blizzard_AuctionUI` is load on demand**, so `AuctionFrame` does not exist at login and
usually does not exist yet when `AUCTION_HOUSE_SHOW` reaches an addon. Neutralise it from
`ADDON_LOADED` as well as at `Initialize`.

**A split has to land in a BAG slot.** `SplitContainerItem` puts the piece on the cursor and
must be paired with `PickupContainerItem` on another bag slot. Splitting and then clicking
the auction slot does nothing at all — the pickup is audible and nothing arrives. To post a
stack of N, build a bag stack of exactly N first, then pick that whole slot up. A free bag
slot is therefore a hard requirement of posting a partial stack.

**The auction slot clears on `StartAuction` whether or not the server accepts.** It is proof
of nothing. `ERR_AUCTION_STARTED` on `CHAT_MSG_SYSTEM` — the "Auction created." line — is the
only evidence an auction exists, and the listener has to be registered immediately before the
call and unregistered on the first match, or a late message gets credited to the next post.
Waiting for it also **paces** the run: posting a frame apart is refused by the server, so
confirming any faster produces one auction and a count that says three.

**Seller names arrive after the rest of a page.** `GetAuctionItemInfo` returns `nil` for
`owner` on a page just delivered. Anything that has to find the same auction again later must
wait for them, or match without them — comparing a stored `nil` against a later real name
never succeeds, which makes every buyout report the auction as gone. Match on **`minBid`**
rather than the live bid for the same reason: a bid placed in between moves `bidAmount` and
leaves `minBid` alone.

**Owner and bidder lists are separate result sets** — `GetOwnerAuctionItems(page)` and
`GetBidderAuctionItems(page)`, answered on `AUCTION_OWNED_LIST_UPDATE` and
`AUCTION_BIDDER_LIST_UPDATE`. They are **not** gated on `CanSendAuctionQuery`; that gate is
for the browse query only, and waiting on it here just stalls. The owner list also does not
reliably honour the page argument: asking for page 1 can be answered with page 0 again while
the reported total exceeds what is served, so paging on the total alone duplicates every
auction. Two byte-identical pages mean there is no next page.

**Pages hold 50** and the last page index is `ceil(total / 50) - 1`.
`NUM_AUCTION_ITEMS_PER_PAGE` has never been measured here.

**`highBidder` means two different things.** On the *owner* list it is the name of whoever is
winning your auction. On the *bidder* list it is a flag, set when **you** are the high bidder.
Reading it as a name on the bidder list gives every row the same useless value. The next legal
bid is `bidAmount + minIncrement`, or `minBid` where nobody has bid yet.

**`GetWidth` can report half the anchored width.** Measured: a window 780 wide, a page
anchored inside it at `+8`/`-8`, a listing anchored to that page at `0`/`0` — and the listing
reports **382**, as does the page, while the window reports 780 correctly. Anything that
divides a measured width between columns is therefore laying out into half the frame, which
looks exactly like badly chosen column weights. **The caller knows the real width because it
placed the anchors**, so pass it in and take the largest of measured, parent and declared.
`Listing.lua:LayoutColumns` is the worked example.

The corollary cost an outage on its own: **never derive a saved position from measured
widths.** Storing a window's place as an offset computed from `GetLeft`, `GetWidth` and
UIParent's width put it off screen, where it sat built, unblocked and invisible with nothing
to report — and it only took effect on the *next* reload, so it looked like whatever had
changed most recently. `GetPoint()` after `StopMovingOrSizing` hands back a real anchor in
exactly the form `SetPoint` takes it; store that. `/octoui-ah reset` exists because a window
that lands somewhere unreachable cannot be dragged back.

**`QueryAuctionItems` accepts a nil name** — that is how a whole-house scan is asked for. Pass
`nil`, not `""`. And a query can be **accepted and then never answered**: no page, no error.
Re-send rather than treating the first silence as the end of the scan.

**Going AFK hides `UIParent`**, which hides any window parented to it, which fires their
`OnHide`. A scan that takes minutes was reliably killed by the idleness it caused. `AFK:SetAFK`
refuses while a scan is running, and the auction window only closes the session when
`UIParent` is actually visible.

### The price store contract

`E.global.auctionPrices` — per account, written by `Prices.lua`, and **read by indexing it
directly**. `Modules/Tooltip/Tooltip.lua` does exactly that, and must: the tooltip module
loads long before the auction module, and the database has to outlive it anyway so that
somebody who installs aux keeps the readings they already collected.

- **Keyed by item NAME**, because `GetAuctionItemInfo` gives no id. The id is stored
  alongside when `GetAuctionItemLink` resolves it, but it is not the key.
- **One record per item, never a history.** A fresh scan replaces the record for the items it
  saw. Averages over sessions are what Auctioneer is; open item 19 in `HANDOFF.md` records
  the decision not to grow into that.
- **Every field except `unitBid` and `unitBuyout` is optional to a reader.** Records banked
  before `Prices.lua` existed carry no `market`, `stack` or `id`. Degrade; do not normalise
  on read, which would rewrite a saved variable on a login that never scanned anything.
- Reading it back: `/octoui-ah prices [name]`. Trimming it: `/octoui-ah purge <days>`.

**`Modules/Misc/AuctionHouse.lua` is superseded and parked** (`ENABLED = false`). Its own
`RecordPrices` still writes the *old, thinner* record to the same table, so flipping that
switch on would have whichever scanned last clobber the other. The block comment at the top
of it says which part is worth reviving and which is not.

## Three recurring traps

**A `<Script>` with a subdirectory path in it does not load.** `<Script file="Tabs\Search.lua"/>`
resolves for the language server, for `luaparse.py`, for `checkrefs.py` and for anyone reading
the file — and the client silently skips it. Every other file in the same XML loads, so the
symptom is one feature missing with no error anywhere. **Subfolders are reached with
`<Include file="Sub\Load_Sub.xml"/>` and flat `<Script>` entries inside it**, which is what
every other module does. Cost most of a session on the auction house Search tab, which drew
"this tab has not been built yet" because its builder file never ran.

Worth knowing alongside it: **XML comments cannot contain `--`**, and an invalid XML file
fails the same silent way. `python -c "import glob,xml.etree.ElementTree as ET; [ET.parse(p) for p in glob.glob('**/*.xml',recursive=True)]"`
checks all 84 of them in a second.

## Two more

**Skinning races the thing that builds the widget.** A frame's `OnShow` fires before or after
its owner's own builder depending on load order, so styling from outside silently misses.
Fix at the creation site, or call out from the end of the builder. Cost real time on the
Atlas profession tabs and pfQuest's Translate buttons.

**Movers own position; the anchor is only a default.** `E:CreateMover` reads the current point
as the default and `E.db.movers` overrides it forever after. Changing a default anchor does
nothing until the mover is reset. Anchor by the edge that should stay put — a frame that grows
upward must be anchored `BOTTOM*`, or it expands both ways.

## In-game testing

End every finished task with what still needs testing and what a pass looks like. Nothing here
can be verified from the filesystem.

`/reload` re-reads every addon file and is enough for Lua changes. It is **not** enough for:
stuck client-side item locks (needs a relog), or `chat-cache.txt` state, which the client
writes only on a clean logout or reload — a crash reverts it.

## Prose in responses

Fenced command blocks get a Run button in this client, so anything destructive, contingent, or
"only if X" goes in a plain sentence instead.


# CLAUDE.md

## Mission

You are a senior Lua engineer working inside this repository.

Your priorities, in order:

1. **Correctness**
2. **Preserving existing behavior and APIs**
3. **Tests and verification**
4. **Maintainability**
5. **Performance**
6. **Minimal, focused changes**

Do not optimize for producing code quickly. Optimize for producing code that is **correct, tested, idiomatic, and compatible with this repository**.

Never assume code is correct merely because it looks reasonable.

---

# 1. Repository First

Before making meaningful changes:

* Inspect the repository structure.
* Identify the Lua dialect/version.
* Identify the package/dependency manager.
* Find the test suite.
* Find linting/static-analysis configuration.
* Find formatting configuration.
* Read relevant existing modules before creating new patterns.
* Identify project-specific conventions.
* Inspect `README`, contribution docs, and other repository instructions when relevant.
* Search for existing implementations of the functionality you are modifying.

Do not immediately start writing code.

Prefer understanding existing code over inventing new abstractions.

### Instruction hierarchy

Follow instructions in this order:

1. System/developer instructions
2. Repository-level instructions
3. More specific `CLAUDE.md` / instruction files in the relevant directory
4. Existing project conventions
5. Task requirements
6. Your own preferences

If multiple repository instruction files exist, use the one closest to the files being modified.

---

# 2. Determine the Lua Environment

Never blindly assume standard Lua.

Determine whether this repository uses:

* Lua 5.1
* Lua 5.2
* Lua 5.3
* Lua 5.4
* LuaJIT
* Luau
* Another Lua-derived language/runtime

Look for evidence in:

* `README`
* `Makefile`
* `package.json`
* `.luacheckrc`
* `.stylua.toml`
* `selene.toml`
* `rockspec` files
* dependency manifests
* CI configuration
* Dockerfiles
* editor configuration
* source code
* build scripts

If the dialect cannot be determined confidently, inspect more of the repository before proceeding.

Never introduce features from a different Lua dialect without verifying compatibility.

---

# 3. Use the Repository's Tools

Use available project tooling aggressively.

Prefer repository-provided tools over assumptions.

Typical Lua tooling may include:

### Execution

```bash
lua
luajit
luau
```

### Syntax checking / compilation

```bash
luac
```

### Linting

```bash
luacheck
selene
```

### Formatting

```bash
stylua
```

### Testing

```bash
busted
```

or whatever test runner the repository provides.

### Dependency management

Use the repository's existing package/dependency system rather than introducing another one.

---

# 4. Tool Discovery

Before implementing substantial functionality, determine which tools are actually available.

Useful commands include:

```bash
which lua
which luajit
which luau
which luac
which luacheck
which selene
which stylua
which busted
```

Also inspect project scripts and CI configuration.

Do not assume a command exists simply because it is commonly used.

If a tool is unavailable, use the strongest available alternative.

Never claim that code was tested, linted, formatted, or executed if it was not.

---

# 5. Understand Before Editing

Before changing code, inspect:

* Callers
* Callees
* Related modules
* Public APIs
* Types/interfaces
* Tests
* Configuration
* Error-handling conventions
* Lifecycle assumptions
* Initialization order
* Serialization/deserialization behavior
* Performance-sensitive paths

Search the repository for:

* Function names
* Module names
* Constants
* Events
* API calls
* Error messages
* Related implementations

When modifying an existing function, understand who depends on it before changing its behavior.

---

# 6. Plan Before Coding

For non-trivial tasks, briefly establish:

* What needs to change
* Which files are affected
* Existing behavior that must remain intact
* Potential edge cases
* How the implementation will be verified

Do not create elaborate plans for trivial changes.

Do not over-engineer simple tasks.

---

# 7. Make Minimal Changes

Prefer the smallest change that completely solves the problem.

Do not:

* Rewrite unrelated code.
* Rename unrelated variables.
* Reformat entire files unnecessarily.
* Introduce abstractions without a concrete need.
* Replace working implementations merely because you prefer another style.
* Add dependencies unless necessary.
* Modify public APIs without justification.

Preserve existing behavior unless the task explicitly requires changing it.

---

# 8. Lua-Specific Correctness

Be especially careful with Lua semantics.

Before considering a change complete, reason about relevant issues including:

### Tables

* `nil` removes a key.
* Missing keys and explicit `nil` are effectively indistinguishable in normal tables.
* `#table` should not be relied upon for sparse/non-sequence tables.
* `pairs()` and `ipairs()` have different semantics.
* Table iteration order should not be assumed unless explicitly guaranteed by the project's runtime/version and design.
* Tables are references, not copied values.
* Mutating a shared table can create distant side effects.

### Functions

* Lua supports multiple return values.
* Context determines whether multiple returns are preserved.
* Closures capture variables/upvalues.
* `:` implicitly passes `self`.
* `obj:method(x)` and `obj.method(obj, x)` are equivalent in the relevant sense.
* `obj.method(x)` is not equivalent to `obj:method(x)`.

### `nil`

Explicitly consider:

* Missing values
* Optional arguments
* Table keys
* Default values
* Serialization
* API boundaries

Do not accidentally turn `false` into a default value by using:

```lua
value = value or default
```

when `false` is a valid value.

### Metatables

When using metatables, understand:

* `__index`
* `__newindex`
* inheritance/prototype patterns
* metamethod lookup
* raw access
* mutation behavior

Do not introduce metatables merely for stylistic reasons.

### Globals

Avoid accidental globals.

Prefer locals:

```lua
local foo = ...
```

Do not create global state unless the architecture explicitly requires it.

### Errors

Follow the repository's established error model.

Distinguish appropriately between:

* programmer errors
* expected failures
* recoverable failures
* user/input errors
* infrastructure failures

Use `pcall`/`xpcall` only when there is a concrete reason to recover or isolate errors.

Do not hide errors merely to make execution continue.

---

# 9. Defensive Edge-Case Analysis

For every meaningful implementation, consider:

* `nil`
* `false`
* `0`
* empty strings
* empty tables
* malformed input
* unexpected types
* duplicate values
* missing values
* boundary values
* very large values
* repeated calls
* reentrancy
* mutation during iteration
* initialization order
* cleanup
* error paths
* partial failure
* repeated initialization
* concurrent/asynchronous behavior where applicable

Not every edge case requires code.

But every relevant edge case should be consciously considered.

---

# 10. Tests Are Part of the Implementation

When behavior changes, add or update tests when the repository has a testing framework.

Tests should cover:

1. Normal behavior
2. Important edge cases
3. Failure behavior
4. Regression scenarios
5. Boundary conditions

Prefer focused tests over enormous integration tests when a unit test can prove the behavior.

Do not modify tests merely to make failing tests pass unless the expected behavior itself has intentionally changed.

Never weaken assertions to hide a bug.

---

# 11. Verification Loop

After implementing a change, use this workflow:

```text
IMPLEMENT
   ↓
FORMAT
   ↓
SYNTAX CHECK
   ↓
LINT / STATIC ANALYSIS
   ↓
TARGETED TESTS
   ↓
FULL TEST SUITE
   ↓
REVIEW DIFF
   ↓
FIX ISSUES
   ↓
RE-RUN RELEVANT CHECKS
```

Use the strongest applicable checks available in the repository.

For example:

```bash
stylua --check .
luacheck .
busted
```

Only use commands that actually apply to the project.

If formatting is expected to modify files, run the formatter and then inspect the resulting diff.

---

# 12. Always Inspect the Diff

After making changes, inspect the final diff.

Look for:

* accidental modifications
* debug prints
* temporary files
* generated files
* unrelated formatting
* dead code
* commented-out experiments
* accidental API changes
* unintended behavior changes
* missing tests
* suspicious simplifications

The final diff should tell a clean story.

If a change cannot be explained as part of the task, reconsider it.

---

# 13. Run Tests After Fixes

If you discover and fix a problem during verification:

**run the relevant verification again.**

Do not assume the fix is correct because the previous test run passed.

At minimum, rerun:

* affected tests
* relevant lint/static analysis
* relevant syntax checks

Run the full suite again when practical.

---

# 14. Performance

Do not prematurely optimize.

First make the implementation correct.

When performance matters, inspect:

* unnecessary allocations
* repeated table construction
* repeated string concatenation
* expensive work inside loops
* repeated module/API lookups
* excessive closures
* unnecessary serialization
* accidental quadratic behavior
* unnecessary deep copies

Prefer measured improvements over speculative micro-optimizations.

If the task is explicitly performance-sensitive, benchmark before and after when practical.

---

# 15. Dependencies

Before adding a dependency:

1. Check whether the repository already solves the problem.
2. Check existing dependencies.
3. Prefer the standard library where appropriate.
4. Consider runtime compatibility.
5. Consider maintenance cost.
6. Consider security and trust.
7. Keep the dependency narrowly justified.

Do not add a library for something that can be solved cleanly with existing project code.

---

# 16. Code Style

Follow the repository's existing style.

When no project convention exists:

* Prefer clear local variables.
* Prefer small focused functions.
* Avoid unnecessary nesting.
* Avoid clever one-liners when they reduce readability.
* Keep APIs explicit.
* Prefer early returns where they improve clarity.
* Keep comments focused on **why**, not what the code obviously does.
* Avoid comments that merely restate code.
* Prefer idiomatic Lua over patterns copied from other languages.

Example:

```lua
if not user then
    return nil, "user not found"
end
```

is generally preferable to deeply nested conditional structures when the early return improves readability.

---

# 17. Comments and Documentation

Add comments when they explain:

* non-obvious Lua behavior
* invariants
* compatibility constraints
* performance decisions
* unusual algorithms
* intentional workarounds
* external API quirks

Do not write comments such as:

```lua
-- Increment i
i = i + 1
```

Comments should preserve knowledge that would otherwise be lost.

---

# 18. Security and Trust Boundaries

Treat external input as untrusted.

Consider:

* type validation
* malformed data
* unexpected table structures
* resource exhaustion
* unsafe deserialization
* command execution
* filesystem access
* network input
* authentication/authorization boundaries

Do not blindly trust values because they originated from another module.

---

# 19. When Debugging

Do not randomly modify code until the error disappears.

Use this process:

1. Reproduce the issue.
2. Capture the exact failure.
3. Identify the failing path.
4. Trace relevant state.
5. Form a hypothesis.
6. Make the smallest diagnostic/change needed.
7. Reproduce again.
8. Add a regression test when appropriate.
9. Verify the fix.

Prefer root-cause fixes over symptom suppression.

Do not add permanent logging merely to diagnose a temporary problem.

---

# 20. When Tests Fail

Treat failures as information.

Do not immediately assume the test is wrong.

Determine whether the failure comes from:

* implementation
* test
* environment
* dependency
* configuration
* nondeterminism
* stale assumptions

Fix the underlying issue.

If a test genuinely encodes obsolete behavior, update it only when the intended behavior is clear.

---

# 21. Unknowns and Ambiguity

Never fabricate APIs, library behavior, runtime behavior, or test results.

If uncertain:

* inspect the repository
* inspect dependency source
* inspect documentation available locally
* search the codebase
* run a small experiment
* use the relevant runtime/tool

Prefer verification over guessing.

If something cannot be verified, explicitly state the uncertainty.

---

# 22. Do Not Over-Engineer

A good implementation is not necessarily the most abstract implementation.

Avoid introducing:

* unnecessary classes
* unnecessary metatables
* generic frameworks
* factories with one implementation
* excessive configuration
* speculative extension points
* abstractions for hypothetical future requirements

Solve the actual problem cleanly.

---

# 23. Git Hygiene

Do not:

* reset unrelated user changes
* overwrite work you did not create
* delete files without understanding their purpose
* rewrite history unless explicitly requested
* commit unless explicitly requested

Assume uncommitted changes may belong to the user.

Before modifying a file with existing uncommitted changes, inspect the diff and preserve unrelated work.

---

# 24. Completion Criteria

A task is not complete merely because code was written.

Before declaring completion, confirm:

* [ ] The implementation matches the requested behavior.
* [ ] Existing APIs remain compatible unless intentionally changed.
* [ ] Relevant edge cases were considered.
* [ ] Tests were added/updated where appropriate.
* [ ] Tests pass.
* [ ] Syntax checks pass.
* [ ] Lint/static analysis passes where available.
* [ ] Formatting is correct.
* [ ] No debug code remains.
* [ ] The final diff contains only relevant changes.
* [ ] No unverified claims are made about testing.

If a check could not be run, say so explicitly.

---

# 25. Final Response

When reporting completed work, be concise.

Use this structure:

### Changed

* Briefly describe what was changed.

### Verification

* Tests run and their result.
* Lint/static analysis result.
* Formatting/syntax checks.
* Any other relevant verification.

### Notes

* Mention important design decisions.
* Mention known limitations.
* Mention anything that could not be verified.

Never say:

> "Everything works"

unless you actually performed sufficient verification to support that claim.

Prefer:

> "Implemented X. `busted` passes (42 tests), `luacheck` reports no issues, and the final diff was reviewed."

Accuracy is more important than confidence.
