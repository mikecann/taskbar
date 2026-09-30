# Working on taskbar

This is a macOS 13+ Swift/AppKit app. The Swift package under
`Sources/TaskbarApp` is the real app. The Python files are the original prototype,
kept for reference, with pure model and shell-script tests under `tests/`.

## Development rules

- Use test-first development for non-trivial changes. Write or update the test
  first; extract a test seam if the current code needs one.
- When behaviour, UI copy, layout, settings, startup or any tested contract
  changes, update affected tests and rerun them after implementation.
- Before committing, run `swift test` and
  `python3 -m unittest discover -s tests -v`. Check shell syntax with
  `bash -n` for each `.sh` file and the `taskbar` launcher.
- Keep source in this clone. `install.sh` only symlinks the launcher into
  `~/.local/bin` (or the requested directory); it must work from any directory.
- Preserve user settings, launchd labels, bundle identifiers and existing
  permission identities when changing installation or app staging.
- Keep UI designs free of eyebrows and kickers.
- Keep writing conversational and use no em dashes.
- PR descriptions start with `## Why` and explain what prompted the change.

## Build and launch

```bash
bash setup_mac.sh
bash install.sh
bash restart.sh
taskbar settings
taskbar stop
```

`restart.sh` builds, stops existing instances, stages and signs
`~/Applications/Mikerosoft Taskbar.app`, then launches it through launchd.
For permission and interaction testing, use that staged app, not the raw
`.build` executable. Keep its stable designated code-signing requirement.
After an app change, restart and check `~/Library/Logs/mikerosoft-taskbar.log`
for a clean startup; verify the actual interaction before claiming a UI fix.
Do not operate lights, change display modes or disable a display just to run
automated tests. CI must work without hardware, secrets or permission grants.

## App specifics

- Each monitor gets a panel. `TaskbarModel.swift` decides launch, restore and
  activate behaviour. Normal running windows stay active when clicked again.
- Settings use global defaults plus per-monitor overrides and widget settings.
- Window titles require Screen Recording permission; window manipulation and
  Dock badges require Accessibility. Elgato discovery requires Local Network.
- Prompter support comes from [prompter-kit](https://github.com/mikecann/prompter-kit).
  Keep the dependency remote in `Package.swift` and the product `PrompterKit`.
- The lights widget can open [record-it](https://github.com/mikecann/record-it)
  at `~/Applications/Record It.app`. This is optional and specific to Mike's setup.
- The lights widget can also change PA27JCV display scaling. Review those
  settings when adapting this tool to another setup.
- `kill.sh`, `open-settings.sh` and `restart.sh` share existing runtime paths;
  change them together if a migration is ever needed.
