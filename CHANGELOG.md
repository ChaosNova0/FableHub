# FableHub 0.28.3

### Install
1. Close the game, then delete your old `Interface\AddOns\FableHub` folder.
2. Unzip so that `Interface\AddOns\FableHub\FableHub.toc` exists.
3. Your settings and guild data are kept.

It syncs with 0.27.x and 0.28.x as normal.

### Fixed
- Having FableHub's Home page open during a fight could cause a "FableHub tried to call the protected function" error. The game doesn't let addons read the guild message of the day in combat, so Home now shows the last one it read and catches up once the fight is over.
