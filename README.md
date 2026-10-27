# kairos-tts-koplugin

Sentence-by-sentence read-aloud for KOReader with a synchronized overlay
highlight, driven by a local Piper TTS server. The voice never leaves your
network: the e-reader sends plain text over HTTP, the server synthesizes and
plays on the machine it runs on.

This is the reading module of [Kairós](https://github.com/groove-dharma/kairos),
a cognitive exo-prosthesis for neuroatypical minds.

## Why this fork

This fork combines two upstream projects:

- [norude/TTS.koplugin](https://github.com/norude/TTS.koplugin): the plugin
  structure, the playback widget and the remote Piper server protocol.
- [stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin):
  the sentence parser and the screen-coordinate highlight machinery.

The fork changes the highlight mechanic. The original plugin creates a real
KOReader annotation for the highlighted text; here the highlight is paint,
not data: a temporary overlay drawn on the framebuffer after the page is
rendered. Nothing is written to the document or its sidecar, so read-along
highlighting cannot collide with your annotations, sync or export.
Annotation creation was removed entirely.

Sentence matching is intentionally simple: if a sentence cannot be found on
the visible page, that sentence is not highlighted and audio keeps going;
the next sentence recovers. The fine-grained alignment helpers of the
audiobook plugin were not ported, trading precision for robustness.

## What it does

- Sentence-by-sentence playback with the current sentence highlighted
  (EPUB, rolling mode).
- Four highlight styles: invert (best for e-ink), underline, box, background.
- E-ink friendly: only the changed screen strip is refreshed between
  sentences.
- No annotations, no sidecar writes, no document modification.
- Server-side WAV cache in RAM: navigating back and forth replays without
  resynthesis.
- Settings: voice, speed, volume, server URL, highlight style.

## How it works

Two pieces:

- `TTS.koplugin/`: the KOReader plugin (4 Lua files). It parses the book
  into sentences, requests synthesis from the server and draws the overlay.
- `server/python-pyaudio-flask/`: a Flask server (`piper-tts.py`) that
  synthesizes with [Piper](https://github.com/OHF-Voice/piper1-gpl) and
  plays through pyaudio.

Protocol (plain JSON over HTTP): `POST /` (text to handle), `POST /play`,
`POST /remaining`, `POST /stop`, `GET /voices`. The reader polls `/remaining`
to advance the highlight.

The server is lazy: the default voice loads on the first synthesis, and
after ten idle minutes the models are unloaded from RAM while the process
keeps listening.

## Requirements

- KOReader with an EPUB. PDF is not supported: the highlight relies on
  crengine xpointers.
- Any device KOReader runs on. Tested on a 2013 Kindle Paperwhite: synthesis
  happens on the server, the reader only draws.
- Python 3.10+ on the server (tested on 3.13), with portaudio available to
  pyaudio (your package manager has it).

## Setup

### 1. The server

```bash
pip install -r requirements.txt
python server/python-pyaudio-flask/piper-tts.py -m en_US-lessac-medium --data-dir . --port 5000
```

Voices are Piper voice IDs in `<language>-<region>-<name>-<quality>` format
(e.g. `es_ES-davefx-medium`). The server looks for `<voice>.onnx` in
`--data-dir` and can download any voice from the
[piper-voices](https://huggingface.co/rhasspy/piper-voices) collection
through its `/download` endpoint, or you can use the piper CLI.

On Windows, `tts-server.bat` is the reference launcher: it runs the server
under `pythonw` from a `venv/` created next to the script, and the server
redirects its output to `server/server.log` when running without a console.

### 2. The plugin

Copy `TTS.koplugin/` into KOReader's plugins directory and restart KOReader:

| Platform | Path |
|----------|------|
| Kindle | `koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Linux | `~/.config/koreader/plugins/` |
| Android | `/sdcard/koreader/plugins/` |

Open a book, Start TTS Mode, and in settings point the server URL to
`<your-pc-ip>:5000` (no `http://`). The Voice menu lists the voices the
server finds in its data directory.

## Controls

| Button | Action |
|--------|--------|
| ⚙ | Settings |
| ◁ | Previous sentence |
| ⏵ / ⏸ | Play / pause |
| ▷ | Next sentence |
| ⏹ | Stop |

## Provenance

See [NOTICE](NOTICE) for the file-by-file origin of the third-party code.
Unofficial fork, not affiliated with or endorsed by the upstream projects.

## License

AGPL-3.0. See [LICENSE](LICENSE).
