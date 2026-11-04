# Login before the desktop starts

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

Build a package with `make package` and save credentials with `omastation passwd`.
Enable boot login as the desktop user, using the package path printed by the build:

```sh
sudo packaging/omastation/install-login "$(id -un)" /absolute/path/to/omastation.pkg.tar.zst
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
