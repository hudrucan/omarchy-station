# Omastation

Your [Omarchy](https://omarchy.org/) desktop over RDP. Reconnect to your existing
windows and workspaces, with screens and scaling fitted to the remote client.

[Install](#install) · [Use](#use) · [Configure](#configure) · [Development](#development)

- **Your existing session.** Workspaces move to remote outputs and return when you disconnect.
- **A private desk.** Remote takeover turns off physical monitors and fences local input;
  disconnect locks the desktop before restoring it.
- **Adaptive graphics.** Changed regions are sent to the client, with H.264 hardware encoding
  where available and lossless refinement when the screen settles.
- **Desktop integration.** Audio, microphone, clipboard and files, drive redirection,
  RemoteApp, touch and pen, subject to client capabilities.
- **Optional login before the desktop starts.** Authenticate first, then start or reuse your
  desktop through the separate [login integration](docs/login.md).

## Install

On Omarchy:

```sh
git clone https://github.com/hudrucan/omastation.git
cd omastation
./install-omarchy
```

The installer installs dependencies through Omarchy, sets up the pinned Zig
toolchain with mise, and builds and installs an Arch package through pacman.
Builds stay under `~/.cache/omastation`; packages stay under
`~/.local/share/omastation/packages`. The checkout contains source only.

Omastation installs to `/usr` because its helper, systemd units and plugin rebuild
hook use system paths. Installing the package does not enable remote access;
follow the steps below.

<details>
<summary><strong>Optional Hyprland cursor patch</strong></summary>

The included Hyprland patch fixes cursor-image capture so the RDP client can draw
the pointer separately from desktop frames. Without the fix, Omastation can fall
back to painting the cursor into the picture.

```sh
make hyprland-package MAKEPKG_FLAGS=--install
```

This builds and replaces the installed Hyprland with the version in
`packaging/hyprland/PKGBUILD`. Log out and back in afterwards. A later Arch
Hyprland upgrade can replace the patch; this build is independent of normal
Omastation development.

</details>

## Use

From an existing Hyprland session:

```sh
omastation passwd
sudo systemctl enable --now "omastation-helper@$(id -u)"
systemctl --user enable --now omastation
```

Use your Linux login password when saving the RDP credentials. Connect an RDP
client to this machine on port **3389**, using your Linux user name and password.
If you use UFW, the package provides a profile:

```sh
sudo ufw allow omastation
```

The session-bound service needs a running Hyprland desktop. For remote login
before the desktop starts, use [on-demand login](docs/login.md); it replaces the
session-bound listener on the same port.

For clipboard file transfers, copy files or folders in Finder/Explorer and paste
them into Files on the remote desktop. Folder contents and empty subfolders are
preserved. The client must support clipboard file streaming; copied image data
uses the separate image clipboard formats.

## Configure

`omastation --help` lists server options. The packaged service runs
`omastation --desktop`; the optional login service runs `omastation --login`.
Client monitor size, scale and layout are negotiated on connection.

Desktop capture uses linear DMA-BUF buffers when supported by the compositor and
GPU, with shared-memory fallback. AVC420 updates can import these buffers directly
into VA-API, including partial updates when all changes to the H.264 source fit
inside their selected macroblocks. Other mixed updates and refinement preserve
the previous source outside those blocks. Text and UI keep their existing codec
policy. Use `--no-dmabuf` to force shared-memory capture when troubleshooting.

The native plugin is compiled against the installed Hyprland headers and build
ID. Its package hook rebuilds it after Hyprland upgrades. Log in again after an
upgrade so the running compositor matches the installed files.

<details>
<summary><strong>Update and troubleshoot</strong></summary>

From your checkout:

```sh
git pull --ff-only
./install-omarchy
```

Inspect the active service:

```sh
journalctl --user -u omastation
journalctl -u "omastation-helper@$(id -u)"
```

For the optional boot listener, use `journalctl --user -u omastation-login`.
Rebuilding and installing a package does not rebuild the patched compositor.

</details>

## Development

The server is written in Zig, with a C++ Hyprland plugin. Build/check commands
live at the repository root and generated files stay outside the source checkout.

```sh
mise trust
mise install
make build
make check
```

`make build` builds the server. `make check` also compiles the plugin for the
installed Hyprland, checks Zig formatting and shell syntax, and runs Zig unit
tests and the desktop-start integration tests without changing live services.
Use `make plugin`, `make bench`, `make package` or `make install` for those tasks.

See [building and packaging](docs/build.md) for dependencies, cache locations,
parallelism and package snapshots. `make package` includes current source changes;
you do not need to commit them first.

This is a fork of [realazizk/omastation](https://github.com/realazizk/omastation).
Original MIT copyright is retained. Found a bug? [Open an issue](https://github.com/hudrucan/omastation/issues)
with your Omarchy, Hyprland and RDP client versions and steps to reproduce.

[MIT license](LICENSE)
