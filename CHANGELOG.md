# FableHub 0.28.2

### Install
1. Close the game, then delete your old `Interface\AddOns\FableHub` folder.
2. Unzip so that `Interface\AddOns\FableHub\FableHub.toc` exists.
3. Your settings and guild data are kept.

It syncs with 0.27.x and 0.28.x as normal.

### Fixed
- Chat could fill up with "No player named '...' is currently playing." over and over. FableHub was trying to reach a guildmate who'd logged off, and the game spelled their name back differently from how FableHub sent it, so FableHub didn't recognise the message. It now hides that line and stops retrying that spelling.
