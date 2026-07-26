# AgentUsage

A local-only macOS menu-bar app for viewing Codex and Claude usage and activity.

![AgentUsage Day, Week, and Cumulative usage views](Assets/Previews/agent-usage-real-app-triptych.png)

AgentUsage talks directly to the Codex and Anthropic services using credentials already stored by their local clients.
In the case of Codex, it uses the locally authenticated Codex Appserver to fetch usage data. In the case of Claude, it uses the stored Claude Code credential (as file or in keychain) to fetch usage data from the Anthropic API. AgentUsage includes no analytics or telemetry and does not send requests to any third-party servers.

Licensed under the [MIT License](LICENSE).

## Install

Reading Claude usage requires a one-time Keychain authorization. macOS asks whether `AgentUsageClaudeHelper` may access the `Claude Code-credentials` item in your login Keychain; approval lets it read Claude Code's existing OAuth token and request usage data directly from Anthropic without returning the token to the main AgentUsage app.

The recommended installation path is Homebrew:

```sh
brew install --cask Rock-Z/tap/agentusage
```

Alternatively, use the one-click release installer:

```sh
curl -fsSL https://github.com/Rock-Z/AgentUsage/releases/latest/download/install.sh | bash
```

Alternatively, build and install from source:

```sh
./Scripts/build-app.sh --install
```

The DMG on [Releases](https://github.com/Rock-Z/AgentUsage/releases) remains available for manual installation. The first launch may require using **Open Anyway** in System Settings → Privacy & Security.

## See also

Below are some other alternatives for the same purpose:

- For more providers and a more mature feature set, see [CodexBar](https://github.com/steipete/CodexBar).
- For local usage accounting from coding-agent logs, see [ccusage](https://github.com/ryoppippi/ccusage).

AgentUsage aims to be a minimal, constrained, and aesthetically pleasing to use monitoring utility.
