# Smarter TV (iPad)

Smarter Tube's cable-TV mode remade for iPadOS: your YouTube home feed as numbered channels,
channel-change static, an old CRT look (curved tube, scanlines, phosphor mask, colour fringes),
a CRT power-on, and touch controls.

Built by GitHub Actions on a macOS runner into an unsigned `.ipa` (see the *Build iPad app*
workflow's artifacts); sign and install it with Sideloadly or AltStore.

`proto/` holds the Python prototype of the YouTube engine, ported from SmartTube's MediaServiceCore.
