# FableHub

**A guild management addon for WoW: Forever**, built for the guild *Fable*.

FableHub puts the guild's day-to-day organisation in one in-game window: roster and alts, professions and craft requests, raid sign-ups and plans, ready checks, loot priorities and the guild bank. Everything is shared between guild members over the hidden addon channel. There's no website, bot or account to set up.

![Version](https://img.shields.io/badge/version-0.18.4-c9a26b) ![Client](https://img.shields.io/badge/client-WoW%3A%20Forever-555) ![Status](https://img.shields.io/badge/status-beta-orange) ![License](https://img.shields.io/badge/license-MIT-blue)

---

## Features

| Area | What it does |
|---|---|
| **Home** | Dashboard with Message of the Day, officer announcements (pinnable), guild activity feed, recent loot, upcoming raids with one-click sign-up, open craft and bank requests, who's online. |
| **Roster** | Members with level, rank, zone, notes, last seen and 30-day raid attendance. **Alts** are linked automatically from each player's account and grouped under their main. |
| **Professions** | Every guild member's recipes, searchable by recipe or crafted item, with rarity colours and item level sorting. **Craft Requests** let members ask for an item, and crafters who know the recipe get notified. **Camping** has a camp guide and a camp planner. |
| **Raids** | **Raid nights**: one-off or weekly events, shown in local time, with sign-ups (Accepted / Late / Tentative / Declined), roles, notes and automatic attendance. Officers can import sign-ups from **Raid-Helper** (Discord). **Raid plans**: a drag-and-drop group builder with buff coverage. **Ready check**: shows flasks, food, class buffs, blessings and enchants for the whole raid. |
| **Loot** | Imports **That's My BIS** prio lists and wishlists, lets officers add or remove entries, shows prio info in item tooltips, opens an award window when an officer loots, and keeps an automatic loot history. |
| **Guild Bank** | Browse every tab, search, gold and transaction logs from anywhere. **Follows the guild's own tab permissions**, and members can request items from officers. |
| **Settings** | Every option in one place (cog in the title bar): alerts, minimap button, window opacity, officer ranks. |

The window can be resized, and pages adjust to its width. Tables scroll sideways and toolbars wrap. If [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) is installed, FableHub uses its accent colour.

For a full walkthrough of every page, see the **[player guide](GUIDE.md)**.

---

## Installation

1. Download the latest `FableHub-x.y.z.zip` from the [Releases](../../releases) page, or use **Code → Download ZIP** on this page.
2. Close the game.
3. Unzip it so the folder sits at
   `World of Warcraft\_forever_\Interface\AddOns\FableHub\FableHub.toc`.
   A **Download ZIP** copy unzips as `FableHub-main`: rename that folder to `FableHub`. You can delete its `tests` folder; the game ignores it either way.
4. Start the game. On the character screen, open **AddOns**, make sure **FableHub** is ticked, and tick **Load out of date AddOns** if it's listed as out of date.
5. In game, type **`/fhub`**. Open each of your profession windows once so your recipes are shared with the guild.

FableHub is useful once a few guild members have it, and more useful once an officer has it, since attendance and loot are recorded by officers in the raid.

---

## Commands

| Command | Does |
|---|---|
| `/fhub` | Open or close the window (the minimap button does the same) |
| `/fhub sync` | Ask the guild for anything you've missed |
| `/fhub scan` | Rescan your character (professions, talents) |
| `/fhub status` | Show what FableHub knows and who uses it |
| `/fhub minimap` | Show or hide the minimap button |
| `/fhub opacity 50-100` | Window opacity (default 85) |
| `/fhub resetwindow` | Put the window back in the middle at its default size |
| `/fhub bug` | Open a report (version, client build, name matching, recent errors) to copy into Discord |
| `/fhub ping Name` | Test which spelling of a guildmate's name FableHub can whisper (works even if they don't have FableHub) |
| `/fhub reset` | Clear stored guild data |
| `/fhub debug` | Toggle debug messages |

`/fablehub` works as well.

---

## How sharing works

- Each player's addon shares **only their own characters** (level, professions, recipes, talents, alts) on the guild addon channel. Everyone stores what they hear, so you can still see offline members.
- When someone logs in, the online member with the newest FableHub version sends them anything they missed, so data catches up without anyone needing to be online at the same time. Officer data (raid nights, loot, announcements, raid plans, attendance) is only passed on by an online officer.
- **Officer-only data** (announcements, raid nights, loot, attendance, raid plans, alt links set by officers) is only accepted when the author is an officer *and* it was sent by that officer or passed on by another officer. Every receiver checks this against the guild roster. The Guild Master chooses which ranks count as officers.
- **Members' own data** (sign-ups, requests, guild bank reads) can only be changed by that member or an officer. Copies passed on by other members only fill in things a receiver doesn't have yet.
- **Other safeguards:** addon whispers from outside the guild are ignored, WoW formatting codes are stripped from everything received, changes dated more than five minutes in the future are refused, and each member can have at most 10 open craft requests and 10 open bank requests.
- **Guild bank** contents are read when a member opens the bank in game. Tabs every rank may view go to the whole guild. Restricted tabs are whispered only to members whose rank may view them, using the permissions the Guild Master's FableHub reads from the game.
- Messages are split into parts, throttled and paused during combat and boss encounters.
- Nothing leaves the game. Addons have no internet access; the Raid-Helper and That's My BIS imports work by pasting their export text.

