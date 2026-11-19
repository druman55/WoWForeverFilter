# Releasing Forever Filter

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

## Routine release

After the one-time setup above, each new version is:

1. Add a new `## vX.Y.Z` section at the top of `CHANGELOG.md`.
2. Run the tests with `lua tests/ui_checks_test.lua`.
3. Commit and push `main`.
4. Create and push an annotated tag:

   ```
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

The workflow in `.github/workflows/release.yml` builds the zip and uploads it.

## Project details

- CurseForge project ID: 1810309 (already set in `ForeverFilter.toc`).
- Wago project ID: nKWwMoKE (set in `ForeverFilter.toc`). The `WAGO_API_TOKEN` GitHub secret is set.
- Store text for the project pages is in `description.md`. The logo is `resources/icon/PNG/ForeverFilter_256.png`. Both are uploaded by hand on each site.

## Development

### Local deploy

On Windows, run `deploy.cmd` from the repository root to copy the `ForeverFilter` folder into your local retail install. It also fills in `@project-version@` in the deployed `.toc` with the newest version in `CHANGELOG.md`.

- `deploy.cmd -Flavor forever` or `-Flavor all` deploys to other installs under the default WoW folder.
- `deploy.cmd -AddOnsPath <path>`, or the `WOW_ADDONS_PATH` environment variable, deploys to a specific AddOns folder.

### Tests

Property tests are in `tests/ui_checks_test.lua`. They need a standalone Lua 5.1 or later interpreter. Run this from the repository root:

```
lua tests/ui_checks_test.lua
```

### Retail only

The `.toc` has `## AllowLoadGameType: mainline`, so the addon does not load in WoW Forever. Forever's SocialUI friends list rebuilds itself with a protected call (`C_BattleNet.SearchFriends`), which is blocked once an addon has edited the list. Filtering only works on the classic Friends List.

### Documentation rule

`README.md` is shown to players on CurseForge and Wago, so it only covers features, installation, usage, saved data and the license. Developer details, such as deploying, tests and release steps, go in this file.
