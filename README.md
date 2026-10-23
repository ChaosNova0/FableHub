# FableHub

**Guild management for WoW: Forever, built for the guild *Fable*.**

![Version](https://img.shields.io/badge/version-0.22.0-c9a26b) ![Client](https://img.shields.io/badge/client-WoW%3A%20Forever-555) ![Status](https://img.shields.io/badge/status-launch%20build-green) ![License](https://img.shields.io/badge/license-MIT-blue)

FableHub puts the guild's organisation in one in-game window: who's who, who can craft what, raid nights and sign-ups, raid groups, ready checks, loot priorities and the guild bank. Everything travels between guildmates over the game's hidden addon channel. There's no website, bot or account, and nothing leaves the game.

- **[Player guide](GUIDE.md)**: a walkthrough of every page
- **[Installation](#installation)** · **[Commands](#commands)** · **[For the Guild Master](#setting-up-for-the-guild-master)** · **[How sharing works](#how-sharing-works)**

---

## What's in it

### Home
The page FableHub opens on.
- **Raid banner** on raid days, with a soft glow, across the top: your sign-up (or buttons to sign up), your group in the night's raid plan, and what your last ready check said to bring or fix (flask, food, enchants). It shrinks to one line when you're all set and glows brighter in the last 30 minutes.
- Message of the Day, officer **announcements** (pinnable), a **guild activity** feed (level and profession milestones, new rare recipes, joins and leaves), recent loot, upcoming raids with one-click sign-up, craft requests you can make, open bank requests (officers) and who's online.
- A **Getting started** card lists any setup left for you, and disappears when it's done.

### Roster
- **Members**: level, rank, zone, notes, last seen, 30-day raid attendance and FableHub version.
- **Alts**: linked automatically from each player's own account and grouped under their main. Players pick their main; officers can fix links.

### Professions
- **Recipes**: every guildmate's recipes, searchable by recipe or crafted item, in rarity colours, highest item level first. Filter by gear slot, armour type and stats (all of them, or any).
- **Cooldowns**: transmutes, Mooncloth and the Salt Shaker next to each character, ready or with the time left. **Cooldown crafts** shows whose are ready across the guild.
- **Craft Requests**: ask the guild for an item; members who know the recipe are told. Claim, mark done, cancel.
- **Camping**: a camp guide (every profession's camp items and campfires) and a camp planner.

### Raids
- **Raid nights**: one-off or weekly, in everyone's own time zone, with sign-ups (Accepted, Late, Tentative, Declined), roles and notes. Attendance is recorded automatically. Officers can import sign-ups from **Raid-Helper** (Discord).
- **Raid plans**: drag-and-drop groups with party and raid buff coverage. **Make one straight from a raid night**: its Accepted and Late sign-ups become the member list (Tentative listed apart), with each person's character and role. People who later decline are flagged, never moved.
- **Ready check**: flasks or elixirs, food, other consumables, class buffs, blessings and enchants for the whole raid, at every ready check.

### Loot
- Imports **That's My BIS** prio lists and wishlists. Officers can add, reorder or remove entries, and their changes survive re-imports.
- Prio, wishlist and "already has it" in every item tooltip.
- An **award window** when an officer loots, and an automatic **loot history**.

### Guild Bank
- Every tab, gold and transaction logs, viewable from anywhere, refreshed whenever a member opens the bank.
- **Follows the guild's own tab permissions**: restricted tabs only reach ranks allowed to view them.
- Members can **request items**; officers hand them over or decline.

### Settings
Everything in one place (the cog in the title bar): alerts, minimap button, window opacity, officer ranks, and **feature permissions** (below).

Officers also get a **Change log**: the last 20 officer actions their FableHub has seen (permission and officer rank changes, raid nights, attendance fixes, That's My BIS imports, loot priority edits, removed loot, announcements, alt links set by hand, and bank requests handed over or declined), with who did it and when. It needs no extra addon messages, and changes made while you were offline show up once catch-up brings them in.

The window can be resized and every page adapts to its width. If [EllesmereUI](https://www.curseforge.com/wow/addons/ellesmereui) is installed, FableHub uses its accent colour.

---

## Installation

1. Download the latest `FableHub-x.y.z.zip` from **[Releases](../../releases)** (or get it from an officer).
2. Close the game.
3. Unzip it so the folder sits at
   `World of Warcraft\_forever_\Interface\AddOns\FableHub\FableHub.toc`
   (replace any older `FableHub` folder).
4. Start the game. On the character screen, open **AddOns** and make sure **FableHub** is ticked. If it's listed as out of date, tick **Load out of date AddOns**.
5. In game, type **`/fhub`**, then open each of your profession windows once so the guild can see your recipes.

FableHub is useful once a few guildmates have it, and more so once an officer does: officers record attendance and loot, and pass officer data on to people who log in later.

**Coming from the beta?** The first login with 0.19 or later clears the data FableHub saved during the beta (settings are kept) and says so in chat. It refills as guildmates log in.

---

## Commands

| Command | Does |
|---|---|
| `/fhub` | Open or close the window (the minimap button does the same) |
| `/fhub sync` | Ask the guild for anything you've missed |
| `/fhub scan` | Rescan your character (professions, talents) |
| `/fhub status` | What FableHub knows and who uses it |
| `/fhub minimap` | Show or hide the minimap button |
| `/fhub opacity 50-100` | Window opacity (default 85) |
| `/fhub resetwindow` | Put the window back in the middle at its default size |
| `/fhub bug` | A report to copy into Discord when something's wrong (version, client, name matching, traffic, recent errors) |
| `/fhub ping Name` | Test which spelling of a guildmate's name FableHub can whisper |
| `/fhub reset` | Clear stored guild data |

`/fablehub` works as well.

---

## Setting up (for the Guild Master)

1. **Officer ranks**: cog → Officers → *Officer ranks*. Ranks up to the one you pick are officers.
2. **Feature permissions** (optional): cog → Officers → *Feature permissions*. A grid of features and ranks where you tick who may use what:

   | Feature | Covers |
   |---|---|
   | Announcements | post, pin, delete |
   | Raid nights | create, edit, cancel; change anyone's sign-up; attendance; Raid-Helper import |
   | Raid plans | create, edit, share |
   | Loot | That's My BIS import, prio edits, award window, loot history |
   | Alts | link or unlink anyone's characters |
   | Bank requests | hand over or decline, officer alerts |
   | Craft requests | cancel anyone's request |
   | Ask the bank | ask for guild bank items (every rank by default) |

   Features you don't change follow the officer ranks. The Guild Master can always use everything.
3. **Open the guild bank once** with FableHub running, so it learns which ranks may view each tab.
4. **Officers: import That's My BIS** under Loot → Priorities.

---

## How sharing works

- **Each player shares only their own characters** (level, professions, recipes, talents, alts). Everyone stores what they hear, so offline members still show.
- **Catch-up:** when someone logs in, the online member with the newest FableHub sends them what they missed. A newer version only counts once an officer or two members run it. Officer data (raid nights, loot, announcements, raid plans, attendance) is passed on by an online officer allowed to use that feature.
- **Messages** are split into parts, throttled, and paused during combat and boss fights. A copy of something already waiting to be sent is skipped, and while a lot is waiting, catch-up answers wait their turn.
- **Connected realms:** Forever drops guild addon messages from characters on a connected realm. FableHub notices when its own messages don't come back and whispers other FableHub users instead. Characters are stored under the guild's home realm, so every client agrees on names.
- **Updates:** when an officer, or at least two guildmates, run a newer version, everyone else gets a chat message and a note in the sidebar.

### Trust and security

Every guildmate's FableHub checks what it receives, so these rules don't depend on hiding buttons:

- **Officer data** is accepted only when its author's rank may use that feature (officer ranks, or the Guild Master's feature permissions), and only straight from that author or passed on by someone allowed to use that feature.
- **Members' own data** (sign-ups, requests, bank reads, alt links) can only be changed by that member or an officer. Copies passed on by others only fill gaps, and sign-ups and alt links only from the member answering your catch-up. A link an officer set by hand stays until an officer changes it.
- **Self-correcting:** if anyone sends a newer copy of *your* record, sign-up or alt links than yours, your FableHub re-sends the real one so it wins everywhere.
- **Limits:** size limits per message type, a few half-received messages per sender, catch-up requests answered at most every 20 seconds per member, hellos answered at most 3 times in 5 minutes per member, text fields cut to their normal length, at most 10 open craft and 10 open bank requests per member, and nothing dated more than five minutes ahead.
- **Other safeguards:** addon whispers from outside the guild are ignored and WoW formatting codes are stripped from everything received. Restricted bank tabs are only whispered to ranks allowed to see them.
- **No internet:** addons can't reach it. The Raid-Helper and That's My BIS imports work by pasting their export text.

---

## Known limitations

- `## Interface: 16001` matched the Forever beta client. If the live client marks FableHub out of date, `/fhub bug` shows the value it expects.
- Players on a connected realm send one copy of each message per FableHub user online, so catch-up is slower for them.
- Guild bank contents are only as fresh as the last time someone with FableHub opened the bank, and a member who can view a tab could misreport it.
- Forged copies of your data are only corrected while you're online.
- Enchant checks on other players need an inspect, which only works within about 28 yards.

---

## Credits and licences

- **LibDeflate** by Haoqian He, zlib licence (`Libs/LibDeflate-LICENSE.txt`)
- **json.lua** by rxi, MIT licence (`Libs/json-LICENSE.txt`)
- **Questrial** by Joe Prince and Laura Meseguer, © 2011 The Questrial Project Authors, SIL Open Font License 1.1 (`Media/Fonts/Questrial-OFL.txt`), included unmodified
- That's My BIS and Raid-Helper are separate services; FableHub only reads the export text they produce.

FableHub's own code is released under the [MIT License](LICENSE).
