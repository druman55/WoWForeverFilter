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
- Wago project ID: not set yet. Replace `REPLACE_WITH_WAGO_PROJECT_ID` in `ForeverFilter.toc` and add the `WAGO_API_TOKEN` secret.
- Store text for the project pages is in `description.md`. The logo is `resources/icon/PNG/ForeverFilter_256.png`. Both are uploaded by hand on each site.
- `deploy.cmd` copies the addon into a local WoW install and fills in the version from `CHANGELOG.md`.

