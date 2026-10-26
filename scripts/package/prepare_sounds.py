#!/usr/bin/env python3
"""Build-time preparation of the Ctrl+Calm sound assets (Python 3 standard library only).

Not needed by end users or for compiling the package. It turns the original
recordings in assets/_downloads/ into the bundled loops in assets/sounds/ and
writes assets/sounds/manifest.json, assets/ATTRIBUTION.md and assets/LICENSES.md.

Processing per sound (documented in docs/AUDIO_ENGINE.md):
  1. Parse the RIFF/WAVE file (PCM or WAVE_FORMAT_EXTENSIBLE PCM, 16 or 24 bit).
  2. Take a LOOP_SECONDS segment starting START_FRACTION into the recording
     (skips handling noise at the start); short recordings are used whole.
  3. Normalize toward TARGET_RMS_DBFS RMS (the level of the procedural noise
     generators). Impulsive recordings (fire crackle, drops) are allowed at
     most MAX_LIMITING_DB of gain beyond their peak-normalized level, and a
     5 ms look-ahead peak limiter keeps every sample below PEAK_LIMIT_DBFS.
  4. Convert to 16-bit with TPDF dither; keep the original rate and channels.
  5. Write a canonical PCM WAV. Loop seams are crossfaded at runtime by the
     engine, so no audio is altered at the boundaries here.

Usage:  python scripts/package/prepare_sounds.py [--check]
        --check  only verify that bundled files match manifest checksums
"""

import datetime
import hashlib
import json
import math
import os
import random
import struct
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
DOWNLOADS = os.path.join(ROOT, "assets", "_downloads")
SOUNDS = os.path.join(ROOT, "assets", "sounds")
MANIFEST = os.path.join(SOUNDS, "manifest.json")

LOOP_SECONDS = 60.0
START_FRACTION = 0.08
TARGET_RMS_DBFS = -20.0
PEAK_LIMIT_DBFS = -1.0
MAX_LIMITING_DB = 12.0
# Sparse, impulsive recordings get a little more limiting so they can sit near
# the other sounds' level.
LIMITING_OVERRIDES_DB = {"fireplace": 20.0, "water": 16.0}
LOOKAHEAD_MS = 5.0
RELEASE_MS = 120.0
ACQUIRED = "2026-10-09"

CC0_NAME = "CC0 1.0 Universal (Public Domain Dedication)"
CC0_URL = "https://creativecommons.org/publicdomain/zero/1.0/"
BSB_LICENSE_PAGE = "https://bigsoundbank.com/licenses.html"

# sound key -> (BigSoundBank id, original title, detail page)
SOURCES = {
    "rain": ("1019", "Summer Rain on Terrace", "https://bigsoundbank.com/summer-rain-on-terrace-s1019.html"),
    "thunderstorm": ("0740", "Rain and Thunder #2", "https://bigsoundbank.com/rain-and-storm-2-s0740.html"),
    "wind": ("0908", "Wind in Tall Grass", "https://bigsoundbank.com/wind-in-tall-grass-s0908.html"),
    "forest": ("2749", "Forest #4", "https://bigsoundbank.com/forest-4-s2749.html"),
    "leaves": ("0904", "Wind in the Trees", "https://bigsoundbank.com/forest-wind-in-the-trees-s0904.html"),
    "stream": ("2754", "Mountain stream #1", "https://bigsoundbank.com/mountain-stream-1-s2754.html"),
    "seaside": ("2565", "Sea of the Beach of Dellec #2", "https://bigsoundbank.com/sea-of-the-beach-of-dellec-2-s2565.html"),
    "water": ("2136", "Cave #2", "https://bigsoundbank.com/cave-2-s2136.html"),
    "fireplace": ("2855", "Fireplace #3", "https://bigsoundbank.com/fireplace-3-s2855.html"),
    "summer-night": ("0110", "Campaign at night #1", "https://bigsoundbank.com/campaign-at-night-1-s0110.html"),
    "coffee-shop": ("2561", "Coffee Shop at the Capucins", "https://bigsoundbank.com/coffee-shop-at-the-capucins-s2561.html"),
    "train": ("0635", "Eurostar car", "https://bigsoundbank.com/eurostar-car-s0635.html"),
    "fan": ("0078", "Electric fan #1", "https://bigsoundbank.com/electric-fan-1-s0078.html"),
}
CREATOR = "Joseph Sardin (BigSoundBank.com)"

PROCEDURAL = {
    "white-noise": "White noise generated in real time (xoshiro128** uniform source).",
    "pink-noise": "Pink noise generated in real time (Paul Kellet's refined -3 dB/octave filter).",
    "brown-noise": "Brown noise generated in real time (leaky integrator, -6 dB/octave, DC-blocked).",
}

