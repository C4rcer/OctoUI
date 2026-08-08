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

## Writing Lua for this client

1.12 is **Lua 5.0**. No `#` operator, no `string.gmatch` (`gfind`), no `select` or `strsplit`
except where `Compatibility/` polyfills them. Event handlers read the globals `event`,
`arg1..arg9` and `this` — they take no arguments.

There is no Lua linter here. Syntax-check before deploying; a block-balance scan catches the
common failure:

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

`/octoui-bags [moves]` · `/octoui-dots` · `/octoui-dismount` · `/octoui-dps` · `/octoui-mail`

Prefer a passive **log** over a snapshot for anything transient — `/oprobe dots` hooks the
debuff store's writes so a bug can be read back afterwards rather than caught live.

## Two recurring traps

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
