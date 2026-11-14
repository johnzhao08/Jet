# Jet

Plain-file notes with git sync, for iPad and Mac.

- **Vault** = a folder that is also a git repository. Markdown notes are `.md`; handwritten notes are `.ink`.
- **iPad**: handwritten notes open straight into a PencilKit canvas. Pencil double-tap and squeeze follow
  Settings > Apple Pencil.
- **Mac**: Markdown editing and reading; handwritten notes are view-only.
- **Linking** (Obsidian-compatible): `[[wikilinks]]` (with `|alias` and `#heading`), backlinks and
  unlinked mentions under each note (one tap turns a mention into a link), `#tags` and `#nested/tags`
  (sidebar list, tap to filter, search `#tag`), YAML frontmatter properties (`tags`, `aliases` resolve links),
  a graph view of this note or the whole vault (⇧⌘G), and daily notes in `Daily/` (⇧⌘D) made from
  `Templates/Daily.md` with `{{date}}`, `{{title}}` and `{{weekday}}`. Quick open (⌘O) fuzzy-matches titles
  and aliases and creates the note if it doesn't exist.
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

- `JetKit/` Swift package with all app code (`Git/`, `Model/`, `Views/`)
- `App/` the app target's entry point
- `Dev/` the self-test (runs without Xcode)
- `project.yml` XcodeGen spec for `Jet.xcodeproj`
