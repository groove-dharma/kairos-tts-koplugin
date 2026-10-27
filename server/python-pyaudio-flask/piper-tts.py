#!/usr/bin/env python3.13
# FORK LOCAL sobre norude/TTS.koplugin server/python-pyaudio-flask/piper-tts.py
# Cambios declarados:
#   1. Modelo perezoso: la voz por defecto se carga en la PRIMERA síntesis,
#      no al arrancar. El proceso portero arranca liviano (~40 MB).
#   2. --idle-min N (default 10): tras N minutos sin requests, los modelos se
#      descargan de RAM (el proceso sigue escuchando; la próxima request
#      recarga, pagando unos segundos en esa frase). Cualquier request renueva
#      el contador: el sondeo /remaining mientras suena cuenta como actividad;
#      en pausa no llega nada, y la gracia corre desde la pausa.
#   3. threaded=True: la síntesis de la frase siguiente no bloquea el sondeo
#      /remaining de la frase que suena.
#   4. pythonw: redirigir streams a server.log SIEMPRE bajo pythonw.exe.
#      v3: ruta ABSOLUTA con resolve() — con __file__ relativa (como la pasa
#      el .bat) la bitácora caía un nivel abajo. v2: siempre bajo pythonw
#      (los tubos heredados apuntan a la consola muerta del cmd del .bat —
#      no son None, son zombies). v1: solo si None — insuficiente.

# CAMBIO 4 (v3): antes de cualquier import de tercero.
import sys
from pathlib import Path

_IS_PYTHONW = "pythonw" in Path(sys.executable).name.lower()

if _IS_PYTHONW or sys.stdout is None or sys.stderr is None:
    _log_file = open(
        Path(__file__).resolve().parent.parent / "server.log",
        "a",
        encoding="utf-8",
        buffering=1,
    )
    if _IS_PYTHONW or sys.stdout is None:
        sys.stdout = _log_file
    if _IS_PYTHONW or sys.stderr is None:
        sys.stderr = _log_file

import argparse
import gc
import json
import logging
import threading
import time
import wave
from io import BytesIO
from typing import Any
from urllib.request import urlopen

from common_server import create_server
from flask import request
from piper import PiperVoice, SynthesisConfig
from piper.download_voices import VOICES_JSON, download_voice

