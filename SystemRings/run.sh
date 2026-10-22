#!/usr/bin/env bash
#
# run.sh — control the System Rings desktop widget
#
#   ./run.sh start      launch the widget (builds first if needed)
#   ./run.sh stop       stop/kill the widget (SIGTERM, then SIGKILL)
#   ./run.sh restart    stop, then start
#   ./run.sh status     show whether it's running
#   ./run.sh build      rebuild the app bundle only
#
# The widget is a plain (un-sandboxed) app, so stopping it with pkill is safe.
# If "Launch at Login" is enabled, login/startup will launch it again later —
# disable that in the menu-bar menu first if you want it gone for good.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_DIR="build/SystemRings.app"
PROCESS_NAME="SystemRings"

is_running() {
    pgrep -x "$PROCESS_NAME" >/dev/null 2>&1
}

pids() {
    pgrep -x "$PROCESS_NAME" | tr '\n' ' ' | sed 's/ $//'
}

build_if_needed() {
    if [[ ! -x "$APP_DIR/Contents/MacOS/$PROCESS_NAME" ]]; then
        echo "App bundle missing — building…"
        ./build.sh
    fi
}

start() {
    if is_running; then
        echo "▶ System Rings is already running (pid $(pids))"
        return 0
    fi
    build_if_needed
    if ! open "$APP_DIR" 2>/dev/null; then
        nohup "$APP_DIR/Contents/MacOS/$PROCESS_NAME" >/dev/null 2>&1 &
    fi
    # Give it a moment to come up (and stay up) before declaring success.
    for _ in {1..10}; do
        sleep 0.5
        if is_running; then
            echo "✔ started (pid $(pids))"
            return 0
        fi
    done
    echo "✘ failed to start (process exited right away)" >&2
    return 1
}

stop() {
    if ! is_running; then
        echo "○ System Rings is not running."
        return 0
    fi
    echo "■ stopping (pid $(pids))…"
    pkill -TERM -x "$PROCESS_NAME" 2>/dev/null || true
    for _ in {1..10}; do   # wait up to ~3 s for a graceful exit
        sleep 0.3
        is_running || break
    done
    if is_running; then
        echo "  still running after SIGTERM — sending SIGKILL"
        pkill -KILL -x "$PROCESS_NAME" 2>/dev/null || true
        sleep 1
    fi
    if is_running; then
        echo "✘ could not stop" >&2
        return 1
    fi
    echo "✔ stopped"
}

status() {
    if is_running; then
        echo "▶ System Rings is running (pid $(pids))"
    else
        echo "○ System Rings is not running."
    fi
}

case "${1:-help}" in
    start)   start ;;
    stop)    stop ;;
    restart) echo "restarting…"; stop; start ;;
    status)  status ;;
    build)   ./build.sh ;;
    help|-h|--help)
        sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,2\}//'
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Usage: ./run.sh [start|stop|restart|status|build|help]" >&2
        exit 1
        ;;
esac
