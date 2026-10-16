#!/usr/bin/env python3
"""Röstanalys för Kundkoll.

Läser en förfrågan som JSON på stdin och svarar med JSON på stdout. Allt annat
går till stderr, så att utdata alltid går att tolka.

Två lägen:

    {"läge": "diarisera", "wav": "..."}
    → {"segment": [{"start":…, "slut":…, "talare": "SPEAKER_00"}, ...]}

    {"läge": "avtryck", "wav": "...", "turer": [{"start":…, "slut":…}, ...]}
    → {"dim": 192, "avtryck": [{"start":…, "slut":…, "vektor": [...]}, ...]}

Diariseringen gör pyannote, som är tränad och kalibrerad för just det här och
hittar antalet talare själv. Egen klustring av röstavtryck provades först och
höll inte: på ett riktigt tvåpersonerssamtal gav den antingen 58 röster eller
slog ihop båda till en, beroende på tröskel.

Avtrycken (ECAPA-TDNN) behövs fortfarande, men till en annan sak: att känna
igen samma person mellan olika samtal.

Körs med Pythonmiljön i ~/Projekt/transcriber/venv, som har både pyannote och
speechbrain. Sökvägen kommer från Swift-sidan.
"""
import json
import os
import sys
import warnings

warnings.filterwarnings("ignore")


def fel(text):
    print(json.dumps({"fel": text}), flush=True)
    sys.exit(1)


def ladda_ljud(wav, torch):
    """Läser ljudfilen med soundfile och ger (1, n) i 16 kHz mono.

    Går förbi torchcodec, som kräver att FFmpeg:s delade bibliotek matchar
    exakt den torch-version som är installerad.
    """
    import soundfile as sf
    data, sr = sf.read(wav, dtype="float32", always_2d=True)
    vag = torch.from_numpy(data.T.copy()).mean(dim=0, keepdim=True)
    if sr != 16000:
        import torchaudio
        vag = torchaudio.functional.resample(vag, sr, 16000)
        sr = 16000
    return vag, sr


def main():
    try:
        begaran = json.load(sys.stdin)
    except Exception as e:
        fel(f"kunde inte läsa förfrågan: {e}")

    wav = begaran.get("wav")
    lage = begaran.get("läge") or begaran.get("lage") or "avtryck"
    turer = begaran.get("turer") or []
    if not wav:
        fel("ingen wav angiven")
    if lage == "avtryck" and not turer:
        print(json.dumps({"dim": 0, "avtryck": []}), flush=True)
        return

    try:
        import numpy as np
        import torch
        import torchaudio
    except Exception as e:
        fel(f"saknar torch/torchaudio: {e}")

    # torchaudio 2.10 har tagit bort delar som speechbrain fortfarande kallar på.
    if not hasattr(torchaudio, "list_audio_backends"):
        torchaudio.list_audio_backends = lambda: ["torchcodec"]
    if not hasattr(torchaudio, "AudioMetaData"):
        from dataclasses import dataclass

        @dataclass
        class _Meta:
            sample_rate: int = 0
            num_frames: int = 0
            num_channels: int = 0
            bits_per_sample: int = 0
            encoding: str = ""

        torchaudio.AudioMetaData = _Meta

    # speechbrain 1.0.3 skickar use_auth_token, som nyare huggingface_hub
    # inte längre tar emot. Utan det här faller modelladdningen.
    try:
        import huggingface_hub
        _hamta = huggingface_hub.hf_hub_download

        def _hamta_utan_token(*a, **kw):
            kw.pop("use_auth_token", None)
            return _hamta(*a, **kw)

        huggingface_hub.hf_hub_download = _hamta_utan_token
    except Exception as e:
        fel(f"saknar huggingface_hub: {e}")

    from pathlib import Path

    MODELLFILER = ["hyperparams.yaml", "embedding_model.ckpt",
                   "mean_var_norm_emb.ckpt", "label_encoder.txt"]
    cache = Path.home() / ".cache" / "speechbrain" / "spkrec-ecapa-voxceleb"
    try:
        cache.mkdir(parents=True, exist_ok=True)
        for namn in MODELLFILER:
            if not (cache / namn).exists():
                print(f"laddar ned {namn} …", file=sys.stderr)
                huggingface_hub.hf_hub_download(
                    repo_id="speechbrain/spkrec-ecapa-voxceleb",
                    filename=namn, local_dir=str(cache))
    except Exception as e:
        fel(f"kunde inte hämta modellfilerna: {e}")

    if lage == "diarisera":
        diarisera(wav, begaran, torch)
        return

    try:
        from speechbrain.inference.speaker import EncoderClassifier
    except Exception as e:
        fel(f"saknar speechbrain: {e}")

    try:
        modell = EncoderClassifier.from_hparams(
            source=str(cache), savedir=str(cache), run_opts={"device": "cpu"})
    except Exception as e:
        fel(f"kunde inte ladda ECAPA-modellen: {e}")

    try:
        vag, sr = ladda_ljud(wav, torch)
    except Exception as e:
        fel(f"kunde inte läsa ljudet: {e}")
    vag = vag[0]

    ut = []
    for tur in turer:
        a, b = float(tur["start"]), float(tur["slut"])
        klipp = vag[int(a * sr):int(b * sr)]
        # Under en sekund blir avtrycket för brusigt för att vara värt något.
        if klipp.shape[0] < sr:
            continue
        with torch.no_grad():
            v = modell.encode_batch(klipp.unsqueeze(0)).squeeze().detach().cpu().numpy()
        norm = float(np.linalg.norm(v))
        if norm == 0:
            continue
        ut.append({"start": a, "slut": b, "vektor": (v / norm).astype(float).tolist()})

    print(json.dumps({"dim": len(ut[0]["vektor"]) if ut else 0, "avtryck": ut}), flush=True)


