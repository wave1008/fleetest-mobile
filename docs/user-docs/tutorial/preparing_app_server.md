# Checking the server

[in Japanese(日本語)](preparing_app_server_ja.md)

The SUT Store server (a server plus PostgreSQL) was already declared to fleetest in the Quick Start. Declared servers
start automatically on every `fleetest run` and stop when it ends. The details are in
[Services the app depends on](../reference/writing/services.md).

## 1. Look at the declaration

### Prompt for the AI

```text
Tell me about the servers project1 uses.
```

Expected result:

- Information about the server and the db is shown.

## 2. Start it and check

### Prompt for the AI

```text
Start the servers project1 uses.
Confirm that /health on the published port returns ok.
Run services down and report the result.
```

- If an MCP permission dialog appears, allow it.

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

```bash
../fleetest-mobile/.build/debug/fleetest services up --project project1 --profile ios-run
curl http://127.0.0.1:8090/health     # at the published port that was printed
../fleetest-mobile/.build/debug/fleetest services down --project project1 --profile ios-run
```

</details>
<br>

Expected result:

- The steps run as instructed and the result is reported.

Related:

- [Services the app depends on](../reference/writing/services.md)
- [Network access from scenarios](../reference/writing/network_access.md)
- [Extending](../reference/writing/extending.md)

<br>

Next: [Creating tests](creating_tests.md)

### Link
- [index](../index.md)
