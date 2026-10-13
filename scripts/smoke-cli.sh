#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="${1:-$project_dir/.build/debug/gpt-mem}"
if [[ ! -x "$binary" ]]; then
  echo "CLI 不存在或不可执行，请先运行 swift build：$binary" >&2
  exit 1
fi

/usr/bin/python3 - "$binary" <<'PY'
import json
import os
import pathlib
import select
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from html.parser import HTMLParser

binary = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="gpt-mem-cli-") as directory:
    root = pathlib.Path(directory)
    environment = dict(os.environ, GPT_MEM_HOME=str(root / "history"))
    def run(*arguments, success=True):
        result = subprocess.run([binary, *arguments], env=environment,
                                text=True, capture_output=True, timeout=20)
        if success:
            assert result.returncode == 0, (arguments, result.returncode, result.stderr)
        else:
            assert result.returncode != 0, (arguments, result.stdout)
            assert not result.stdout.strip(), (arguments, "错误污染 stdout", result.stdout)
            assert result.stderr.strip(), (arguments, "错误缺少 stderr")
        return result

    assert "watch" in run("--help").stdout
    run("explain", "--json", success=False)
    assert not (root / "history").exists(), "只读 explain 不应创建历史"
    for arguments in [("watch", "--interval", "0"), ("watch", "--duration", "nan"),
                      ("watch", "--interval", "inf"), ("report", "--since", "-1m"),
                      ("report", "--since", "bogus"), ("status", "--output", "x"),
                      ("status", "--json", "--json"), ("diagnose", "--pid", "0", "--output", "x"),
                      ("diagnose", "--pid", "1")]:
        run(*arguments, success=False)
    status = json.loads(run("status", "--json").stdout)
    assert status["command"] == "status" and status["sessionAttribution"] == "unknown"
    assert isinstance(status["snapshot"]["processes"], list)
    assert not (root / "history").exists(), "status 不应创建历史"

    # A live writer must exclude duplicate watch, then release the flock on SIGINT.
    monitor = subprocess.Popen([binary, "watch", "--json", "--interval", "1", "--duration", "10"],
                               env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([monitor.stdout], [], [], 15)
        assert ready, "watch 未及时输出第一份样本"
        first = json.loads(monitor.stdout.readline())
        assert first["command"] == "watch"
        duplicate = run("watch", "--json", "--duration", "1", success=False)
        assert "lock" in duplicate.stderr.lower() or "监控" in duplicate.stderr or "锁" in duplicate.stderr
        monitor.send_signal(signal.SIGINT)
        remaining, errors = monitor.communicate(timeout=10)
        assert monitor.returncode == 0, errors
        for line in remaining.splitlines():
            json.loads(line)
    finally:
        if monitor.poll() is None:
            monitor.kill()
            monitor.wait()

    started = time.monotonic()
    sampled = run("watch", "--json", "--interval", "1", "--duration", "2.2")
    elapsed = time.monotonic() - started
    rows = [json.loads(line) for line in sampled.stdout.splitlines()]
    assert len(rows) >= 2, "短时采样应提供至少两份样本"
    assert elapsed < 8, f"duration 未及时结束：{elapsed:.1f}s"
    analysis = json.loads(run("explain", "--json", "--since", "30m").stdout)
    assert analysis["sampleCount"] >= 2
    assert analysis["explanation"]["headline"] and analysis["explanation"]["nextSteps"]
    assert analysis["totalChangeBytes"] == sum(analysis[key] for key in
        ["addedContributionBytes", "exitedContributionBytes", "existingChangeBytes", "unresolvedContributionBytes"])

    # Exercise escaping with deliberately hostile diagnostic text in our disposable history.
    database = root / "history" / "history.sqlite3"
    for protected in [database, pathlib.Path(str(database) + "-wal"),
                      pathlib.Path(str(database) + "-shm"), root / "history" / "monitor.lock"]:
        run("report", "--output", str(protected), success=False)
    with sqlite3.connect(database) as connection:
        identifier, payload = connection.execute("SELECT id,payload FROM snapshots ORDER BY captured_at DESC LIMIT 1").fetchone()
        snapshot = json.loads(payload)
        snapshot["warnings"].append("<script>injection&secret</script>")
        connection.execute("UPDATE snapshots SET payload=? WHERE id=?", (json.dumps(snapshot).encode(), identifier))
    output = root / "report.html"
    report = json.loads(run("report", "--json", "--since", "30m", "--output", str(output)).stdout)
    assert report["output"] == str(output)
    assert report["trend"] and report["sessionAttribution"] == "unknown"
    assert report["analysis"]["explanation"]["summary"]
    html = output.read_text()
    assert "分析结论" in html and "下一步检查" in html
    assert "&lt;script&gt;injection&amp;secret&lt;/script&gt;" in html
    assert "<svg" in html and "<script" not in html and "cdn" not in html.lower()
    class LocalReportParser(HTMLParser):
        def handle_starttag(self, tag, attributes):
            for key, value in attributes:
                assert key not in ("src", "href") or not str(value).startswith(("http:", "https:")), "HTML 依赖外部资源"
    LocalReportParser().feed(html)
    def check_redacted(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if key == "executable":
                    assert "/" not in item, "JSON 泄露完整程序路径"
                check_redacted(item)
        elif isinstance(value, list):
            for item in value:
                check_redacted(item)
    check_redacted(report)

    # Simulate one sample per second across two hours without waiting or touching real history.
    # Reuse the live database's schema and payload so this exercises the actual CLI decoder.
    long_database = root / "long-history.sqlite3"
    with sqlite3.connect(database) as source, sqlite3.connect(long_database) as connection:
        source.backup(connection)
        template = json.loads(source.execute(
            "SELECT payload FROM snapshots ORDER BY captured_at DESC LIMIT 1").fetchone()[0])
        connection.execute("DELETE FROM snapshots")
        captured_end = time.time()
        def long_samples():
            for index in range(7_202):
                captured_at = captured_end - 7_201 + index
                snapshot = dict(template, id=f"long-history-{index}", capturedAt=captured_at * 1_000)
                yield snapshot["id"], captured_at, json.dumps(snapshot).encode()
        connection.executemany(
            "INSERT INTO snapshots(id,captured_at,payload) VALUES (?,?,?)", long_samples())
    long_analysis = json.loads(run("explain", "--json", "--since", "2h",
                                   "--db", str(long_database)).stdout)
    assert 5_000 < long_analysis["sampleCount"] <= 7_202, long_analysis["sampleCount"]
    long_output = root / "long-report.html"
    long_report = json.loads(run("report", "--json", "--since", "2h", "--db", str(long_database),
                                "--output", str(long_output)).stdout)
    long_count = long_report["analysis"]["sampleCount"]
    # Each invocation chooses its own current time, so boundary samples may differ slightly.
    assert 5_000 < long_count <= 7_202, long_count
    assert len(long_report["trend"]) == long_count
    assert long_report["output"] == str(long_output)
    long_html = long_output.read_text()
    assert f"{long_count} 份样本" in long_html
    assert "<svg" in long_html
    LocalReportParser().feed(long_html)
    check_redacted(long_report)

    # A known growing process must produce actionable conclusions in JSON, text,
    # and HTML rather than merely repeat the sample count or footprint table.
    explained_database = root / "explained-history.sqlite3"
    with sqlite3.connect(database) as source, sqlite3.connect(explained_database) as connection:
        source.backup(connection)
        connection.execute("DELETE FROM snapshots")
        ended_at = time.time()
        for index in range(11):
            captured_at = ended_at - (10 - index) * 60
            process = dict(bootID="fixture-boot", pid=4242, parentPID=1, startTimeTicks=42,
                           startedAt=(ended_at - 3_600) * 1_000,
                           executable="/private/fixture-secret/Renderer <img src=x onerror=alert(1)>",
                           role="renderer", roleHint="", rootKey="fixture-root",
                           footprintBytes=(100 + index * 15) * 1_048_576,
                           rssBytes=0, peakFootprintBytes=0, cpuPercent=None, ownership="process_tree")
            snapshot = dict(id=f"explained-{index}", capturedAt=captured_at * 1_000,
                            processes=[process], observer=None,
                            system=dict(physicalBytes=16 * 1_073_741_824, pressureLevel=1),
                            unavailablePIDs=[], warnings=[])
            connection.execute("INSERT INTO snapshots(id,captured_at,payload) VALUES (?,?,?)",
                               (snapshot["id"], captured_at, json.dumps(snapshot).encode()))
    explained = json.loads(run("explain", "--json", "--since", "30m",
                               "--db", str(explained_database)).stdout)
    explanation = explained["explanation"]
    assert explanation["kind"] == "growth" and explanation["evidence"] and explanation["nextSteps"]
    assert any(item["kind"] == "sustainedGrowth" and item["pid"] == 4242
               for item in explanation["findings"])
    assert "/private/fixture-secret/" not in json.dumps(explanation, ensure_ascii=False)
    explained_text = run("explain", "--since", "30m", "--db", str(explained_database)).stdout
    assert "分析结论" in explained_text and "下一步检查" in explained_text and "4242" in explained_text
    explained_output = root / "explained-report.html"
    explained_report = json.loads(run("report", "--json", "--since", "30m",
                                      "--db", str(explained_database), "--output", str(explained_output)).stdout)
    assert explained_report["analysis"]["explanation"] == explanation
    explained_html = explained_output.read_text()
    assert "分析结论" in explained_html and "下一步检查" in explained_html and "4242" in explained_html
    assert "&lt;img src=x onerror=alert(1)&gt;" in explained_html and "<img" not in explained_html
    assert "/private/fixture-secret/" not in explained_html
    LocalReportParser().feed(explained_html)
    check_redacted(explained_report)

    # Equal timestamps provide measurements but no elapsed observation; they
    # must not be described as missing process metrics or a confirmed trend.
    same_time_database = root / "same-time-history.sqlite3"
    with sqlite3.connect(database) as source, sqlite3.connect(same_time_database) as connection:
        source.backup(connection)
        connection.execute("DELETE FROM snapshots")
        for index in range(2):
            simultaneous = dict(snapshot, id=f"same-time-{index}")
            connection.execute("INSERT INTO snapshots(id,captured_at,payload) VALUES (?,?,?)",
                               (simultaneous["id"], captured_at, json.dumps(simultaneous).encode()))
    same_time = json.loads(run("explain", "--json", "--db", str(same_time_database)).stdout)
    assert same_time["explanation"]["kind"] == "insufficientData" and not same_time["isComplete"]
    same_time_text = run("explain", "--db", str(same_time_database)).stdout
    assert "样本时间不足" in same_time_text and "存在缺失指标" not in same_time_text
    same_time_output = root / "same-time-report.html"
    run("report", "--db", str(same_time_database), "--output", str(same_time_output))
    assert "样本时间不足" in same_time_output.read_text()

    # PID 1 is not a GPT-owned process: diagnose must reject it without creating an output.
    diagnostic = root / "disallowed-diagnostic.txt"
    run("diagnose", "--pid", "1", "--output", str(diagnostic), success=False)
    assert not diagnostic.exists()

    terminating = subprocess.Popen([binary, "watch", "--json", "--interval", "1", "--duration", "10"],
                                   env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
    try:
        ready, _, _ = select.select([terminating.stdout], [], [], 15)
        assert ready, "SIGTERM 检查未及时开始采样"
        json.loads(terminating.stdout.readline())
        terminating.send_signal(signal.SIGTERM)
        _, errors = terminating.communicate(timeout=10)
        assert terminating.returncode == 0, errors
    finally:
        if terminating.poll() is None:
            terminating.kill()
            terminating.wait()
    print(f"CLI smoke 检查通过：参数、只读边界、NDJSON、单实例、SIGINT/SIGTERM、duration、归因、数据库保护、HTML 转义/离线、两小时长历史、JSON/文本/HTML 分析解读与诊断目标拒绝；短时采样 {len(rows)} 份，{elapsed:.2f}s；长历史报告 {long_count} 份。")
PY
