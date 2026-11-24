# FableHub 0.31.2

### Install
1. Close the game, then delete your old `Interface\AddOns\FableHub` folder.
2. Unzip so that `Interface\AddOns\FableHub\FableHub.toc` exists.
3. Your settings and guild data are kept.

It syncs with 0.31.x as normal.

### Fixed
- Some cancelled or finished craft requests still came back after 0.31.1. This happened when the request had already come back once: cancelling it again wasn't remembered, so it could keep returning. Your own cancel or done is now always remembered.
- The same fix applies to guild bank requests you hand over, decline or cancel.
- A request you cancelled before 0.31.1 can still come back once. Cancel it again and it will stay gone.
