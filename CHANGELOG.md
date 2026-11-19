# Forever Filter

## v1.1.2

- **Retail only.** Forever Filter no longer loads in WoW Forever. Forever's friends list blocks its own refresh after an addon filters it, which caused an "action blocked" message and turned filtering off. Filtering in retail is unchanged.
- **New `/ff log` command.** Prints a short log of what the filter did this session, to help with bug reports.

## v1.1.1

- **Fixed: Friends List jumping to the top.** The Friends List no longer scrolls back to the top every few seconds when friends update. It also keeps your place when you change a game checkbox, the Offline option or the name filter. If the list gets shorter, it stops at the new bottom.

## v1.1.0

- **Separate name filter:** The name box is now its own small window above the Friends List, with a "Filter Friends" placeholder. The games window holds only the options and the games list.
- **Always Show Name Filter option:** New checkbox in the options, on by default. When on, the name filter shows whenever the Friends List is open. When off, it shows only while the games window is open.
- **Remembers your choice:** Whether the games window opens with the Friends List now follows your last choice, whether you used the Friends List icon button, the window's close button, `/ff` or the minimap button.

## v1.0.2

- **Wago:** Releases are now also published to Wago Addons.

## v1.0.1

- **Name filter:** Type in the new Name box to show only friends whose account name, BattleTag, character, realm or rich presence matches. It works together with the game checkboxes.
- **Icons:** The addon icon now appears on the filter window, on a button next to the Friends List close button (it also remembers whether the window opens with the Friends List), and on a minimap button. Use `/ff minimap` to show or hide the minimap button.
- **Closes with the Friends List:** The filter window now closes when the Friends List closes.
- **Debug:** `/ff debug` is now off at every login and is no longer saved.
- **Documentation:** Release notes moved out of the README.
## v1.0.0

First public release.

- **Game filter checkboxes:** Each game your online Battle.net friends are playing has its own row with a checkbox. Every game starts checked, and your choices are saved between sessions. Each WoW version (Retail, Classic and so on) gets its own row. Rows show the game and a friend count instead of a list of names.
- **Game list polish:** Games are sorted alphabetically. The window grows and shrinks to fit the list, in both height and width. Icons and header text are slightly larger, and each WoW row uses the same icon as the Friends List for that WoW version.
- **Attached to the social menu:** The window opens when you open the social menu and appears beside it, on the right or on the left if there is no room. You can drag it anywhere, and it then stays where you put it. Type `/ff reset` to return it to the default position. `/ff` still opens and closes the window by hand, and Escape closes it.
- **Window scale and options panel:** The window is a bit smaller by default (scale 0.85). Click the small icon next to the close button to open an options strip with a scale slider (0.5 to 1.5) and a checkbox to show or hide the player count on each game row. A "Reset to defaults" button restores the options. You can also set the scale with `/ff scale <number>`.
- **Friends list filter:** Unchecking a game hides the friends who are playing it from the Blizzard friends list, and checking it brings them back. Nothing is removed from your account. An **Offline** row hides or shows your offline Battle.net friends. A **Battle.net** row covers friends who are online only in the Battle.net app or mobile app. Friends who are in a game and in the app follow the game's checkbox.