def diarisera(wav, begaran, torch):
    """Delar ljudet i talarsegment med pyannote."""
    # Modellerna ligger i huggingface-cachen. Utan offline-läget vill
    # pyannote hämta dem på nytt och kräver då ett konto.
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    try:
        from pyannote.audio import Pipeline
    except Exception as e:
        fel(f"saknar pyannote: {e}")

    modell = begaran.get("modell") or "pyannote/speaker-diarization-3.1"
    try:
        pipeline = Pipeline.from_pretrained(modell)
    except Exception as e:
        fel(f"kunde inte ladda {modell}: {e}")
    if pipeline is None:
        fel(f"{modell} gick inte att ladda — modellen saknas i cachen "
            "eller kräver ett Hugging Face-konto")

    if torch.backends.mps.is_available():
        try:
            pipeline.to(torch.device("mps"))
        except Exception:
            pass  # faller tillbaka på processorn

    # Antalet talare kan vara känt, till exempel ur en kalenderinbjudan.
    kwargs = {}
    for nyckel, arg in (("minst", "min_speakers"), ("mest", "max_speakers")):
        if begaran.get(nyckel):
            kwargs[arg] = int(begaran[nyckel])
    if begaran.get("antal"):
        kwargs["num_speakers"] = int(begaran["antal"])

    try:
        vag, sr = ladda_ljud(wav, torch)
    except Exception as e:
        fel(f"kunde inte läsa ljudet: {e}")

    try:
        resultat = pipeline({"waveform": vag, "sample_rate": sr}, **kwargs)
    except Exception as e:
        fel(f"diariseringen misslyckades: {e}")

    if hasattr(resultat, "serialize"):
        rader = resultat.serialize().get("diarization", [])
        segment = [{"start": float(r["start"]), "slut": float(r["end"]),
                    "talare": str(r["speaker"])} for r in rader]
    else:
        segment = [{"start": float(t.start), "slut": float(t.end), "talare": str(s)}
                   for t, _, s in resultat.itertracks(yield_label=True)]

    print(json.dumps({"segment": segment}), flush=True)


if __name__ == "__main__":
    main()
