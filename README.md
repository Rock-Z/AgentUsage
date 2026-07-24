# AgentUsage

A local-only macOS menu-bar app for viewing Codex and Claude usage and activity.

![AgentUsage Day, Week, and Cumulative usage views](Assets/Previews/agent-usage-real-app-triptych.png)

AgentUsage talks directly to the Codex and Anthropic services using credentials already stored by their local clients.
In the case of Codex, it uses the locally authenticated Codex Appserver to fetch usage data. In the case of Claude, it uses the stored Claude Code credential (as file or in keychain) to fetch usage data from the Anthropic API. AgentUsage includes no analytics or telemetry and does not send requests to any third-party servers.

Licensed under the [MIT License](LICENSE).

## Install

Install by downloading the latest release from [Releases](https://github.com/Rock-Z/AgentUsage/releases)

To build from source instead:

```sh
./Scripts/build-app.sh --install
```

## See also

Below are some other alternatives for the same purpose:

- For more providers and a more mature feature set, see [CodexBar](https://github.com/steipete/CodexBar).
- For local usage accounting from coding-agent logs, see [ccusage](https://github.com/ryoppippi/ccusage).

AgentUsage aims to be a minimal, constrained, and aesthetically pleasing to use monitoring utility.
