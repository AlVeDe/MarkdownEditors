# Building MarkdownEditor (Rust) on Windows, Linux and macOS (Apple Silicon)

The Rust version is a [Tauri 2](https://tauri.app) app. The Cargo workspace is in
`MarkdownEditorRust/src` and has two crates:

| Crate             | Folder      | Purpose                                         |
|-------------------|-------------|-------------------------------------------------|
| `mdcore`          | `src/core`  | Platform-independent logic, with unit tests     |
| `markdown-editor` | `src/app`   | Tauri shell (windows, menus, dialogs) and web UI |

Tauri bundles installers only for the OS it runs on, so build each platform on that
platform (or in CI, see the end of this file).

---

## 1. Common steps (all platforms)

1. Install Rust (stable) with [rustup](https://rustup.rs).
2. Install the Tauri CLI (version 2):

   ```sh
   cargo install tauri-cli --version "^2" --locked
   ```

3. Get the source and go to the workspace:

   ```sh
   git clone https://github.com/AlVeDe/MarkdownEditors.git
   cd MarkdownEditors/MarkdownEditorRust/src
   ```

Then do the setup for your platform below.

---

## 2. Windows (x64)

### Prerequisites

- **Microsoft C++ Build Tools**: install
  [Visual Studio Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
  and select the **"Desktop development with C++"** workload.
- **Rust MSVC toolchain** (the rustup default on Windows):

  ```powershell
  rustup default stable-msvc
  ```

- **WebView2 runtime**: already included in Windows 10 (current builds) and 11.

### Build

```powershell
cd MarkdownEditorRust\src
cargo test -p mdcore
cd app
cargo tauri build
```

On the first run, Tauri downloads WiX (for `.msi`) and NSIS (for `-setup.exe`).

### Output

```
MarkdownEditorRust\src\target\release\MarkdownEditor.exe
MarkdownEditorRust\src\target\release\bundle\msi\MarkdownEditor_2.3.0_x64_en-US.msi
MarkdownEditorRust\src\target\release\bundle\nsis\MarkdownEditor_2.3.0_x64-setup.exe
```

To build only one installer type: `cargo tauri build --bundles nsis` (or `msi`).

---

## 3. Linux (x86_64)

### Prerequisites

Install a C toolchain and the WebKitGTK 4.1 development packages.

**Debian / Ubuntu (22.04 or newer):**

```sh
sudo apt update
sudo apt install build-essential curl wget file libssl-dev libxdo-dev \
  libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
  librsvg2-dev patchelf
```

**Fedora:**

```sh
sudo dnf group install "c-development"
sudo dnf install webkit2gtk4.1-devel openssl-devel curl wget file \
  libappindicator-gtk3-devel librsvg2-devel libxdo-devel patchelf
```

**Arch Linux:**

```sh
sudo pacman -S --needed base-devel webkit2gtk-4.1 curl wget file openssl \
  libappindicator-gtk3 librsvg xdotool patchelf
```

### Build

```sh
cd MarkdownEditorRust/src
cargo test -p mdcore
cd app
cargo tauri build
```

The AppImage step downloads `linuxdeploy` on its first run, so you need internet
access.

### Output

```
MarkdownEditorRust/src/target/release/MarkdownEditor
MarkdownEditorRust/src/target/release/bundle/deb/MarkdownEditor_2.3.0_amd64.deb
MarkdownEditorRust/src/target/release/bundle/rpm/MarkdownEditor-2.3.0-1.x86_64.rpm
MarkdownEditorRust/src/target/release/bundle/appimage/MarkdownEditor_2.3.0_amd64.AppImage
```

To build only one format: `cargo tauri build --bundles deb` (or `rpm`, `appimage`).

---

## 4. macOS (Apple Silicon / ARM64)

### Prerequisites

- **Xcode Command Line Tools**:

  ```sh
  xcode-select --install
  ```

- **ARM64 Rust target** (already the default on an Apple Silicon Mac):

  ```sh
  rustup target add aarch64-apple-darwin
  ```

### Build

```sh
cd MarkdownEditorRust/src
cargo test -p mdcore
cd app
cargo tauri build --target aarch64-apple-darwin
```

### Output

```
MarkdownEditorRust/src/target/aarch64-apple-darwin/release/bundle/macos/MarkdownEditor.app
MarkdownEditorRust/src/target/aarch64-apple-darwin/release/bundle/dmg/MarkdownEditor_2.3.0_aarch64.dmg
```

The minimum macOS version is 10.15 (set in `src/app/tauri.conf.json`). In practice,
any Mac with Apple Silicon can run it.

### Optional: universal binary (ARM + Intel)

```sh
rustup target add x86_64-apple-darwin
cargo tauri build --target universal-apple-darwin
```

The output is in `target/universal-apple-darwin/release/bundle/`.

### Gatekeeper (unsigned builds)

Without an Apple Developer ID certificate the app is not signed or notarized, and
macOS blocks it when it is first opened on another Mac. To open it anyway:

- Right-click the app, choose **Open**, then confirm, or
- remove the quarantine flag:

  ```sh
  xattr -dr com.apple.quarantine /Applications/MarkdownEditor.app
  ```

To sign the app, set `APPLE_SIGNING_IDENTITY` (and, for notarization,
`APPLE_ID`, `APPLE_PASSWORD` and `APPLE_TEAM_ID`) before you run `cargo tauri build`.
For details, see the [Tauri macOS signing guide](https://tauri.app/distribute/sign/macos/).

---

## 5. Development and other commands

These commands work on every platform. Run them from `MarkdownEditorRust/src`.

| Task                          | Command                                               |
|-------------------------------|-------------------------------------------------------|
| Run core tests                | `cargo test -p mdcore`                                |
| Run the app (debug)           | `cargo run -p markdown-editor -- notes.md`            |
| Build release binary only     | `cargo build -p markdown-editor --release`            |
| Render Markdown to PDF (CLI)  | `cargo run -p mdcore --example render_pdf -- in.md out.pdf` |
| Debug build with installers   | `cd app && cargo tauri build --debug`                 |

The version number is set in two places, `src/Cargo.toml` (`workspace.package.version`)
and `src/app/tauri.conf.json` (`version`). Keep them the same.

---

## 6. Building all three platforms in CI

`.github/workflows/rust-app.yml` (at the repository root) runs the core tests and
`cargo tauri build` on `ubuntu-22.04`, `windows-latest` and `macos-latest`. The
`macos-latest` runners are Apple Silicon, so they build ARM64. The installers are
uploaded as the workflow artifacts `MarkdownEditor-Linux`, `MarkdownEditor-Windows`
and `MarkdownEditor-macOS`.

> **Note:** The workflow still uses the old path `src/MarkdownEditorRust`. In this
> repository the workspace is at `MarkdownEditorRust/src`. Update the `paths`,
> `working-directory`, `workspaces` and artifact `path` entries to that location
> before you use the workflow.

---

## 7. Troubleshooting

| Problem | Fix |
|---------|-----|
| `error: linker 'link.exe' not found` (Windows) | Install the C++ Build Tools workload (section 2). |
| `Package webkit2gtk-4.1 was not found` (Linux) | Install the WebKitGTK 4.1 dev package for your distro (section 3). Distros with only WebKitGTK 4.0 (Ubuntu 20.04 and older) are not supported by Tauri 2. |
| AppImage bundling fails | Check internet access and that `file` and `patchelf` are installed. Or build without it: `--bundles deb,rpm`. |
| `cargo tauri: no such command` | Install the CLI (section 1, step 2) and check that `~/.cargo/bin` is on your `PATH`. |
| "App is damaged and can't be opened" (macOS) | The quarantine flag is set on an unsigned app. See *Gatekeeper* in section 4. |
