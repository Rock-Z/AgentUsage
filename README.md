# aiusage

A private-by-default macOS menu-bar app for viewing Codex and Claude usage limits, credits, and activity.

## Install

Requires macOS 14 or later and a local Codex or Claude Code login.

```sh
curl -fsSL https://github.com/Rock-Z/aiusage/releases/latest/download/install.sh | bash
```

The installer verifies the release checksum and code signature, then installs to `~/Applications`. To build from source instead:

```sh
./Scripts/build-app.sh --install
```

aiusage talks directly to the Codex and Anthropic services using credentials already stored by their local clients. Credentials are read locally and sent only to their respective provider; aiusage includes no analytics or telemetry.

Licensed under the [MIT License](LICENSE).
