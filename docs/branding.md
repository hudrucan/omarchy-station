# Omarchy Station — brand draft

## Name and compatibility

Use **Omarchy Station** as the product name and **Station** in prose after the
first mention. The promise is straightforward: reach your existing Omarchy
desktop from another device and continue working.

This draft changes presentation only. Keep these identifiers:

| Surface | Name |
| --- | --- |
| Binary and Arch package | `omastation` |
| Desktop listener | `omastation.service` |
| Login listener | `omastation-login.service` |
| Helper | `omastation-helper@.service` |
| Desktop session | `omastation-session@.service` |
| Plugin and IPC names | Existing `omastation` names |
| Configuration, credentials, build caches and package storage | Existing paths |

No package replacement, credential migration, service switch or runtime change
is needed. The existing installed CLI help and system descriptions continue to
use their current wording in this documentation draft.

The GitHub repository remains `hudrucan/omastation`. A later repository rename
to `omarchy-station` is optional and separate: update clone instructions, badge,
issue, workflow and source URLs together if it happens. Do not publish URLs for
a repository that has not been renamed.

Retain the upstream link, Git history, license and original copyright notices.
Present the project as developed from Omastation, with concrete additions rather
than unmeasured performance comparisons.

## README presentation

- Lead with the desktop experience, followed by installation and daily use.
- Use the static SVG as branding, not as a screenshot or performance demo.
- Keep the earlier sample-window recording in a collapsed section for context.
- Replace it with the recording below once the real workflow has been captured.
- Avoid claims such as guaranteed 60 fps or identical client support. Codec and
  clipboard capabilities depend on the client and connection.

## Demo to record

Target **20–25 seconds**, using real apps and an RDP client. Use a disposable
sample project so every action is clear without exposing a personal workspace.

| Time | Action | Visible result | Caption |
| --- | --- | --- | --- |
| 0–6 s | Show a Mac with an open Windows App connection; type in a remote editor. | Both the client frame and the Omarchy desktop are visible; text appears in the editor. | Same desktop. Keep working. |
| 6–14 s | Copy a small project folder in Finder, paste into remote Files, then open it. | The folder and its contents arrive on the remote desktop. | Copy a folder. Paste it there. |
| 14–23 s | Reduce the remote display from landscape to phone proportions, with floating windows near the original right edge. | The remote resolution changes and the windows move into the smaller work area. | Big screen to pocket. |

Keep captions outside the application content, one per scene. Show actual
remote resolution changes; resizing a video crop is not a substitute. The final
portrait view can be a narrow desktop client if explicitly labeled; use an
actual phone recording when showing a phone client.

Make the window-recovery scene the main visual payoff. Hold the before and
after states long enough to understand what moved. Keep the client frame or
another clear device cue visible so viewers understand this is remote access.

Export a compact looping GIF for GitHub's README and a higher-frame-rate MP4
for closer viewing. Label the capture frame rate; neither file should be
presented as a benchmark. Keep the original recording until both exports have
been reviewed at the README's displayed size and on a narrow screen.
