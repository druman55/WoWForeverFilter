# Forever Filter

## v1.0.0

First public release.

- **Game filter checkboxes:** Each game your online Battle.net friends are playing has its own row with a checkbox. Every game starts checked, and your choices are saved between sessions. Each WoW version (Retail, Classic and so on) gets its own row. Rows show the game and a friend count instead of a list of names.
- **Game list polish:** Games are sorted alphabetically. The window grows and shrinks to fit the list, in both height and width. Icons and header text are slightly larger, and each WoW row uses the same icon as the Friends List for that WoW version.
- **Attached to the social menu:** The window opens when you open the social menu and appears beside it, on the right or on the left if there is no room. You can drag it anywhere, and it then stays where you put it. Type `/ff reset` to return it to the default position. `/ff` still opens and closes the window by hand, and Escape closes it.
- **Window scale and options panel:** The window is a bit smaller by default (scale 0.85). Click the small icon next to the close button to open an options strip with a scale slider (0.5 to 1.5) and a checkbox to show or hide the player count on each game row. A "Reset to defaults" button restores the options. You can also set the scale with `/ff scale <number>`.
- **Friends list filter:** Unchecking a game hides the friends who are playing it from the Blizzard friends list, and checking it brings them back. Nothing is removed from your account. An **Offline** row hides or shows your offline Battle.net friends. A **Battle.net** row covers friends who are online only in the Battle.net app or mobile app. Friends who are in a game and in the app follow the game's checkbox.
