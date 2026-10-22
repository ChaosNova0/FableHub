# FableHub 0.21.0

Guild roster and profession tracker for WoW: Forever.

## Install
1. Close WoW.
2. Unzip so the `FableHub` folder sits in your Forever game folder under `Interface\AddOns\`
   (for example `World of Warcraft\_forever_\Interface\AddOns\FableHub\FableHub.toc`).
3. Start the game. On the character screen, open **AddOns** and make sure FableHub is ticked.
   If it says "Out of date", tick **Load out of date AddOns**.

## Use
- `/fhub` or the minimap button opens the window. Drag the title bar to move it and the bottom-right corner to resize it. If the sidebar doesn't fit, scroll it with the mouse wheel. If a table is wider than the window, a thin bar appears under it: drag it, or hold Shift and use the mouse wheel, to scroll sideways. Pages adjust to the window's width: toolbar buttons wrap onto another row, search boxes shrink, side lists narrow, and Settings puts its second column underneath (scroll with the mouse wheel).
- **Home** (where FableHub opens each session; after that it reopens where you left off):
  - **Raid banner**: on a raid day (from midnight, or 12 hours before) until the raid ends, a glowing banner across the top shows the raid and when it starts, with:
    - **Your sign-up** (status, character, role; Change opens Raid nights). Not signed up yet? Accept / Late / Tentative / Decline right there.
    - **Your group** in the night's raid plan, your groupmates and the group's party buffs (once officers have made a plan from the raid night).
    - **Bring / fix**: what your last ready check (or **Check now**) found missing on you: flask or elixirs, food, unenchanted gear. Checks over a week old are ignored.
    - **Raid plan** opens the night's plan.
    - When you're signed up and nothing needs fixing it shrinks to one line. Click its title to shrink it yourself. In the last 30 minutes it glows brighter and stays open.
  - Message of the Day, Announcements, Recent loot, Bank requests (officers only), Upcoming raids (with Accept / Late / Tentative / Decline for the next raid night), Crafting requests (ones you can craft and your own) and who's online.
  - **Guild activity**: level milestones (10/20/30/40/50/60), profession milestones (150/225/300), new recipes for rare or better items, members joining or leaving, raid nights scheduled and crafting requests completed. Kept for 30 days; only changes after installing are shown.
  - Cards shrink to fit what's in them; click a card's title to collapse or expand it (remembered).
  - **Getting started** appears at the top while there's setup left: professions whose recipes FableHub hasn't read yet, and for the Guild Master, choosing officer ranks and opening the guild bank once. Each tip goes away when it's done; **Hide** (or Settings) turns the card off.
  - Officers post announcements with **+ Post**. They disappear after 14 days unless pinned; right-click one to pin, unpin or delete it.
- **Roster** (sidebar section with Members and Alts):
  - **Members**: every guild member with level, rank, zone, note and last seen. Hover for details, right-click to whisper.
  - **Alts**: each player's main with their alts underneath (click a main to show or hide them). Alts link automatically: when someone logs in with FableHub, it knows every character on their account and tells the guild. Characters with nobody linked are under "Not linked".
    - **My main** picks which of your characters is your main (your highest level until you choose). Or right-click your own character.
    - Officers right-click any character to link it as an alt of someone (pick the main from a searchable guild list), unlink it, or make it the main. An officer's change stays until that player changes their own main or logs in a new alt.
- **Professions** (sidebar section with Recipes, Craft Requests, and Camping, which holds Camp guide and Camp planner)
- **Professions > Recipes**: pick a profession on the left (or All). Professions are grouped into Crafting, Gathering and Secondary; only Crafting shows unless you tick "Show gathering" or "Show secondary".
  - *Recipes*: one row per character. Click a name to expand their recipes. Recipes show the crafted item's name and icon in its rarity colour (enchants keep the recipe name); hover for the recipe. Searching (recipe or item name) expands matches automatically. Recipes are sorted highest item level first within each profession; the toolbar button switches to A to Z.
    Shift-click a recipe to link it; right-click to whisper a crafter.
  - *Crafters*: everyone with that profession, by skill.
- **Raids** (sidebar section; click to open or close it):
- **Raids > Raid plans**: build raid plans (10, 20 or 40 players).
  - Officers drag members from the pool into groups, or click a member then click a slot. Right-click removes; Ctrl-click changes role.
  - Each group shows its party buffs (totems, auras, shouts). The bottom shows raid buffs, boss debuffs and utility: lit = covered.
  - Spec and buffs are detected from each member's talents and spellbook. Members without FableHub are assumed to have their class's standard buffs.
  - **From raid night** (officers) makes a plan from a raid night's sign-ups; so does **Make raid plan** on the raid night itself (which then becomes **Raid plan** and opens it).
    - The member list shows only the night's Accepted and Late sign-ups (sorted tanks, healers, melee, ranged), with Tentative listed apart underneath. Untick **Signed up** to see the whole guild again.
    - Each person comes with the character and role they signed up with. The plan is sized 10, 20 or 40 for how many are coming.
    - New sign-ups appear in the list as they come in. Anyone already placed who later declines, goes Tentative or withdraws gets a red "!" (hover for why) and a count in the status line; nobody is moved for you.
    - **From raid night > Unlink** turns it back into an ordinary plan.
  - Plans are saved; **Share** sends one to the guild. The Guild Master chooses which ranks count as officers.
  - Players not in the guild can be added by name and class.
  - The buff list lives in `Data/Buffs.lua` and can be edited as Forever's classes change.
- **Raids > Raid nights**: officers create one-off or weekly raid nights (shown in everyone's own time zone).
  - Every field can be typed. Day: `21/10`, `21 Oct`, `tomorrow`, `tue` (or pick from the calendar). Start: `20:00`, `8pm`, `8:30 pm` (or pick from the 15-minute list). Length: `3h`, `2h30`, `2:30`, `90m`.
  - **Copy** makes a new raid night with the same settings; just pick the new date.
  - **Import Raid-Helper** (officers): on raid-helper.dev, open the event and copy its JSON export, paste it in and click **Read**.
    - Each Discord name is matched to a guild character (exact name first, then ignoring punctuation; partial matches are flagged "guess, check"). Click anyone to pick their character from a guild list that filters as you type (click a name or press Enter for the top one); FableHub remembers it for next time and shares it with other officers. Right-click to ignore someone or forget a link.
    - Accepted, Late, Tentative and Absence (Declined) carry over with role; Bench becomes Tentative with a "Bench" note; other notes are left blank (Raid-Helper exports have none). Hover a sign-up to see if it came from Raid-Helper. People who can't be matched are skipped.
    - It goes onto the raid night that starts within 2 hours of the event, or creates one (3 hours long unless the export says otherwise). **Choose raid night** puts the sign-ups on any raid night from the last week or next 4 weeks instead.
    - Events dated more than a year away (a placeholder or a typo'd year) never create a raid night: pick one with Choose raid night. Raid nights dated more than 2 years ahead are deleted automatically when an officer logs in. After importing, FableHub opens the raid night (switching to past nights if needed).
    - Each sign-up keeps the time it was made in Discord, so whichever answer is newer (Raid-Helper or in game) wins. Import again any time to pick up new sign-ups.
  - Members sign up as Accepted, Late, Tentative or Declined, choose which of their characters and what role, and can leave a note.
  - **Officers: right-click anyone** on a raid night's list to change their answer (Accepted, Late, Tentative, Declined, or clear it), their role, or their note, including people who haven't replied. Hovering shows who made the change.
  - Past nights show attendance, recorded automatically while an officer with FableHub is in the raid. Officers can click to correct it.
  - The Roster shows each member's attendance over the last 30 days.
  - You get a chat reminder if a raid night is within 24 hours and you haven't signed up.
- **Raids > Ready check**: every time a ready check starts, FableHub looks at everyone in your raid or party (anyone can use it; nothing is sent to the guild).
  - Columns: flask (or two elixirs), food, other consumables (juju, Zanza, scrolls...), class buffs (Fortitude, Mark of the Wild, Arcane Intellect; Spirit and Shadow Protection shown but not required), paladin blessings (one per paladin, up to 4) and enchants.
  - A class buff is only expected if someone in the group can cast it. Hover a player for exactly what they have and which enchants are missing.
  - Enchants need an inspect, which only works within about 28 yards: far-away players show a "?" until you click **Re-inspect gear** near them.
  - **Check now** runs it without a ready check. **Only show problems** hides players who are ready. Buffs are checked again when the ready check ends, for people who buffed during it.
  - The consumables, required class buffs and enchant slots are listed in `Data/Consumables.lua`, so they're easy to change for Forever.
- **Loot** (sidebar section):
  - **Priorities**: officers import the Gargul export from That's My BIS (prio lists and wishlists) and it's shared with the guild. Pick a member on the left to see every item on their lists, with prio order, wishlist order and whether they have it. An Items view shows it the other way round.
  - **Add item to a list** (officers): search an item by name or ID (or shift-click it), pick any guild member, choose Prio or Wishlist and the order. These entries survive re-importing from That's My BIS, and override that person's imported entry for the same list.
  - **Removing**: right-click an item in a member's reading pane (or in the Add window) to take it off their prio list or wishlist. This works for imported entries too, and removals stick when you re-import; add the item again to bring it back.
  - Every item tooltip in game shows its prio order, wishlist, and who already received it.
  - **Award window**: opens when an officer loots in a raid. Pick an item, see candidates in prio then wishlist order with attendance and recent loot, and click Award. It's recorded and announced in raid chat. Hand the item over by trade or master loot as usual.
  - **Loot history**: epic drops are recorded automatically while an officer with FableHub is in the raid. Officers can add entries (shift-click an item) or right-click to delete. Everyone can see it.
- **Professions > Craft Requests**: ask the guild to craft something.
  - **New request** searches recipes known in the guild (by item or recipe name, or shift-click an item), then set how many, your mats (all / some / none) and a note. Or right-click any recipe on the Recipes page and choose "Request this from the guild".
  - Members who know the recipe get a chat message, a reminder at login, and a count on the minimap button.
  - Click a request to claim it ("I'll craft this"), mark it done, un-claim, cancel or whisper. Finished requests clear after 30 minutes; open ones expire after 7 days. Officers can cancel anything.
- **Professions > Camping > Camp guide** and **Camp planner**:
  - **Camp guide**: click a profession's heading to show or hide it (remembered); **Collapse all / Expand all** at the top right; searching shows everything. Every profession's camp items (3 tiers each) and the campfires, with skill needed, what they give, the class buff they don't stack with, and how many guildmates can make them. Hover for names.
  - **Camp planner**: saved camp plans. Pick a campfire size (3, 5 or 10 slots), who lights it, and for each slot an item and who brings it. FableHub flags missing skill, the same player twice (each player can place one item) and two items from one profession, lists what the camp gives, and marks buffs your group (or a raid plan) already gets from a class. **Post to chat** sends it to party, raid or guild chat only when you choose a channel.
  - Camp item data lives in `Features/Camping.lua`; most values aren't published yet, so it's easy to update.
- **Guild Bank** (sidebar section with Contents and Requests): see the guild bank without going to a banker.
  - Addons can only read the bank while it's open, so whenever any member opens the guild bank in game, their FableHub reads the tabs they can see and shares them. "Last read 2h ago by Bob" shows how fresh it is.
  - **Follows the guild's own tab permissions.** The Guild Master's FableHub reads which ranks may view each tab (the Guild Master needs to open the guild bank once with FableHub). Tabs every rank may view go to everyone; restricted tabs are sent privately only to members whose rank may view them, so other members' FableHub never receives them. Before the Guild Master's first visit, a tab only goes to the same rank or higher than whoever read it.
  - **Contents > Items**: pick a tab on the left to see its slots like in game (hover for the tooltip, shift-click to link). **Search all tabs** finds an item across every tab you can see, with totals.
  - **Gold** balance at the top, and a **Log** view with the recent deposits, withdrawals and moves the game keeps for each tab, plus the gold log.
  - **Requests** (its own page): right-click any item on Contents to ask for it (how many, optional note). Officers get a chat message (can be turned off in Settings) and right-click a request to mark it handed over or decline it; you get a message when yours is handled, and can cancel it. Finished requests clear after 7 days. Officers also see open bank requests on Home (the Bank requests card), where they can right-click to hand over or decline.
- **Settings** (the cog next to the close button; click it again to go back): every option in one place, saved for your whole account.
  - General: minimap button, open on Home each session, window opacity, reset window.
  - Alerts in chat (each can be turned off): raid nights you haven't signed up for, new craft requests you can make, open requests at login, your request claimed or done, and the request count on the minimap button.
  - Raids: run the ready check automatically.
  - Officers: officer ranks (Guild Master), feature permissions, announce awarded loot in raid chat, and **Change log** (officers only): the last 20 officer changes, who made them and when. Several edits of the same kind by one officer within 5 minutes show as one line.
  - **Feature permissions** (button under Officers): a grid of features and guild ranks. The Guild Master ticks which ranks may use each one: Announcements, Raid nights, Raid plans, Loot, Alts, Bank requests (handing over / declining), Craft requests (cancelling anyone's), and Ask the bank (asking for guild bank items). Hover a feature for exactly what it covers. A feature the Guild Master hasn't changed follows the officer ranks setting (Ask the bank: every rank); **Reset** puts one back, **Reset all** puts them all back. The Guild Master can always use everything. Everyone else can look at the grid but not change it. It's checked by every guildmate's FableHub, not just by hiding buttons.
  - Data: sync now, rescan your character, clear stored guild data (click twice).
- If EllesmereUI is installed, FableHub uses its accent colour.
- **Open each of your profession windows once** after installing so your recipes are shared.
  Skill levels share automatically.

## Commands
`/fhub minimap` show or hide the minimap button · `/fhub resetwindow` · `/fhub opacity 50-100` window see-through-ness (default 85) · `/fhub sync` resync · `/fhub scan` rescan your character · `/fhub status` · `/fhub bug` a report to copy into Discord when something's wrong · `/fhub ping Name` test which spelling of a name FableHub can whisper (works even if they don't have FableHub) · `/fhub reset` clear stored guild data

When guildmates run a newer FableHub, you'll get a chat message and the sidebar shows **update** next to the version.

## Credits
Bundles LibDeflate (zlib licence) and rxi/json.lua (MIT) to read That's My BIS exports; licences are in the Libs folder. The font is Questrial (SIL Open Font License; licence in Media/Fonts).

## How sharing works
Each player's addon shares only their own character with the guild, over the hidden addon channel.
Everyone stores what they hear, so you can still see an offline member's professions.
Nothing is sent during combat or boss fights.
Officer data (raid nights, loot, announcements, raid plans, attendance) is only accepted from officers, so someone logging in later receives it once an officer with FableHub is online.
Addon messages from players outside the guild are ignored, and formatting codes are stripped from anything received.
Characters on a connected realm can't be heard on the guild's addon channel, so their FableHub notices and whispers other FableHub users instead. Nothing to set up.

## Coming from the beta
The first time you log in with 0.19 or later, FableHub clears the guild data and character records it saved during the beta (your settings stay) and says so in chat. Open each profession window once again so your recipes are shared. Guildmates still on a beta version can't send old data in; they're told to update instead.
