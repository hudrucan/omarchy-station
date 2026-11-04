# omastation

**Your [Omarchy](https://omarchy.org/) desktop, from anywhere. It feels like Windows RDP.**

Open Remote Desktop on your laptop, type your password, and you're at your desk: the same
windows and workspaces, fitted to the screen in front of you, with a pointer that never lags.
Disconnect and the desk locks before its screens come back on. Sit down at it later and sign
in: everything is where you left it.

No permission prompts, no second desktop, no unlocked screen glowing at your desk.

- **Your real session**, not a copy. Workspaces move to the client's screens and come back
  exactly as they were; the desk goes dark, its keyboard and mouse fenced, its speakers muted.
- **A pointer that never lags.** Your client draws it, as with Windows.
- **Fits any screen.** Size, DPI and monitors follow your client live, as you resize the window
  or drag it to another display.
- **Built for Omarchy.** It logs you into Omarchy's own lock screen and locks it when you leave,
  even after a crash. Sign in at the desk and the desk takes over.
- **Your keyboard, your bindings.** The client's layout is picked for you, Hyprland bindings
  and key repeat just work, and a Mac gets Option + drag for SUPER + drag.
- **Survives bad Wi-Fi.** Drop out and reconnect within 2 minutes: same session, desk still
  dark. Quality follows your bandwidth, and a still screen sharpens to pixel-perfect.
- **Windows clients just work**, because omastation speaks RDP the way Windows does.
- **And the rest:** sound and microphone, copy and paste with files, your client's drives in
  `~/RDP Drives`, RemoteApp, touch and pen.

## Get started

```sh
git clone https://github.com/realazizk/omastation
cd omastation/packaging/omastation && makepkg -si
cd ../hyprland && makepkg -si                            # the smooth pointer; log out and in after
omastation passwd                                        # your Linux login password
sudo systemctl enable --now omastation-helper@$(id -u)   # fences the desk's input
systemctl --user enable --now omastation                 # the server
sudo ufw allow omastation                                # port 3389, TCP and UDP
```

Then connect from any RDP client with your Linux user name and password.

`packaging/hyprland` is Arch's Hyprland plus omastation's cursor fix. Without it the pointer is
painted into the picture; Arch's next Hyprland update replaces it.

## Login before the desktop starts

`omastation --login` listens on port **3389** without a running desktop. After
NLA and PAM authenticate the listener's Unix owner, it reuses that user's sole
live Hyprland instance or starts `omastation-session@USER.service`. systemd
opens a PAM session on VT 8; the launcher activates that session before UWSM
starts Hyprland so it can acquire the GPU. Logout ends the desktop while the
listener keeps running. Disconnect keeps the desktop and locks it as usual.

This mode serves one Unix user per listener. It needs an accessible home and
credential store before login, UWSM, polkit, and a free VT 8. Multiple live
Hyprland instances are refused. NLA and PAM are mandatory. Disk/home encryption
must already be unlocked. Startup is limited to 40 seconds. Physical display
isolation during startup has not been verified on a machine with a monitor.

Install the built Arch package, then enable boot login as the desktop user:

```sh
sudo packaging/omastation/install-login "$(id -un)" /absolute/path/omastation-0.0.1-2-x86_64.pkg.tar.zst
```

The installer enables lingering, disables SDDM autologin, installs the narrow
polkit rule, disables the session-bound `omastation` service, and enables
`omastation-login`. Existing RDP connections briefly disconnect during rollout.
The original autologin configuration is saved in
`/var/lib/omastation/rollback/sddm-autologin.conf`. It does not reboot the host.
Keep SSH available for recovery. Use the existing firewall profile for TCP/UDP
3389; an SSH tunnel is not required when that port is reachable.

The polkit rule permits users to start only their own fixed desktop unit; RDP
connections still pass NLA and PAM. The listener and desktop run as the user.
The system unit and authorization rule must remain root-owned.

`--session-starter /absolute/executable` overrides startup. Its stdout contract
is two lines: Hyprland instance signature and Wayland socket basename. It runs
after authentication, as the listener owner, without passwords/client arguments.
Diagnostics go to stderr/the journal.

```sh
journalctl --user -u omastation-login
journalctl -u "omastation-session@$(id -un).service"
```

To return to session-bound remote access, disable `omastation-login`, restore
SDDM autologin from the saved configuration if desired, and enable `omastation`
in a running desktop. Do not run both listeners on the same port. Do not stop
the system session unit while its desktop contains work you need to keep.

## License

MIT, see [LICENSE](LICENSE).
