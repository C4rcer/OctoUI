# OctoUI

A complete user interface replacement for **OctoWoW**, the Vanilla+ private
server running on the real **1.12.1** client.

OctoUI is a port of **ElvUI** to this client, with a threat meter and a set of
quality-of-life tweaks folded in so that one addon owns the whole UI. Nothing
else needs installing, and there is nothing to configure before it works.

<p align="center"><img src=".github/logo.png" alt="OctoUI" width="320"></p>

---

## Install

### With the OctoWoW launcher (recommended)

Paste this address into the launcher's addon section:

```
https://github.com/C4rcer/OctoUI.git
```

The launcher clones it straight into `Interface\AddOns\OctoUI` and keeps it
updated. That is the whole install.

### By hand

1. Download the repository as a ZIP and unpack it.
2. Rename the unpacked folder to exactly **`OctoUI`** (a ZIP from GitHub
   unpacks as `OctoUI-main`, which will not load under that name).
3. Move it into `<your WoW folder>\Interface\AddOns\`.
4. Restart the game. You should end up with
   `Interface\AddOns\OctoUI\OctoUI.toc`.

### First run

Type `/oc` and click **Install** to run the setup wizard. It asks for a layout
(healer, caster DPS, physical DPS, tank) and lays the UI out to match. You can
re-run it any time from the same place.

> **Remove or disable pfUI, and any other full UI replacement, before using
> OctoUI.** Two UI replacements will fight over the same frames. Smaller addons
> are fine, but see [Playing well with other addons](#playing-well-with-other-addons).

---

## Quick guide

### The commands worth knowing

| Command | What it does |
| --- | --- |
| `/oc` or `/octoui` | Open the configuration window. Everything lives here. |
| `/moveui` | Unlock every frame so you can drag it. Run it again to lock. |
| `/resetui` | Put all frames back where they started. `/resetui uf` resets just the unitframes. |
| `/rl` | Reload the interface. |
| `/twt` | Threat meter commands (see below). |
| `/bgstats` | Toggle battleground datatexts while inside a battleground. |
| `/ocgrid` | Toggle an alignment grid, handy when placing frames by hand. |
| `/farmmode` | Enlarge the minimap for farming. |
| `/in 1.5 /say hi` | Run a command after a delay. |



### Moving things

`/moveui` unlocks everything at once. Drag a frame where you want it, then run
`/moveui` again to lock. Holding **Shift** while dragging disables snapping if
you want a position that does not align to the others.

If you lose something off-screen, `/resetui` puts it all back.

### Making the action bars fit you

Everything below is under **/oc → ActionBars**, and each of the bars 1-5 is
configured separately.

- **Button Size** shrinks or grows the whole bar.
- **Buttons Per Row** controls wrapping. A 12-button bar at 6 per row becomes
  two rows of 6 instead of one long strip. The bar's backdrop resizes to match.
- **Buttons** sets how many slots the bar shows at all. Drop it to 6 for a
  minimal setup, or enable all five bars if you want every ability visible.
- **Backdrop** draws the panel behind the buttons.
- **Mouseover** hides a bar until you move the mouse over it.

A minimal setup is a small button size with few buttons and no backdrop. An
everything-visible setup is all five bars enabled with per-row wrapping keeping
them compact.

### Threat meter

The threat meter is on by default and works in a party or raid when you are
fighting elites or bosses. It reads live threat from the server, so the numbers
are real rather than estimated.

- `/twt show` (or `/twtshow`) opens the window if you have closed it.
- The **cog** on the window title bar opens its own settings: bar height, font,
  columns, window scale, target-frame glow, aggro warning sound, and Tank Mode.
- The **padlock** locks the window in place. Drag the title bar to move it, and
  the grip in the bottom-right corner to resize.
- Turn the whole thing off under **/oc → General → Threat Meter**.

### Warlock summon list

A raider types **`123`** in chat and every warlock in the raid gets a small
clickable list. Click a name to target them, cast Ritual of Summoning and
announce it — and the name comes off every warlock's list at once, so two of you
never burn two shards on the same person.

- **Left-click** summons. **Ctrl-click** only targets, without spending a shard.
  **Right-click** drops the row.
- Warlocks sort to the top, because summoning another summoner is the click that
  pays for itself.
- It refuses to summon someone carrying **Evil Twin**, or someone already
  standing next to you, and whispers them to say so rather than wasting a shard.
- **Warlocks only.** Nothing loads at all on any other class — no window, no
  chat hooks, no options page. Warlocks relay to each other, so a `123` said
  within earshot of one reaches the ones standing out of range.

Settings live under **/oc → General → Summon List**: the trigger word, where the
summon is announced (say, raid, or nowhere), whether to whisper the person,
whether to include the zone and your remaining shard count, and which alert
sound plays. `/moveui` positions the list.

The Alert Sound dropdown plays each sound as you move through it. It can only
offer what LibSharedMedia knows, which is OctoUI's own files — to use one of the
thousands the game itself ships, audition a path with
`/octoui-summon play Sound\Interface\ReadyCheck.wav` and keep it with
`/octoui-summon alert <that path>`. Silence means the file is not there; the
client does not report a missing sound.

Everything is also reachable from chat, as `/octoui-summon` or `/warlocksummon`:

| Command | What it does |
| --- | --- |
| `/octoui-summon` | Who is waiting, and the current state of everything. |
| `/octoui-summon help` | The list below, in chat. |
| `/octoui-summon show` | Show or hide the list window. |
| `/octoui-summon settings` | Open the options straight at this page. |
| `/octoui-summon zone` | Toggle zone info in the announcement. |
| `/octoui-summon whisper` | Toggle whispering the person being summoned. |
| `/octoui-summon shards` | Toggle the remaining shard count. |
| `/octoui-summon sound` | Toggle the alert, and play it if you just switched it on. |
| `/octoui-summon play` `[sound or path]` | Play the alert, or audition any sound or file path. |
| `/octoui-summon alert <sound or path>` | Keep the sound you just auditioned. |
| `/octoui-summon add`/`remove` `<name>` | Put a row up or take one down by hand. |

> It speaks the same addon messages as the older **LockPort** addon, so a raid
> that is half OctoUI and half LockPort still shares one list. If you have
> LockPort installed, remove it — two copies react to the same trigger.

### Other things you may want to switch on

All under **/oc → General**:

| Setting | Default | What it does |
| --- | --- | --- |
| Auto Stance | on | Switches to whichever stance or form a spell needs. |
| Auto Dismount | on | Dismounts, or drops your form, when you cast something that requires it. |
| Combat Feedback | on | Floating damage and healing numbers on the unitframes. |
| Reveal World Map | on | Fills in unexplored areas of the world map. |
| Energy Ticks | off | Shows the energy/mana tick timer on your power bar. |
| Macro Icons | on | A macro starting with `#showtooltip` uses that spell's icon. |
| Macro Tweaks | on | Adds `/equip` and `/use` to macros, and keeps macro spam out of chat. |
| Bag Item Click | on | Right-click a bag item to add it to a trade, or search or sell it at the auction house. Hold **Shift** for the normal use/equip. |
| Reagent Counter | off | Shows remaining reagents on action buttons. |
| Summon List | on | The warlock summon list described above. |
| Threat Meter | on | The threat meter described above. |

