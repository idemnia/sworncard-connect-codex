---
name: sworncard-setup
description: Set up a personal SwornCard connection in local Codex Desktop when the user asks to connect SwornCard, e.g. «Подключи SwornCard», or to update the PAT after rotation.
---

On macOS, after an explicit setup request, run `/usr/bin/ruby --disable-gems /absolute/path/to/this/skill/scripts/setup-macos.rb` once using the directory of this installed SKILL.md. Launch the helper yourself. The user enters their PAT in the system dialog, and can cancel. The helper takes no arguments. Do not collect the token, read the user's config, inspect the clipboard, invoke the dialog separately, or substitute a terminal command for this step.

After a confirmed save, use the personal SwornCard MCP tools if available. If needed ask the user to open a new chat or restart Codex to load the saved server. Verify the catalogue with `list_connections`. Installation or saving alone does not confirm access. For a personal/work ambiguity, ask for the intended connection. Cancellation ends setup.

On native Windows, the packaged MCP reads the current user's environment variable `SWORNCARD_CONNECT_PAT`. Direct the user to Windows **Edit environment variables for your account** and have them enter the PAT as the value there, then fully quit and reopen Codex. Never ask for the value in chat. This route uses one PAT for the bundled server and requires the native Windows host to receive the variable. For WSL/remote sessions explain that they have a separate environment.
