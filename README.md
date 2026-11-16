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

## Releasing

A GitHub Actions workflow builds the addon zip and uploads it to GitHub, CurseForge and Wago when you push a version tag. Do these steps once, in order, before the first release.

1. Create a project for the addon on CurseForge and another on Wago. Note the project ID that each site gives you.
2. In the GitHub repository, open Settings > Secrets and variables > Actions and add two repository secrets: `CF_API_KEY` (your CurseForge API token) and `WAGO_API_TOKEN` (your Wago API token).
3. In Settings > Actions > General, set Workflow permissions to "Read and write permissions" and save. Without this the workflow cannot create the GitHub release.
4. In `ForeverFilter/ForeverFilter.toc`, replace the two placeholder lines with your real project IDs:
   - `## X-Curse-Project-ID: REPLACE_WITH_CURSEFORGE_PROJECT_ID`
   - `## X-Wago-ID: REPLACE_WITH_WAGO_PROJECT_ID`

   Commit and push this change.
5. Create the release tag and push it. The tag must be annotated, which means it is created with `-a` and a message. A plain lightweight tag will not work.

   ```
   git tag -a v1.0.0 -m "v1.0.0"
   git push origin v1.0.0
   ```

6. On the GitHub repository page, add topics (for example `warcraft-addon`, `world-of-warcraft`, `lua`) and upload a social preview image under Settings > General.
7. Ask for a listing on the WowUp Hub.

The WowUp Hub reads the GitHub release that the workflow creates. CurseForge covers WowUp-CF, so no extra step is needed for it.

## License

See [LICENSE](LICENSE).