SUBTYPE_PCM = bytes.fromhex("0100000000001000800000aa00389b71")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_wav(path):
    """Returns (rate, channels, bits, frames as list of per-channel float lists)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[0:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    pos, fmt, pcm = 12, None, None
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b"fmt ":
            tag, ch, rate, _, align, bits = struct.unpack_from("<HHIIHH", body, 0)
            if tag == 0xFFFE:
                if body[24:40] != SUBTYPE_PCM:
                    raise ValueError("unsupported extensible sub-format")
            elif tag != 1:
                raise ValueError("unsupported format tag %d" % tag)
            fmt = (ch, rate, align, bits)
        elif cid == b"data":
            pcm = body
        pos += 8 + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError("missing fmt or data chunk")
    ch, rate, align, bits = fmt
    if bits not in (16, 24):
        raise ValueError("unsupported bit depth %d" % bits)
    nframes = len(pcm) // align
    chans = [[0.0] * nframes for _ in range(ch)]
    width = bits // 8
    scale = 1.0 / (1 << (bits - 1))
    for i in range(nframes):
        base = i * align
        for c in range(ch):
            o = base + c * width
            if width == 2:
                v = struct.unpack_from("<h", pcm, o)[0]
            else:
                b = pcm[o:o + 3]
                v = int.from_bytes(b, "little", signed=True)
            chans[c][i] = v * scale
    return rate, ch, bits, chans


def write_wav(path, rate, chans):
    ch, n = len(chans), len(chans[0])
    rng = random.Random(20261009)
    out = bytearray(n * ch * 2)
    k = 0
    for i in range(n):
        for c in range(ch):
            # TPDF dither of +/- 1 LSB
            v = chans[c][i] * 32767.0 + (rng.random() - rng.random())
            v = 32767 if v > 32767 else (-32768 if v < -32768 else int(round(v)))
            struct.pack_into("<h", out, k, v)
            k += 2
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(out)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, ch, rate, rate * ch * 2, ch * 2, 16))
        f.write(b"data" + struct.pack("<I", len(out)))
        f.write(out)


def limit(chans, rate, ceiling):
    """Look-ahead peak limiter: min-filtered gain over the look-ahead window,
    smoothed by a moving average (attack) and a one-pole release."""
    from collections import deque
    n = len(chans[0])
    la = max(1, int(rate * LOOKAHEAD_MS / 1000))
    need = [1.0] * n
    for i in range(n):
        p = max(abs(c[i]) for c in chans)
        if p > ceiling:
            need[i] = ceiling / p
    # running minimum of need[i .. i+la]
    gmin = [1.0] * n
    dq = deque()
    for i in range(n + la - 1, -1, -1):
        if i < n:
            while dq and need[dq[-1]] >= need[i]:
                dq.pop()
            dq.append(i)
        while dq and dq[0] > i + la:
            dq.popleft()
        if i < n:
            gmin[i] = need[dq[0]]
    # moving average over the look-ahead window (smooth attack)
    acc, avg = 0.0, [1.0] * n
    for i in range(n):
        acc += gmin[i]
        if i >= la:
            acc -= gmin[i - la]
        avg[i] = acc / min(i + 1, la)
    rel = 1.0 - math.exp(-1.0 / (rate * RELEASE_MS / 1000))
    g, reduced = 1.0, 0.0
    for i in range(n):
        target = min(avg[i], gmin[i])
        g = target if target < g else g + (target - g) * rel
        for c in chans:
            c[i] *= g
        reduced = max(reduced, -db(g))
    # hard safety (the averaging can leave tiny overshoots)
    for c in chans:
        for i in range(n):
            if c[i] > ceiling:
                c[i] = ceiling
            elif c[i] < -ceiling:
                c[i] = -ceiling
    return reduced


def db(x):
    return 20 * math.log10(x) if x > 0 else -999.0


def process(key):
    bsb_id, title, page = SOURCES[key]
    src = os.path.join(DOWNLOADS, bsb_id + ".wav")
    rate, ch, bits, chans = read_wav(src)
    total = len(chans[0])
    loop = int(LOOP_SECONDS * rate)
    if total <= loop:
        start, length = 0, total
    else:
        start = min(int(total * START_FRACTION), total - loop)
        length = loop
    seg = [c[start:start + length] for c in chans]
    sumsq = sum(v * v for c in seg for v in c)
    rms = math.sqrt(sumsq / (length * ch))
    peak = max(abs(v) for c in seg for v in c)
    ceiling = 10 ** (PEAK_LIMIT_DBFS / 20)
    max_lim = LIMITING_OVERRIDES_DB.get(key, MAX_LIMITING_DB)
    gain = min(10 ** (TARGET_RMS_DBFS / 20) / rms, ceiling / peak * 10 ** (max_lim / 20))
    seg = [[v * gain for v in c] for c in seg]
    reduction = limit(seg, rate, ceiling) if peak * gain > ceiling else 0.0
    final_rms = math.sqrt(sum(v * v for c in seg for v in c) / (length * ch))
    final_peak = max(abs(v) for c in seg for v in c)
    out_name = key + ".wav"
    out_path = os.path.join(SOUNDS, out_name)
    write_wav(out_path, rate, seg)
    return {
        "id": key,
        "kind": "recorded",
        "originalFilename": bsb_id + ".wav",
        "originalTitle": title,
        "creator": CREATOR,
        "sourceUrl": page,
        "downloadUrl": "https://bigsoundbank.com/UPLOAD/bwf-en/%s.wav" % bsb_id,
        "license": CC0_NAME,
        "licenseUrl": CC0_URL,
        "licenseEvidence": BSB_LICENSE_PAGE,
        "acquired": ACQUIRED,
        "originalSha256": sha256(src),
        "originalFormat": "%d Hz, %d-bit PCM, %d ch, %.2f s" % (rate, bits, ch, total / rate),
        "processing": (
            "Segment %.2f-%.2f s of the original; gain %+.1f dB; peak limiter max %.1f dB "
            "(result RMS %.1f dBFS, peak %.1f dBFS); %s16-bit TPDF dither; runtime loop crossfade 1.5 s."
            % (start / rate, (start + length) / rate, db(gain), reduction, db(final_rms),
               db(final_peak), "24-bit to " if bits == 24 else "")),
        "file": out_name,
        "sha256": sha256(out_path),
        "format": "PCM WAV, %d Hz, 16-bit, %s" % (rate, "stereo" if ch == 2 else "mono"),
        "durationSeconds": round(length / rate, 3),
        "bytes": os.path.getsize(out_path),
    }


def write_docs(entries):
    att = ["# Ctrl+Calm sound attribution", "",
           "All recorded sounds bundled with Ctrl+Calm were recorded by **Joseph Sardin** and "
           "published on [BigSoundBank.com](https://bigsoundbank.com) under "
           "[CC0 1.0 Universal](%s). Attribution is not required by CC0; it is given here "
           "with thanks." % CC0_URL, "",
           "| Sound | Original recording | Creator | License | Bundled file |",
           "|---|---|---|---|---|"]
    for e in entries:
        if e["kind"] == "recorded":
            att.append("| %s | [%s](%s) | %s | [CC0 1.0](%s) | `sounds/%s` |" % (
                e["id"], e["originalTitle"], e["sourceUrl"], e["creator"], e["licenseUrl"], e["file"]))
        else:
            att.append("| %s | Generated in code | Ctrl+Calm | MIT (project license) | - |" % e["id"])
    att += ["", "Processing details and checksums for every file are in `sounds/manifest.json`.", ""]
    with open(os.path.join(ROOT, "assets", "ATTRIBUTION.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(att))

    lic = ["# Ctrl+Calm asset licenses", "",
           "## Recorded sounds (assets/sounds/*.wav)", "",
           "License: **%s**  " % CC0_NAME,
           "Deed: %s  " % CC0_URL,
           "Source license statement: %s (each sound page states "
           "\"CC0 (public domain): Free and royalty-free\")." % BSB_LICENSE_PAGE, "",
           "The creator has dedicated these recordings to the public domain. They may be copied, "
           "modified and redistributed, including commercially, without asking permission. "
           "Ctrl+Calm redistributes trimmed, level-normalized 16-bit copies, see manifest.json.", "",
           "## Procedural noise (white, pink, brown)", "",
           "Generated at runtime by Ctrl+Calm's own code under the project's MIT license. "
           "No audio files are involved.", "",
           "## Icons", "",
           "All icons are original vector drawings in `src/UI/CtrlCalm.UI.Icons.pas` (MIT).", "",
           ]
    with open(os.path.join(ROOT, "assets", "LICENSES.md"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lic))


def check():
    with open(MANIFEST, encoding="utf-8") as f:
        m = json.load(f)
    bad = 0
    for e in m["sounds"]:
        if e["kind"] != "recorded":
            continue
        p = os.path.join(SOUNDS, e["file"])
        ok = os.path.exists(p) and sha256(p) == e["sha256"]
        print(("OK   " if ok else "BAD  ") + e["file"])
        bad += 0 if ok else 1
    return bad


def main():
    if "--check" in sys.argv:
        sys.exit(check())
    os.makedirs(SOUNDS, exist_ok=True)
    entries = []
    for key in SOURCES:
        print("processing", key, flush=True)
        entries.append(process(key))
    for key, text in PROCEDURAL.items():
        entries.append({"id": key, "kind": "procedural", "creator": "Ctrl+Calm",
                        "license": "MIT", "processing": text, "file": None})
    order = ["rain", "thunderstorm", "wind", "forest", "leaves", "stream", "seaside", "water",
             "fireplace", "summer-night", "coffee-shop", "train", "fan",
             "white-noise", "pink-noise", "brown-noise"]
    entries.sort(key=lambda e: order.index(e["id"]))
    manifest = {"schema": "ctrlcalm-sound-manifest/1",
                "generated": datetime.date.today().isoformat(),
                "generator": "scripts/package/prepare_sounds.py",
                "sounds": entries}
    with open(MANIFEST, "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    write_docs(entries)
    print("done")


if __name__ == "__main__":
    main()
