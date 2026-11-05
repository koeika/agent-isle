"""Original soft chiptune cues, synthesized at build time. No third-party assets."""
import math
import struct
import sys
import wave
from pathlib import Path

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)
for name, notes in {"complete": [(659.25, .14), (830.61, .14), (987.77, .30)],
                    "attention": [(783.99, .18), (0, .08), (783.99, .24)],
                    "error": [(392, .20), (293.66, .30)]}.items():
    data = bytearray()
    rate = 44100
    for freq, duration in notes:
        for i in range(int(rate * duration)):
            t = i / rate
            envelope = min(1, t / .008) * max(0, 1 - t / duration) ** 1.3
            # Rounded pulse timbre with only three harmonics, avoiding harsh buzz.
            sample = sum(math.sin(2 * math.pi * freq * k * t) / k ** 2 for k in [1, 3, 5]) if freq else 0
            data.extend(struct.pack("<h", int(sample * envelope * 18000)))
    with wave.open(str(root / (name + ".wav")), "wb") as f:
        f.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        f.writeframes(data)
