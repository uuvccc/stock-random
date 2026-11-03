# -*- coding: utf-8 -*-
"""
stock-random 服务守护进程（由 NSSM 托管运行）

职责：
1. 拉起并守护 app.py 子进程，崩溃后自动重启（指数退避）
2. 定时执行 git pull（默认 300s，GIT_PULL_INTERVAL 配置，0 关闭）
3. 监控 *.py / templates 下文件变化，变化后自动重启子进程实现热加载
   （git pull 拉到的更新也会通过文件变化检测触发重启）

环境变量：
  GIT_PULL_INTERVAL  git pull 间隔秒数，默认 300，设为 0 禁用
  WATCH_ENABLED      文件监控热加载，默认 1，设为 0 禁用
  WATCH_INTERVAL     文件扫描间隔秒数，默认 2
"""
import os
import subprocess
import sys
import time
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
VENV_PY = BASE_DIR / ".venv" / "Scripts" / "python.exe"
PYTHON = str(VENV_PY) if VENV_PY.exists() else sys.executable

GIT_PULL_INTERVAL = float(os.environ.get("GIT_PULL_INTERVAL", "300"))
WATCH_ENABLED = os.environ.get("WATCH_ENABLED", "1") != "0"
WATCH_INTERVAL = float(os.environ.get("WATCH_INTERVAL", "2"))

RESTART_BACKOFF_MIN = 2.0
RESTART_BACKOFF_MAX = 60.0
# 子进程稳定运行超过该时长则重置退避
STABLE_RUN_SECONDS = 60.0

WATCH_PATTERNS = ("*.py", "*.html", "*.js", "*.css")
WATCH_DIRS = (BASE_DIR, BASE_DIR / "templates")
IGNORE_DIRS = {".venv", ".git", "__pycache__", "tools", ".screenshots", "logs"}


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} [supervisor] {msg}", flush=True)


def snapshot_files() -> dict[str, float]:
    """采集受监控文件的 mtime 快照。"""
    snap: dict[str, float] = {}
    for watch_dir in WATCH_DIRS:
        if not watch_dir.exists():
            continue
        for pattern in WATCH_PATTERNS:
            for f in watch_dir.rglob(pattern):
                if any(part in IGNORE_DIRS for part in f.parts):
                    continue
                try:
                    snap[str(f)] = f.stat().st_mtime
                except OSError:
                    continue
    return snap


def files_changed(old: dict[str, float], new: dict[str, float]) -> list[str]:
    changed = [p for p, m in new.items() if old.get(p) != m]
    changed += [p for p in old if p not in new]
    return changed


def git_pull() -> None:
    try:
        r = subprocess.run(
            ["git", "pull", "--ff-only"],
            cwd=BASE_DIR,
            capture_output=True,
            text=True,
            timeout=120,
            encoding="utf-8",
            errors="replace",
        )
        out = (r.stdout or "").strip()
        if r.returncode == 0:
            log(f"git pull OK: {out or '(no output)'}")
        else:
            log(f"git pull FAILED(rc={r.returncode}): {(r.stderr or out).strip()}")
    except Exception as exc:
        log(f"git pull 异常: {exc}")


def start_app() -> subprocess.Popen:
    log(f"启动 app.py (python={PYTHON})")
    return subprocess.Popen(
        [PYTHON, "app.py"],
        cwd=BASE_DIR,
        # 独立进程组，避免 NSSM 发信号时互相干扰
        creationflags=subprocess.CREATE_NEW_PROCESS_GROUP,
    )


def stop_app(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    log(f"停止 app 子进程 pid={proc.pid}")
    # 用 taskkill /T 杀掉整棵进程树，比 terminate 更可靠
    subprocess.run(
        ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
        capture_output=True,
    )
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass


def main() -> int:
    log(f"守护进程启动，工作目录 {BASE_DIR}")
    log(f"GIT_PULL_INTERVAL={GIT_PULL_INTERVAL}s WATCH_ENABLED={WATCH_ENABLED} WATCH_INTERVAL={WATCH_INTERVAL}s")

    proc = start_app()
    backoff = RESTART_BACKOFF_MIN
    last_start = time.time()
    last_pull = time.time()
    snap = snapshot_files()
    last_watch = time.time()

    try:
        while True:
            time.sleep(1)
            now = time.time()

            # 1. 崩溃自动重启
            rc = proc.poll()
            if rc is not None:
                run_time = now - last_start
                if run_time >= STABLE_RUN_SECONDS:
                    backoff = RESTART_BACKOFF_MIN
                log(f"app 进程退出 rc={rc}（运行 {run_time:.0f}s），{backoff:.0f}s 后重启")
                time.sleep(backoff)
                backoff = min(backoff * 2, RESTART_BACKOFF_MAX)
                proc = start_app()
                last_start = time.time()
                snap = snapshot_files()
                continue

            # 2. 定时 git pull
            if GIT_PULL_INTERVAL > 0 and now - last_pull >= GIT_PULL_INTERVAL:
                git_pull()
                last_pull = time.time()

            # 3. 文件变化热加载（git pull 的更新也走这里触发）
            if WATCH_ENABLED and now - last_watch >= WATCH_INTERVAL:
                new_snap = snapshot_files()
                changed = files_changed(snap, new_snap)
                if changed:
                    log(f"检测到文件变化（{len(changed)} 个），热重启: {changed[:3]}")
                    stop_app(proc)
                    proc = start_app()
                    last_start = time.time()
                    backoff = RESTART_BACKOFF_MIN
                    snap = snapshot_files()
                else:
                    snap = new_snap
                last_watch = now
    except KeyboardInterrupt:
        pass
    finally:
        stop_app(proc)
        log("守护进程退出")
    return 0


if __name__ == "__main__":
    sys.exit(main())
