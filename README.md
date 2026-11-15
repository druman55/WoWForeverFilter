# Forever Filter

A World of Warcraft addon that groups your Battle.net friends by the game they are playing, so you can see at a glance who is on which game or WoW version.

## Features

- Lists each game your online Battle.net friends are playing, with its icon and a friend count.
- Shows a checkbox on every game row. Your choices are saved between sessions, and every game starts checked.
- Treats each WoW version (Retail, Classic and so on) as its own row with its own checkbox.

## Installation

1. Download or clone this repository.
2. Copy the `ForeverFilter` folder into `World of Warcraft\_retail_\Interface\AddOns\`.
3. Start the game, or type `/reload` if it is already running.

On Windows you can run `deploy.cmd` to copy the folder into a default WoW install for you.

## Usage

| Command | Action |
| --- | --- |
| `/ff` or `/foreverfilter` | Open or close the window |
| `/ff debug` | Toggle debug output, which adds project IDs to the game rows |

## Saved data

Settings are stored in the `ForeverFilterDB` saved variable.

## Tests

Property tests for the checkbox state logic are in `tests/ui_checks_test.lua`. They need a standalone Lua 5.1 or later interpreter. Run this from the repository root:

```
lua tests/ui_checks_test.lua
```

## License

See [LICENSE](LICENSE).
