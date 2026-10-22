#!/usr/bin/env bash
# Doorbell Demo — unified control interface
cd "$(dirname "$0")"

while true; do
    clear
    echo "============================================"
    echo "  DOORBELL DEMO — CONTROL MENU"
    echo "============================================"
    echo "  1) Start all (PBX container)"
    echo "  2) Stop all"
    echo "  3) Reset demo (clean test data)"
    echo "  4) Guided demo (step-by-step manual)"
    echo "  0) Exit"
    echo "============================================"
    read -p "Choose [0-4]: " choice

    case "$choice" in
        1) ./scripts/start-all.sh > /tmp/opencode/demo.log 2>&1; echo "Started. (log: /tmp/opencode/demo.log)"; read -p "Press Enter..." _ ;;
        2) ./scripts/stop-all.sh > /tmp/opencode/demo.log 2>&1; echo "Stopped."; read -p "Press Enter..." _ ;;
        3) ./scripts/reset-demo.sh > /tmp/opencode/demo.log 2>&1; echo "Reset complete."; read -p "Press Enter..." _ ;;
        4) ./scripts/guided-demo.sh ;;
        0) echo "Bye!"; exit 0 ;;
        *) echo "Invalid choice"; read -p "Press Enter..." _ ;;
    esac
done