### Pixel Perfect

**/oc → General → Pixel Perfect** draws borders exactly one screen pixel wide.
It is **off** by default in OctoUI, because on large or high-resolution
monitors a one-pixel border is nearly invisible and the buttons look bare. Turn
it on if you prefer the thinner look. Changing it needs a reload.

---

## What is included

### The threat meter

[TWThreat](https://github.com/CosminPOP/TWThreat) by **Xerron/Er**, Turtle WoW's
threat meter, is built in. It speaks the server's threat API, so it reports true
threat, threat needed to pull, TPS and percentages, with an optional glow and
percentage readout on the target frame, a full-screen warning glow, an aggro
sound and a Tank Mode.

If you already run the standalone TWThreat addon, **disable it**. Two copies
create the same frames and double the network traffic.

### The warlock summon list

Rewritten against OctoUI's own toolkit from the workflow **LockPort** by
**Gurky-Turtle** established, which it replaces. None of that addon's code is
here — its repository is gone and it carried no licence — but its addon messages
are kept exactly, so the two still share one list across a raid.

If you already run LockPort (or its rebranded WarlockSummon build), **remove
it**. Both react to the same trigger word, and you would get two lists.

### Absorbed from ShaguTweaks

These were ported in so that ShaguTweaks is not needed alongside OctoUI:

Auto Stance, Auto Dismount, Energy Ticks, Combat Feedback, Reveal World Map.

### Absorbed from ShaguTweaks-extras

Macro Tweaks, Macro Icons, Reagent Counter, Bag Item Click.

Everything else in those two addons was checked and left out because ElvUI
already does it (raid frames, bag search, chat history and timestamps, stance
bar, world map handling, sell junk, chat links, cooldown numbers, and so on).

---

## Playing well with other addons

OctoUI replaces the entire interface, so anything that also replaces a whole
interface will conflict.

**Do not run alongside OctoUI:**

- **pfUI** and its plugins. It is a second full UI replacement.
- **ShaguTweaks** and **ShaguTweaks-extras**. Everything worth having is
  already here, and running both gives you two of each feature.
- **TWThreat** standalone. Built in, see above.
- **LockPort** / **WarlockSummon**. The summon list is built in, and both would
  answer the same trigger word.

**Fine to run alongside:** quest helpers (pfQuest), boss mods (BigWigs),
damage meters, auction addons, and most single-purpose addons.

If something looks doubled up, the usual cause is another addon owning the same
piece of the UI. You can turn OctoUI's own modules off individually under
**/oc → Module Control** rather than giving up either addon.

---

## Reporting a problem

Please include:

1. What you were doing when it happened.
2. The full error text, if there was one. Turn errors on with `/luaerror on`.
3. Whether it still happens with only OctoUI enabled.

`/oc → Status Report` gathers your version, resolution and addon state in one
place, which saves a lot of back and forth.

---

## Credits

OctoUI is assembled from other people's work. Please support the original
authors.

| Project | Author | Link |
| --- | --- | --- |
| **ElvUI** | Elv and Simpy | [tukui-org/ElvUI](https://github.com/tukui-org/ElvUI) |
| **ElvUI 1.12.1 backport** | the ElvUI-Vanilla contributors | [ElvUI-Vanilla/ElvUI](https://github.com/ElvUI-Vanilla/ElvUI) |
| **TWThreat** | Xerron/Er | [CosminPOP/TWThreat](https://github.com/CosminPOP/TWThreat) — [Ko-fi](https://ko-fi.com/xerron) |
| **ShaguTweaks** | Eric Mauser (shagu) | [shagu/ShaguTweaks](https://github.com/shagu/ShaguTweaks) |
| **ShaguTweaks-extras** | Eric Mauser (shagu) | [shagu/ShaguTweaks-extras](https://github.com/shagu/ShaguTweaks-extras) |
| **LockPort** (the summon list workflow) | Gurky-Turtle | repository no longer available |
| **oUF** | haste and contributors | [oUF-wow/oUF](https://github.com/oUF-wow/oUF) |
| **Ace3** | the Ace3 team | [WowAce](https://www.wowace.com/projects/ace3) |
| **LibSharedMedia-3.0** | Elkano | [WowAce](https://www.wowace.com/projects/libsharedmedia-3-0) |

The Recipe Finder ships a generated database reconciled from three projects. No
code from any of them is included, only the facts they record about the game:

| Project | Author | Link |
| --- | --- | --- |
| **LibCrafts-1.0** | Refaim | [refaim/LibCrafts-1.0](https://github.com/refaim/LibCrafts-1.0) (MIT) |
| **TradeSkillsData** and **TradeSkillsData-turtle** | Refaim | [refaim/TradeSkillsData](https://github.com/refaim/TradeSkillsData) |
| **pfQuest** and **pfQuest-turtle** | Eric Mauser (shagu) | [shagu/pfQuest](https://github.com/shagu/pfQuest) (MIT) |

The compatibility layer that lets Ace3 and ElvUI run on Lua 5.0 borrows
approaches from [pfUI](https://github.com/shagu/pfUI) by shagu, which is the
reference for what actually works on this client.

Ported and maintained for OctoWoW by **Carcer - N'Zoth**.

If OctoUI is useful to you and you would like to buy me a coffee:
[ko-fi.com/carcer7378](https://ko-fi.com/carcer7378). Entirely optional, and
please consider supporting the authors above first.

---

## Licence

ElvUI is licensed per the upstream project. The ShaguTweaks and
ShaguTweaks-extras code is MIT, Copyright (c) 2021 Eric Mauser (shagu);
attribution is kept in each ported file. TWThreat is included with credit to
its author.

The warlock summon list contains no LockPort code. That addon states no licence
and its repository is gone, so it is credited above for the workflow and for the
addon-message format the two share, both of which are facts about how a raid
summons rather than anything ownable.

The Recipe Finder's database is derived from pfQuest and LibCrafts-1.0 (both
MIT) and from TradeSkillsData, which states no licence; it is credited above and
supplies only the vendor prices and reputation requirements, which no
MIT-licensed source records.

Technical notes on how the port was done, and what had to change to run on the
1.12.1 client, are in [PORTING.md](PORTING.md).
