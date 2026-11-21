# FableHub 0.31.0

### Install
1. Close the game, then delete your old `Interface\AddOns\FableHub` folder.
2. Unzip so that `Interface\AddOns\FableHub\FableHub.toc` exists.
3. Your settings and guild data are kept.

It syncs with 0.30.0 as normal. Please update soon, because your guild's old data only comes back once you do.

### Fixed: guild data "reset" after the game patch on 21 November
- The game patch stopped telling addons the realm name, so FableHub started an empty copy of the guild's data. Professions, recipes, guild activity and the rest looked wiped. Nothing was actually lost.
- The first time you log in with this version, FableHub moves your saved guild data over to the new names, once, on your own computer. You'll see a short note in chat when it's done.
- Your own recipe lists come back straight away. Some guildmates' recipe lists only come back once they update too.
- Your old data is kept as a backup for 90 days.

### Fixed
- Two new error popups since the patch, about a "secret" value: the game now sometimes hides cooldowns and system chat lines from addons, and FableHub now leaves those alone.
