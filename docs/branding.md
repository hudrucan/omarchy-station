# Omarchy Station — branding and README media

## Name and compatibility

Use **Omarchy Station** as the product name and **Station** in prose after the
first mention. The promise is straightforward: reach your existing Omarchy
desktop from another device and continue working.

The product name changes presentation only. Keep these identifiers:

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
is needed. CLI help and system descriptions keep their existing technical names.

The GitHub repository is `hudrucan/omarchy-station`; the local checkout is named
`omarchy-station` as well. Clone, badge, issue and package metadata URLs use the
repository name. Build caches, package storage and the source snapshot's internal
`omastation` directory keep their technical names.

Retain the upstream link, Git history, license and original copyright notices.
Present the project as developed from Omastation, with concrete additions rather
than unmeasured performance comparisons.

## README presentation

- Lead with the desktop experience, followed by installation and daily use.
- Put the recorded RDP workflow near the top, with a caption that explains the
  visible result before someone starts watching.
- Keep the [static SVG](assets/station.svg) as a separate brand asset.
- Use real applications and actual remote resolution changes in the demo.
- Avoid claims such as guaranteed 60 fps or identical client support. Codec and
  clipboard capabilities depend on the client and connection.

## Current demo

The [README recording](assets/README.md) follows a single workflow: work in an
editor and terminal over RDP, shrink the client window to portrait proportions,
then switch between the two applications that remain in reach. The wide and
portrait dimensions are labeled in the video so the benefit is visible without
reading the feature list.

The portrait view is a resized FreeRDP desktop client on Linux. A Mac/Finder
folder-transfer scene should use an actual Mac recording when added separately.

Captions sit outside the remote application content. The GIF is a lightweight
10 fps preview, with an MP4 alongside it. Preserve capture/export details in
the asset notes; the demo illustrates behavior rather than benchmark results.
