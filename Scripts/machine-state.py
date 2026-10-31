#!/usr/bin/env python3
# この Mac の状態を1行の JSON で出す(読むだけ)。回帰の赤をマシンの劣化と切り分ける材料(Scripts/regress.py が開始と終了で記録する)。
# 書き手の台帳 ~/.fleetest/{fm-liveness,video-encoder-liveness}.json を読むだけで、FM もエンコーダも撃たない。
# 欄の契約: 読めない値は欄ごと省く(0 や dead で埋めない)。ageSeconds が大きい観測は古い = 今の状態とは言えない。
# 判定は置かない(「劣化」と言えるのは人が run と突き合わせたときだけ)。
import json, os, re, socket, subprocess, time


def uptime_seconds(now):
    out = subprocess.run(["sysctl", "-n", "kern.boottime"], capture_output=True, text=True)
    match = re.search(r"sec = (\d+)", out.stdout) if out.returncode == 0 else None
    return round(now - int(match.group(1))) if match else None


def ledger(name):
    try:
        with open(os.path.join(os.path.expanduser("~/.fleetest"), name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def verdict(entry, now):
    if not isinstance(entry, dict) or "state" not in entry or "checkedAt" not in entry:
        return None
    return {"state": entry["state"], "source": entry.get("source"), "ageSeconds": round(now - entry["checkedAt"])}


def main():
    now = time.time()
    state = {"at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "host": socket.gethostname(), "cpuCount": os.cpu_count()}
    uptime = uptime_seconds(now)
    if uptime is not None:
        state["uptimeSeconds"] = uptime
    try:
        state["load1"], state["load5"], _ = [round(v, 1) for v in os.getloadavg()]
    except OSError:
        pass
    fm = ledger("fm-liveness.json") or {}
    for key in ("text", "vision"):
        found = verdict(fm.get(key), now)
        if found:
            state[f"fm{key.capitalize()}"] = found
    encoder = verdict(ledger("video-encoder-liveness.json"), now)
    if encoder:
        state["videoEncoder"] = encoder
    print(json.dumps(state, ensure_ascii=False))


if __name__ == "__main__":
    main()
