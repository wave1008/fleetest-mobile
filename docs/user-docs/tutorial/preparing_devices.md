# Preparing devices

[in Japanese(日本語)](preparing_devices_ja.md)

Add to the devices you set up in the Quick Start.

## 1. Add more virtual devices

### Prompt for the AI

```text
Add one more iPhone Simulator to the run profile ios-run in the fleetest test project project1.
If there aren't enough, you can create one with the same model and OS.
Then show me the profile's updated device list.
```

<details>
<summary><b>If you do it manually (click to show details)</b></summary>

In the **Profiles** tab of the Device Monitor, press the run profile's "Add device" button.

From the CLI, run the following. `--count` makes the run profile hold N devices of that OS in total (the existing ones included).

```bash
../fleetest-mobile/.build/debug/fleetest profile setup --project project1 --platform ios --app-id com.sutec.mobile.ios --auto-device --count 3
```

</details>
<br>

Expected result:

- Check the **Profiles** tab of the Device Monitor.

<br>

Next: [Checking the server](preparing_app_server.md)

### Link
- [index](../index.md)
