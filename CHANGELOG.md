# FableHub 0.31.1

### Install
1. Close the game, then delete your old `Interface\AddOns\FableHub` folder.
2. Unzip so that `Interface\AddOns\FableHub\FableHub.toc` exists.
3. Your settings and guild data are kept.

It syncs with 0.31.0 as normal.

### Fixed
- Craft requests that had been marked done or cancelled kept coming back as open. This happened when a guildmate who was offline at the time logged back in: their FableHub still had the old copy and shared it again. FableHub now remembers finished requests and turns those old copies away.
- The same could happen to guild bank requests that had been handed over, declined or cancelled. That's fixed too.
- If you were offline when a request was finished, it may still show as open for you until it expires. Guildmates who saw it finished won't take it back.