_LOGGER = logging.getLogger()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0", help="HTTP server host")
    parser.add_argument("--port", type=int, default=5000, help="HTTP server port")
    parser.add_argument("-m", "--model", required=True, help="Path to Onnx model file")
    parser.add_argument("-s", "--speaker", type=int, help="Id of speaker (default: 0)")
    parser.add_argument(
        "--length-scale", "--length_scale", type=float, help="Phoneme length"
    )
    parser.add_argument("--volume", type=float, help="Volume")
    parser.add_argument(
        "--noise-scale", "--noise_scale", type=float, help="Generator noise"
    )
    parser.add_argument(
        "--noise-w-scale",
        "--noise_w_scale",
        "--noise-w",
        "--noise_w",
        type=float,
        help="Phoneme width noise",
    )
    parser.add_argument("--cuda", action="store_true", help="Use GPU")
    parser.add_argument(
        "--sentence-silence",
        "--sentence_silence",
        type=float,
        default=0.0,
        help="Seconds of silence after each sentence",
    )
    parser.add_argument(
        "--idle-min",
        "--idle_min",
        type=float,
        default=10.0,
        help="Minutos sin requests antes de descargar los modelos de RAM (0 = nunca)",
    )
    parser.add_argument(
        "--data-dir",
        "--data_dir",
        action="append",
        default=[str(Path.cwd())],
        help="Data directory to check for downloaded models (default: current directory)",
    )
    parser.add_argument(
        "--download-dir",
        "--download_dir",
        help="Path to download voices (default: first data dir)",
    )
    parser.add_argument(
        "--debug", action="store_true", help="Print DEBUG messages to console"
    )
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)
    _LOGGER.debug(args)

    if not args.download_dir:
        # Download voices to first data directory if not specified
        args.download_dir = args.data_dir[0]

    download_dir = Path(args.download_dir)

    # Download voice if file doesn't exist
    model_path = Path(args.model)
    if not model_path.exists():
        # Look in data directories
        voice_name = args.model
        for data_dir in args.data_dir:
            maybe_model_path = Path(data_dir) / f"{voice_name}.onnx"
            _LOGGER.debug("Checking '%s'", maybe_model_path)
            if maybe_model_path.exists():
                model_path = maybe_model_path
                break

        if not model_path.exists():
            raise ValueError(
                f"Unable to find voice: {model_path} (use piper.download_voices)"
            )

    default_model_id = model_path.name.rstrip(".onnx")

    # CAMBIO 1: la voz por defecto se carga LAZY, en la primera síntesis.
    loaded_voices: dict[str, PiperVoice] = {}
    _default_cache: dict[str, PiperVoice] = {}

    def _get_default_voice() -> PiperVoice:
        if not _default_cache:
            _LOGGER.info("Cargando voz por defecto '%s'...", default_model_id)
            _default_cache["voice"] = PiperVoice.load(model_path, use_cuda=args.cuda)
        return _default_cache["voice"]

    async def voices():
        config_paths: list[Path] = [Path(f"{model_path}.json")]

        for data_dir in args.data_dir:
            for onnx_path in Path(data_dir).glob("*.onnx"):
                config_path = Path(f"{onnx_path}.json")
                if config_path.exists():
                    config_paths.append(config_path)
        for config_path in config_paths:
            name = config_path.name.rstrip(".onnx.json")
            yield name.split("-")[0], name

    async def inference(text: str, model_id, length_scale, volume, wav_io: BytesIO):
        voice = loaded_voices.get(model_id)
        if voice is None:
            for data_dir in args.data_dir:
                maybe_model_path = Path(data_dir) / f"{model_id}.onnx"
                if maybe_model_path.exists():
                    _LOGGER.debug("Loading voice %s", model_id)
                    voice = PiperVoice.load(maybe_model_path, use_cuda=args.cuda)
                    loaded_voices[model_id] = voice
                    break

        if voice is None:
            _LOGGER.warning("Voice not found: %s. Using default voice.", model_id)
            voice = _get_default_voice()
            model_id = default_model_id

        speaker_id: int | None = None  # data.get("speaker_id")
        if (voice.config.num_speakers > 1) and (speaker_id is None):
            speaker = None  # data.get("speaker")
            if speaker:
                speaker_id = voice.config.speaker_id_map.get(speaker)

            if speaker_id is None:
                _LOGGER.warning(
                    "Speaker not found: '%s' in %s",
                    speaker,
                    voice.config.speaker_id_map.keys(),
                )
                speaker_id = args.speaker or 0

        if (speaker_id is not None) and (speaker_id > voice.config.num_speakers):
            speaker_id = 0

        syn_config = SynthesisConfig(
            speaker_id=speaker_id,
            length_scale=float(
                length_scale
                if length_scale is not None
                else args.length_scale
                if args.length_scale is not None
                else voice.config.length_scale
            ),
            noise_scale=float(
                (
                    args.noise_scale
                    if args.noise_scale is not None
                    else voice.config.noise_scale
                ),
            ),
            noise_w_scale=float(
                (
                    args.noise_w_scale
                    if args.noise_w_scale is not None
                    else voice.config.noise_w_scale
                ),
            ),
            volume=float(
                volume
                if volume is not None
                else args.volume
                if args.volume is not None
                else 1.0,
            ),
        )

        _LOGGER.debug("Synthesizing text: '%s' with config=%s", text, syn_config)
        with wave.open(wav_io, "wb") as wav_file:
            wav_params_set = False
            for i, audio_chunk in enumerate(voice.synthesize(text, syn_config)):
                if not wav_params_set:
                    wav_file.setframerate(audio_chunk.sample_rate)
                    wav_file.setsampwidth(audio_chunk.sample_width)
                    wav_file.setnchannels(audio_chunk.sample_channels)
                    wav_params_set = True

                if i > 0:
                    wav_file.writeframes(
                        bytes(int(voice.config.sample_rate * args.sentence_silence * 2))
                    )

                wav_file.writeframes(audio_chunk.audio_int16_bytes)

    app = create_server(voices, inference)

    # CAMBIO 2: contador de actividad + watchdog de inactividad.
    _activity_lock = threading.Lock()
    _last_activity = time.time()

    def _touch():
        nonlocal _last_activity
        with _activity_lock:
            _last_activity = time.time()

    def _unload_voices():
        n = len(loaded_voices) + len(_default_cache)
        loaded_voices.clear()
        _default_cache.clear()
        gc.collect()
        _LOGGER.info(
            "Idle %g min: %d voz(es) descargada(s) de RAM. El server sigue escuchando.",
            args.idle_min,
            n,
        )

    @app.before_request
    def _mark_activity():
        _touch()

    def _idle_watchdog():
        while True:
            time.sleep(15)
            if args.idle_min <= 0:
                continue
            with _activity_lock:
                idle = time.time() - _last_activity
            if idle > args.idle_min * 60 and (loaded_voices or _default_cache):
                with _activity_lock:
                    _unload_voices()

    threading.Thread(target=_idle_watchdog, daemon=True).start()

    @app.get("/all-voices")
    def app_all_voices() -> dict[str, Any]:
        """List all Piper voices.
        Outputs voices.json from the piper-voices repo on HuggingFace.
        See: https://huggingface.co/rhasspy/piper-voices
        """
        with urlopen(VOICES_JSON) as response:
            return json.load(response)

    @app.post("/download")
    def app_download() -> str:
        """Download a voice.

        Downloads the .onnx and .onnx.json file from piper-voices repo on HuggingFace.

        Expects a JSON object with the format:
        {
            "voice": " ", (required)
            "force_redownload": false (optional)
        }

        Returns the name of the voice.
        Voice format must be <language>-<region>-<name>-<quality> like "en_US-lessac-medium".
        """
        data = json.loads(request.data)
        model_id = data.get("voice")
        if not model_id:
            raise ValueError("voice is required")

        force_redownload = data.get("force_redownload", False)
        download_voice(model_id, download_dir, force_redownload=force_redownload)

        return model_id

    # CAMBIO 3: threaded=True (sintesis y sondeo no se estorban).
    app.run(host=args.host, port=args.port, threaded=True)


if __name__ == "__main__":
    main()