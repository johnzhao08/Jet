# Jet

Plain-file notes with git sync, for iPad and Mac.

- **Vault** = a folder that is also a git repository. Markdown notes are `.md`; handwritten notes are `.ink`.
- **iPad**: handwritten notes open straight into a PencilKit canvas. Pencil double-tap and squeeze follow
  Settings > Apple Pencil.
- **Mac**: Markdown editing and reading; handwritten notes are view-only.
- **Sync**: commit, fetch, merge, push over HTTPS with a personal access token (no SSH).
  Two devices editing the same handwritten note are merged stroke by stroke; the same text note
  keeps your version and saves the other as a "conflict" copy.

## Run

iPad (needs Xcode): open `Jet.xcodeproj`, pick your team under Signing & Capabilities, choose your
iPad, Run. The Xcode target is iPad-only (it's what ships to the App Store); the Mac app builds from `Dev/`.

Mac without Xcode:

```sh
./run-mac.sh
```

## Test

```sh
./selftest.sh --https
```

Syncs two simulated devices through a local bare repository (fast-forward, merge, text conflict,
ink merge, deletion), and clones a public repository over HTTPS.

## Layout

- `JetKit/` Swift package with all app code (`Git/`, `Model/`, `Views/`)
- `App/` the app target's entry point
- `Dev/` Xcode-less Mac launcher and the self-test
- `project.yml` XcodeGen spec for `Jet.xcodeproj`
