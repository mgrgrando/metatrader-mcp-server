#!/usr/bin/env python3
"""Inicia (ou reinicia) a bridge de backtest LLM na porta 8000."""
import os
import sys
import signal
import socket
import subprocess

BRIDGE_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(BRIDGE_DIR)

ENV = {
    **os.environ,
    "HERMES_URL":            "http://192.168.100.56:8644",
    "HERMES_ROUTE":          "backtest",
    "CALLBACK_BASE_URL":     "http://192.168.100.55:8000",
    "HERMES_WEBHOOK_TOKEN":  "97G2nd05aTy9y4Z1E0Sk_3Jg9yYG9EiBA5HGas-vHsc",
    "DECIDE_TIMEOUT":        "300",
    "LOG_FILE":              os.path.join(PROJECT_DIR, "logs", "bridge.log"),
    "CACHE_FILE":            os.path.join(PROJECT_DIR, "backtest_cache.json"),
}


def port_in_use(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def kill_port(port: int) -> None:
    if sys.platform == "win32":
        result = subprocess.run(
            f'netstat -ano | findstr ":{port} "', shell=True, capture_output=True, text=True
        )
        for line in result.stdout.splitlines():
            parts = line.split()
            if f":{port}" in parts[1] and parts[3] == "LISTENING":
                pid = int(parts[4])
                subprocess.run(f"taskkill /PID {pid} /F", shell=True)
                print(f"Processo anterior encerrado (PID {pid}).")
                return
    else:
        subprocess.run(f"fuser -k {port}/tcp", shell=True)


if __name__ == "__main__":
    port = 8000

    if port_in_use(port):
        print(f"Porta {port} em uso — encerrando processo anterior...")
        kill_port(port)

    print(f"Iniciando bridge em http://0.0.0.0:{port} ...")
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "bridge:app", "--host", "0.0.0.0", "--port", str(port)],
        cwd=BRIDGE_DIR,
        env=ENV,
    )
    print(f"Bridge rodando (PID {proc.pid}). Ctrl+C para encerrar.")
    try:
        proc.wait()
    except KeyboardInterrupt:
        proc.send_signal(signal.SIGINT)
        proc.wait()
        print("Bridge encerrada.")