---

## Repository layout

The repository root is the addon folder (what goes in `Interface\AddOns\FableHub`):

```
FableHub.toc         load order and metadata
Core.lua             saved data, options, events, slash commands
Comm.lua             guild messaging, chunking, throttling, catch-up sync, trust checks
UI.lua, Theme.lua    window, sidebar, lists, toolbars, shared widgets
UI_*.lua             one file per page
Buffs.lua            class buffs used by Raid plans        (editable data)
Consumables.lua      ready check consumables and enchants  (editable data)
Camping.lua          camp items and campfires              (editable data)
Libs/                LibDeflate, json.lua, Base64
Media/               font and textures
GUIDE.md             player guide
tests/              (not needed in game)
  mockwow.lua        a minimal WoW API mock with several simulated clients
  test_sync.lua      the test suite
  run.py             runs the suite under Lua 5.1
  fixtures/          real Raid-Helper exports used by the tests
```

The data files (`Buffs.lua`, `Consumables.lua`, `Camping.lua`) are plain Lua tables. They're meant to be edited as Forever's classes, consumables and camping values are confirmed.

---

## Development

### Running the tests

The suite loads the addon into several simulated clients sharing a fake guild channel and clock. It checks syncing, permissions, imports, the UI building and laying out at different window sizes, and that no errors were reported.

```bash
pip install lupa            # Lua 5.1 runtime for Python
python3 tests/run.py        # run from the repository root
```

Expected output ends with something like `366 passed, 0 failed`.

### Static checks

```bash
luacheck *.lua --std lua51 --no-max-line-length --allow-defined-top
```

Warnings about WoW API globals are expected (luacheck doesn't know the game's API).

### Building a release

Put everything except `tests/`, `.gitignore` and the `.git` folder into a folder called `FableHub`, and zip that folder as `FableHub-<version>.zip`. Bump the version in both `FableHub.toc` (`## Version`) and `Core.lua` (`ns.VERSION`).

When a guildmate (an officer, or at least two members) runs a newer version, everyone on an older one gets a chat message and a note in the sidebar.

### Fresh start for the live launch

`ns.DATA_EPOCH` in `Core.lua` is the data era. In the build released for launch, change it from `1` to `2`:

- each player's saved guild data and character records from the beta are cleared once (settings are kept), with a chat message saying so;
- FableHub moves to a new addon-message channel (`FableHub2`), so anyone still on an older version can't send beta data into the new guild. Their hellos are still heard, so they're counted as FableHub users and told to update.

Guild data for a guild not visited for 90 days is removed automatically.

### Notes for contributors

- Forever runs the modern Retail client with classic-style content. Use modern APIs with fallbacks, and guard anything removed from Retail (for example `UnitBuff`, `MouseIsOver`).
- Register events through `ns.RegisterEvent`, which skips events the client doesn't know.
- New page toolbars should use `UI.Toolbar` so they reflow with the window width. Tables should use `UI.CreateList`.
- Choosing a guild member should go through `UI.PickMember` (the searchable guild list).
- Received officer data must pass `ns.OfficerSent(sender, author)` (author is an officer, and the sender is that author or another officer). Changes to a member's own data use `ns.FirstHand(sender, actor)`; second-hand copies only fill gaps. Check incoming timestamps with `ns.TimeOK(ts)`. Catch-up for officer data is answered by `ns.AmOfficerRelayFor`.

---

## Known limitations

- `## Interface: 16001` in the TOC is a best guess for Forever's client build. If the game reports the addon as out of date, check the real value with `/dump select(4, GetBuildInfo())`.
- Whispered addon messages to characters whose Forever names include a surname (a space in the name) haven't been tested in game yet.
- Guild bank contents are only as fresh as the last time someone with FableHub opened the bank.
- Ready check enchant reads need an inspect, which only works within about 28 yards.

---

## Credits and licences

- **LibDeflate** by Haoqian He, zlib licence (`Libs/LibDeflate-LICENSE.txt`)
- **json.lua** by rxi, MIT licence (`Libs/json-LICENSE.txt`)
- **Questrial** by Joe Prince and Laura Meseguer, © 2011 The Questrial Project Authors, SIL Open Font License 1.1 (`Media/Fonts/Questrial-OFL.txt`). Included unmodified.
- That's My BIS and Raid-Helper are separate services. FableHub only reads the export text they produce.

FableHub's own code is released under the [MIT License](LICENSE). The bundled libraries and font keep their own licences, listed above.
