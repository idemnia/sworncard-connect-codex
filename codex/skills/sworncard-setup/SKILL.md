---
name: sworncard-setup
description: Set up a personal SwornCard connection in local Codex Desktop when the user asks to connect SwornCard, e.g. «Подключи SwornCard», or to update the PAT after rotation.
---

On macOS, after an explicit setup request, run `/usr/bin/ruby --disable-gems /absolute/path/to/this/skill/scripts/setup-macos.rb` once using the directory of this installed SKILL.md. Launch the helper yourself. The user enters their PAT in the system dialog, and can cancel. The helper takes no arguments. Do not collect the token, read the user's config, inspect the clipboard, invoke the dialog separately, or substitute a terminal command for this step.

After a confirmed save, use the personal SwornCard MCP tools if available. If needed ask the user to open a new chat or restart Codex to load the saved server. Verify the catalogue with `list_connections`. Installation or saving alone does not confirm access. For a personal/work ambiguity, ask for the intended connection. Cancellation ends setup.

On native Windows, for the same explicit setup request, start the installed skill's `scripts/SwornCardSetup.exe` as the signed-in desktop user and wait for the window to close. The helper takes no arguments. If the app requests permission to open the window, let the user approve the normal launch. Use the official Idemnia package. The user pastes their PAT only into the masked field, selects «Сохранить», then «Готово». Exit 0 means saved, 1 means cancelled. Do not read config, collect a secret, or ask the user to configure environment variables. Use the catalogue check above. WSL, remote hosts and cloud tasks require opening a local native Windows Codex chat for setup.
