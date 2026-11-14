# Jet

Plain-file notes with git sync, for iPad and Mac.

- **Vault** = a folder that is also a git repository. Markdown notes are `.md`; handwritten notes are `.ink`.
- **iPad**: handwritten notes open straight into a PencilKit canvas. Pencil double-tap and squeeze follow
  Settings > Apple Pencil.
- **Mac**: Markdown editing and reading; handwritten notes are view-only.
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
- **Organizing**: drag files and folders onto a folder in the sidebar (or onto "Files" for the top
  level), or use Move to in a file's menu. PDF annotations move with their PDF.
- **Linking** (Obsidian-compatible): `[[wikilinks]]` (with `|alias` and `#heading`), backlinks and
  unlinked mentions under each note (one tap turns a mention into a link), `#tags` and `#nested/tags`
  (sidebar list, tap to filter, search `#tag`), YAML frontmatter properties (`tags`, `aliases` resolve links),
  a graph view of this note or the whole vault (⇧⌘G), and daily notes in `Daily/` (⇧⌘D) made from
  `Templates/Daily.md` with `{{date}}`, `{{title}}` and `{{weekday}}`. Quick open (⌘O) fuzzy-matches titles
  and aliases and creates the note if it doesn't exist.
- **AI (Mac)**: Jet.app bundles `jet-mcp`, an MCP server that lets Claude, Claude Code, Codex
  (ChatGPT) or any MCP client list, read, search, link-check and edit a vault. Handwritten notes are
  sent as page images so the model reads the handwriting; PDFs as their text plus page images with any
  handwriting on them. It can create notes, edit text and append,
  never delete. Set it up from the sidebar's ✨ button (or the ••• menu → Connect AI…), or by hand:
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
Testers in an internal TestFlight group with automatic distribution get it after Apple's processing.
`--no-upload` exports the signed `.ipa` to `build/export` instead.

## Test

```sh
./selftest.sh --https
```

Syncs two simulated devices through a local bare repository (fast-forward, merge, text conflict,
ink merge, deletion), and clones a public repository over HTTPS.

## Layout

- `JetKit/` Swift package with all app code (`AI/`, `Git/`, `Model/`, `Views/`)
- `Tools/jet-mcp/` the MCP helper's entry point
- `App/` the app target's entry point
- `Dev/` the self-test (runs without Xcode)
- `project.yml` XcodeGen spec for `Jet.xcodeproj`
