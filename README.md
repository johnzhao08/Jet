# Jet

Plain-file notes with git sync, for iPad and Mac.

- **Vault** = a folder that is also a git repository. Markdown notes are `.md`; handwritten notes are `.ink`.
- **iPad**: handwritten notes open straight into a PencilKit canvas. Pencil double-tap and squeeze follow
  Settings > Apple Pencil.
- **Mac**: edit Markdown, draw on handwritten notes and annotate PDFs with a mouse, trackpad or pen tablet.
- **Pens**: choose which tools are in the iPad tool picker, and their order (note's ••• menu →
  Pens & Tools): pen, monoline, fountain pen, highlighter, pencil, watercolor, crayon, eraser, ruler.
- **Pictures**: insert photos or image files into handwritten notes (under the ink; hold a finger on one
  to move, resize or delete it) and into Markdown notes (`![[name.png]]` at the cursor). They're saved
  in `Attachments/`; photos become JPEGs at most 2560 px.
- **Other files**: PDFs open on the handwriting canvas, so you can write on them with the same tools;
  the ink is kept in a hidden `.Name.pdf.ink` beside the PDF (which is never modified) and can be
  shared as an annotated copy. Text and code files (`.txt`, `.csv`, `.json`, …) open in a plain editor;
  everything else (pictures, Office/iWork documents, audio, video…) in Quick Look. Bring files in with
  New → Import Files…, or "Open in Jet" / share to Jet from other iPad apps.
- **Files from elsewhere**: drop files on the window (or on a sidebar folder) on Mac or iPad, or on the
  Mac open them with Jet from Finder (Open With, the Dock icon). A file already in a vault opens in
  place; anything else is copied in (contents only, not the original's permissions). Files over 100 MB are
  refused (GitHub won't take them, so sync would stop) and 50–100 MB files ask first. Apps and other
  bundles, folders Jet can't read (macOS keeps Downloads and Desktop private), folders of more than 1000
  files and folders containing the vault are refused.
- **Organizing**: click a folder to open it; the bar under "Files" shows the folder you're working in
  (new notes go there). Sort by Manual, Name, Date Modified or Kind, or Clean Up By one of them (the
  ⇅ menu). On the Mac, drag rows like Finder's list view: onto a folder to put it inside, between rows
  to reorder (switching to manual order), or beside top-level rows / below the list to move it out of
  a folder. On iPad, use a row's menu: Move to, Move Up, Move Down. Manual order is saved in
  `.jet/order.json`, so it syncs. PDF annotations move with their PDF.
- **Linking** (Obsidian-compatible): `[[wikilinks]]` (with `|alias` and `#heading`), backlinks and
  unlinked mentions under each note (one tap turns a mention into a link), `#tags` and `#nested/tags`
  (sidebar list, tap to filter, search `#tag`), YAML frontmatter properties (`tags`, `aliases` resolve links),
  a graph view of this note or the whole vault (⇧⌘G), and daily notes in `Daily/` (⇧⌘D) made from
  `Templates/Daily.md` with `{{date}}`, `{{title}}` and `{{weekday}}`. Quick open (⌘O) fuzzy-matches titles
  and aliases and puts recently opened notes first when the search is empty.
- **Search** combines full text with `path:Projects`, `tag:work`, `[status:active]`, `task-todo:review`,
  quoted phrases and `/regular expressions/`. Jet indexes changed notes locally, including text
  recognized in handwritten strokes. Recognized tags and wikilinks also appear in the graph and backlinks.
  Renaming or moving notes or folders updates references in Markdown files, including relative links.
- **Navigation and templates**: open Navigate → Command palette (⌘K) to find commands. Go back
  with ⌘[ and forward with ⌘]. Choose “New note from template” to use any Markdown note as a
  template in the current folder. Weekly and monthly notes use `Templates/Weekly.md` and
  `Templates/Monthly.md` when present. Weekly filenames follow ISO week numbering (e.g. `2026-W47`).
- **Markdown** supports link and tag completion, ⌘B and ⌘I, heading navigation, note and section
  embeds, tables, callouts, highlights, comments, footnotes, syntax colouring, math and Mermaid.
  The note toolbar includes font sizing, printing and PDF export.
- **Vault library** shows notes by property in a table or board, conflict copies and deleted notes
  recoverable from Git. Open a note’s history to restore a committed version.
- **iPad capture** accepts shared text, links and files. Widgets and Shortcuts can open quick capture
  or a daily note. Captures are queued locally until Jet can file them into the selected vault.
- **AI (Mac)**: Jet.app bundles `jet-mcp`, an MCP server that lets Claude, Claude Code, Codex
  (ChatGPT) or any MCP client list, read, search, link-check and edit a vault. Handwritten notes are
  sent as page images so the model reads the handwriting; PDFs as their text plus page images with any
  handwriting on them. It can create or move notes, update links and properties, edit or append text,
  and show note history and diffs. Set it up from the sidebar's ✨ button (or the ••• menu → Connect AI…), or by hand:
  `jet-mcp --vault <folder>`. The Mac app shows changes made by other programs live.
- **Sync**: commit, fetch, merge, push over HTTPS with a personal access token (no SSH).
  Two devices editing the same handwritten note are merged stroke by stroke; the same text note
  keeps your version and saves the other as a "conflict" copy.

## Run

iPad: open `Jet.xcodeproj`, choose the `Jet` scheme and your iPad, Run.

Mac: the `JetMac` target is a regular Mac app, signed to run on this Mac only.

```sh
./install-mac.sh   # build Release and install /Applications/Jet.app
./run-mac.sh       # build Debug and open it
```

## Release to TestFlight

```sh
./release.sh
```

Bumps the build number, commits and tags it, archives the iPad app, and uploads it to App Store Connect.
The app, share extension and widget extension use the same App Group. The signing team must have access to provision all three targets.
Testers in an internal TestFlight group with automatic distribution get it after Apple's processing.
`--no-upload` exports the signed `.ipa` to `build.noindex/export` instead.

## Test

```sh
./selftest.sh --https
```

Syncs two simulated devices through a local bare repository (fast-forward, merge, text conflict,
ink merge, deletion), and clones a public repository over HTTPS. Omit `--https` for the local checks,
including link updates, handwriting recognition, properties, Git history and Mac ink.
Run `./selftest.sh --markdown-reader-test` for the WebKit reader and PDF export,
`./graphcheck.sh` for graph filters and layout, and `swift test --package-path JetKit` for capture recovery.

Run the drag-and-drop UI regressions with Xcode and XcodeGen installed:

```sh
./ui-test.sh mac
./ui-test.sh ipad
```

The iPad command defaults to the iPad Pro 11-inch (M5) simulator. Pass another
`xcodebuild` destination as the second argument to select a different simulator.
The tests use isolated Debug vaults and exercise file moves, the command palette, Mac handwriting
and PDF annotation, and quick capture on iPad. Results, including failure screenshots and UI
hierarchies, are saved under `build.noindex/UIResults-*.xcresult`.

## Layout

- `JetKit/` Swift package with all app code (`AI/`, `Git/`, `Model/`, `Views/`)
- `Tools/jet-mcp/` the MCP helper's entry point
- `App/` the app target's entry point
- `Dev/` the self-test (runs without Xcode)
- `project.yml` XcodeGen spec for `Jet.xcodeproj`
