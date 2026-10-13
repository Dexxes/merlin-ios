#!/usr/bin/env python3
"""Erzeugt die nahtlos kachelbare Papierstruktur für den Reader-Hintergrund.

Ausgabe: Sources/Merlin/paper-texture.png (512×512, Graustufen). Die Kachel
wird im Reader per Multiply über die Theme-Farbe gelegt (siehe
`PaperBackground` in ArticleReaderView.swift), deshalb liegt sie knapp unter
Weiß: Mittelwert ≈ 0.975, kaum Werte über 1.0 – das Blatt wird nur minimal
dunkler, Fasern und Korn schwanken um wenige Prozent.

Das Rauschen wird im Frequenzraum gefiltert; die FFT ist periodisch, die
Kachel hat dadurch keine sichtbaren Nähte.

    python3 scripts/generate-paper-texture.py   # benötigt numpy + Pillow
"""
import os
import numpy as np
from PIL import Image

N = 512
MEAN = 0.975
STD = 0.02
rng = np.random.default_rng(7)

fy = np.fft.fftfreq(N)[:, None]
fx = np.fft.fftfreq(N)[None, :]


def band(sigma_lo, sigma_hi=0.0, aniso=1.0):
    """Normiertes, periodisches Rauschen; `aniso` streckt es zu Fasern."""
    spectrum = np.fft.fft2(rng.standard_normal((N, N)))
    r = np.sqrt((fx * aniso) ** 2 + fy ** 2)
    filt = np.exp(-(r * sigma_lo) ** 2)
    if sigma_hi:
        filt -= np.exp(-(r * sigma_hi) ** 2)
    n = np.real(np.fft.ifft2(spectrum * filt))
    return (n - n.mean()) / n.std()


tex = (0.18 * band(60)                     # leichte Wolkigkeit
       + 0.45 * band(1.5, 6, aniso=5)      # Fasern, vertikal
       + 0.35 * band(1.5, 6, aniso=0.2)    # Fasern, horizontal
       + 0.50 * band(0.5))                 # feines Korn
tex /= tex.std()

out = np.clip(MEAN + STD * tex, 0, 1)
path = os.path.join(os.path.dirname(__file__), "..", "Sources", "Merlin", "paper-texture.png")
Image.fromarray(np.round(out * 255).astype(np.uint8), mode="L").save(path, optimize=True)
print(f"{os.path.normpath(path)}: mean {out.mean():.4f}, min {out.min():.3f}, max {out.max():.3f}")
