@echo off
cd /d "%~dp0"
start "" "venv\Scripts\pythonw.exe" "server\python-pyaudio-flask\piper-tts.py" -m es_ES-davefx-medium --data-dir . --port 5000
