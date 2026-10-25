# fleetest mobile

[日本語](README_ja.md)

**fleetest mobile** is an E2E testing tool for iOS and Android apps, designed to be used from an AI assistant
such as Claude Code. It runs on macOS.

- **fleet** — tests run in parallel on a fleet of Simulators, Emulators and physical devices, across your Mac and other Macs (runner machines)
- **fleetest** — the drivers are tuned for speed, on a single device and in parallel
- **free** — open source, and runs entirely on your own Macs, so running tests costs nothing

**AI writes the tests; code replays them deterministically.** The AI assistant drives your app through the
fleetest MCP server and CLI and writes test code in a Swift DSL. That test code then runs without any LLM —
fast, stable and suited to CI. Everything can run locally, which makes fleetest an option for organizations
that cannot use cloud services.

## Requirements

- A Mac with Apple silicon, macOS 26+
- Xcode 27.2+
- Homebrew
- VSCode
- Android SDK (if you test Android)
- An AI assistant that supports MCP (verified with Claude Code and Codex)
- Apple Intelligence (Foundation Models) is optional

Details: [Environment](docs/user-docs/overview/environments.md)

## Install

Open a new folder for your tests in VSCode, start your AI assistant and tell it:

```text
Clone https://github.com/wave1008/foundation-tester next to this folder and set it up by following
../foundation-tester/.claude/skills/fleetest-setup/SKILL.md.
```

The step-by-step guide, including running a sample app, is the [Quick start](docs/user-docs/quick-start.md).

## Documentation

| You want to | Start here |
|---|---|
| Use fleetest for your own app | [User documentation](docs/user-docs/index.md) ([日本語](docs/user-docs/index_ja.md)) |
| Look up a DSL command | [Function/Property](docs/user-docs/index.md#functionproperty) ([full command specification](docs/commands.md), Japanese) |
| Change fleetest itself | [CLAUDE.md](CLAUDE.md) (rules), [docs/README.md](docs/README.md) (maintainer docs index), [docs/development.md](docs/development.md) (build and repository layout) — all in Japanese |

## Four interfaces

| Interface | What it does |
|---|---|
| CLI | Commands that control test runs ([reference](docs/user-docs/reference/tools/cli.md)) |
| VSCode extension | Run and debug scenarios, Device Monitor, results dashboard ([reference](docs/user-docs/reference/tools/vscode_extension.md)) |
| MCP server | Lets an AI assistant drive devices to explore apps and write or debug tests ([reference](docs/user-docs/reference/tools/mcp_server.md)) |
| Swift DSL | The functions you write test code with ([reference](docs/user-docs/reference/testclass/testcode_structure.md)) |

## License

[LICENSE](LICENSE)
