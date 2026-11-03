# FableHub 0.27.0

### Install
1. Close the game, then delete your old `Interface\AddOns\FableHub` folder.
2. Unzip so that `Interface\AddOns\FableHub\FableHub.toc` exists.
3. Your settings and guild data are kept.

It syncs with 0.26.x as normal. You need 0.27.0 to get roll popups.

### New: rolling for loot
- **For the master looter (officers):** the award window opens by itself when you loot a boss as master looter, and only then.
  - **Start roll** asks the raid for `/roll 100` (main spec) or `/roll 99` (off spec). It counts down, warns at 5 seconds and closes by itself. The roll length is in Settings > Officers.
  - Rolls are listed main spec first, then off spec, highest first, next to everyone's prio list, wishlist, attendance and recent loot. Ties are marked, and only someone's first roll counts.
  - Pick the winner and click **Give to**, then click again to confirm. FableHub hands the item over through master loot, then records and announces it once it has really left the loot window.
- **Roll popups for everyone:** when an officer starts a roll, you get a small window with the item, a countdown, your prio or wishlist spot (or "You already have it"), and **Main spec**, **Off spec** and **Pass** buttons. The buttons do a normal /roll, and Pass just closes the window. Drag it where you like; `/fhub testroll` shows a sample. Typing /roll still works too.
- **Pugs** in the raid can roll and be given loot. In a pug raid (less than half the raid is guild), loot isn't added to the guild's loot history.

### New: settings for other loot addons
If the guild uses another loot addon such as Gargul, you can turn FableHub's parts off:
- Settings > Officers > **Award window when I'm master looter**
- Settings > Loot > **Prio lists in item tooltips** and **Show roll popups**

Loot history is still recorded in guild raids either way.

### Fixed
- The award window no longer pops up for every officer who loots a corpse. It's for the master looter only.
- Someone from another realm, or a pug who shares a guild member's name, is no longer mistaken for that guild member. Their loot and raid attendance used to be credited to the guild member.
