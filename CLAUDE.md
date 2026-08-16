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
`/octoui-recipes [name]`

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
