# README demo

[GIF](demo.gif) · [MP4](demo.mp4) · [Brand banner](station.svg)

The recording shows a real authenticated localhost RDP connection to an
isolated Hyprland desktop, viewed through FreeRDP's SDL client on Linux.
The applications are nano and a Bash terminal, both running in Foot, with a
disposable sample project.

The sequence:

1. Type and run a Python command through the RDP client.
2. Resize the client window from a 1280×720 remote display to 480×760.
3. Show the editor and terminal automatically returning to the visible work
   area, then switch focus between them.

The resolution change is sent by the client through RDP; the server's output
dimensions and the windows' visible positions were checked during capture.
The portrait segment is a resized Linux desktop client window.

Captions were added over the recorded client desktop. Capture and MP4 are
12 fps; the looping GIF is exported at 10 fps and 1080×765. This is a feature
walkthrough, not a performance benchmark.

Shared-memory capture and lossless planar updates keep text crisp in this
recording. The clip demonstrates input and window recovery; it does not compare
graphics backends or encoders.

Recorded with Omarchy Station 0.1.6, stock Hyprland 0.56.2 and FreeRDP 3.32.2.
The isolated compositors, temporary RDP credentials and test input devices are
separate from the user's desktop session.
