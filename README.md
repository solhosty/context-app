# Context for macOS

The first native build is a SwiftUI menu-bar app. It does not start a web server.

## Local test

1. Install the full Xcode app from the Mac App Store (or a matching Xcode release from Apple Developer), then point developer tools at it:

   ```sh
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   ```

2. From this folder, build and run the app:

   ```sh
   swift run ContextApp
   ```

3. Look for **Context** in the macOS menu bar. Choose a project folder with the folder button.

4. Verify the menu lists the project’s instruction files and its `.agents/skills`, `.codex/skills`, and `.claude/skills` packages.
   - Open **Effective context** to see the exact Codex instruction stack from global scope through the selected working folder, in load order.
   - Use **Compiled preview** to inspect the instruction messages Codex receives, including provenance headers.
   - Context flags repeated directives, direct conflicts, unavailable referenced skills, overrides, and oversized stacks without requiring a model.
   - Use **Simulate edit** to compare before and after, including token impact, before applying a snapshot-backed change.
   - Click an instruction file to open it in your default Markdown/text editor.
   - Open **Context** for the editor: instruction files, skill files, and plugin files can be edited in place. Context captures a local snapshot before each save and also shows Git history when the project has it.
   - Reveal any package in Finder when you need its full directory structure.
   - The instruction editor shows a transparent context-fit signal (estimated tokens and heading count); it is a size/structure check, not a claim that a model has judged the content correct.

## Build an app bundle

For a normal Finder-launchable local app instead of `swift run`:

```sh
./Scripts/build-app
open dist/Context.app
```

The bundle is locally ad-hoc signed. It is appropriate for this Mac only; distribution to other Macs needs Developer ID signing and notarization.

## Verification

Run the repeatable release gate before handoff:

```sh
./Scripts/verify-context
```

It runs the Swift behavior tests, checks every cross-harness fixture, builds the production app, and verifies its signature. To also launch the packaged app and verify it remains alive outside the invoking shell:

```sh
CONTEXT_VERIFY_LAUNCH=1 ./Scripts/verify-context
```

`CONTEXT_UI_TEST=1` and `CONTEXT_TEST_PROJECT=/path/to/fixture` expose a test-only normal window with stable accessibility identifiers. They are reserved for native UI automation; normal launches remain menubar-only.

## Choose a project

Use **Choose project** in the Context menu to select the folder you want to inspect. That explicit choice is the supported way to change projects.

For a keyboard or terminal workflow, Context also includes a small local manual switcher. From the project directory you want to inspect, run:

```sh
./Scripts/context-project use
```

The menubar app switches to that working folder within a second, resolves its Git root, and labels the source **Manual project switcher**. Keeping the working folder lets Context show the exact root-to-folder instruction stack. You can check or clear the selected path with `path` or `clear`.

This command does not observe Codex, Claude, Gemini, Finder, or any other app. It is only an explicit project-selection shortcut.

## Harness-aware inventory

Context inventories instruction formats instead of assuming every tool reads the same file:

- Shared agent instructions: `AGENTS.md` and `AGENTS.override.md`
- Claude: `CLAUDE.md` and `.claude/rules/`
- Gemini: `GEMINI.md`
- Cursor: `.cursor/rules/*.mdc` and legacy `.cursorrules`
- GitHub Copilot: `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md`
- Cline, Roo Code, Windsurf, and Continue rule directories/files when present

The full Context window lets you filter the inventory by harness. It also inventories skill packages and plugin packages from both project and global locations.

## Current boundary

Context does not infer the foreground project from Codex, Claude, Gemini, Finder, or another editor. Those apps do not expose a reliable foreground-project signal here. The project picker and manual switcher are deliberate, visible overrides rather than a misleading approximation of active-chat detection.
