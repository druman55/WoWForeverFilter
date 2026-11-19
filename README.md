# Forever Filter

A retail World of Warcraft addon that groups your Battle.net friends by the game they are playing, so you can see at a glance who is on which game or WoW version.

## Features

- Lists each game your online Battle.net friends are playing, with its icon and a friend count.
- Shows a checkbox on every game row. Your choices are saved between sessions, and every game starts checked.
- Treats each WoW version (Retail, Classic and so on) as its own row with its own checkbox.

## Installation

1. Download or clone this repository.
2. Copy the `ForeverFilter` folder into `World of Warcraft\_retail_\Interface\AddOns\`.
3. Start the game, or type `/reload` if it is already running.

## Usage

| Command | Action |
| --- | --- |
| `/ff` or `/foreverfilter` | Open or close the window |
| `/ff debug` | Toggle debug output, which adds project IDs to the game rows |
| `/ff log` | Print the filter's session log, for bug reports |

## Saved data

Settings are stored in the `ForeverFilterDB` saved variable.

## License

Forever Filter is released under the MIT License. See the [LICENSE](https://github.com/druman55/WoWForeverFilter/blob/main/LICENSE) file for the full text.
