import math
import struct
import subprocess
import sys
import tempfile
import unittest
import wave
from pathlib import Path


class CueTests(unittest.TestCase):
    def test_default_cue_is_audible_length_and_louder_without_clipping(self):
        script = Path(__file__).resolve().parent.parent / 'scripts/make_sounds.py'
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run([sys.executable, str(script), temp], check=True)
            with wave.open(str(Path(temp) / 'complete.wav')) as sound:
                self.assertEqual(sound.getnchannels(), 1)
                samples = struct.unpack('<' + 'h' * sound.getnframes(), sound.readframes(sound.getnframes()))
                duration = len(samples) / sound.getframerate()
            peak = max(map(abs, samples)) / 32768
            rms = math.sqrt(sum(x*x for x in samples) / len(samples)) / 32768
            self.assertGreaterEqual(duration, .55)
            self.assertLess(peak, .95)
            self.assertGreater(rms * .85 / (.095 * .42), 3.5)


if __name__ == '__main__':
    unittest.main()
