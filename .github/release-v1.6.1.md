Bluetooth output routing now uses the selected device’s audio format and verifies the route after startup and resume. A harmless configuration-change notification no longer stops playback when the selected output is still running correctly. The macOS default output does not need to be changed.

Silent hardware tests verified playback, independent local monitoring and pause/resume through a Bluetooth adapter while another device remained the system default. An intermittent first-click error was reported but could not be reproduced; its cause remains unconfirmed.

Download **MZT-Player-1.6.1-macOS-arm64.zip** for Apple Silicon Macs running macOS 13 or later. **SHA256SUMS.txt** contains the archive checksum. The build is ad hoc signed and not Apple-notarised.
