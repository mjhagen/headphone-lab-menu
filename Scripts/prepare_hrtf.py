#!/usr/bin/env python3
"""Rebuild the bundled SADIE II subsets (requires numpy and h5py).

Usage: python3 Scripts/prepare_hrtf.py --cache /tmp/headphone-spatial-sadie
Downloads original SOFA files only when absent. No runtime Python dependency.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import urllib.request
import h5py
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'Sources/HeadphoneLabMenu/Resources/HRTF'
SUBJECTS = {'D1': 'KU100', 'D2': 'KEMAR', 'H10': 'Listener H10'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = {}
    for subject, name in SUBJECTS.items():
        url = f'https://sofacoustics.org/data/database/sadie/{subject}_48K_24bit_256tap_FIR_SOFA.sofa'
        source = args.cache / f'{subject}.sofa'
        if not source.exists():
            urllib.request.urlretrieve(url, source)
        with h5py.File(source) as sofa:
            license_text = sofa.attrs['License'].decode()
            if 'Apache License' not in license_text:
                raise ValueError(f'{subject}: Apache license not found; refusing to redistribute')
            assert float(sofa['Data.SamplingRate'][0]) == 48000
            assert np.all(sofa['Data.Delay'][:] == 0)
            ir = sofa['Data.IR'][:]
            positions = np.deg2rad(sofa['SourcePosition'][:, :2])
            directions = np.column_stack((np.cos(positions[:, 1]) * np.cos(positions[:, 0]),
                                           np.cos(positions[:, 1]) * np.sin(positions[:, 0]),
                                           np.sin(positions[:, 1])))
            # Keep actual measured positions nearest a 10-degree azimuth / 15-degree
            # elevation grid, including poles. No new synthetic HRTFs are authored.
            indices = set()
            for elevation in range(-90, 91, 15):
                for azimuth in range(0, 360, 10):
                    a, e = np.deg2rad([azimuth, elevation])
                    target = [np.cos(e)*np.cos(a), np.cos(e)*np.sin(a), np.sin(e)]
                    indices.add(int(np.argmax(directions @ target)))
            indices = sorted(indices)
            # Original filters are already diffuse-field equalized by York. Keep
            # them intact, zero-padding and aligning each ear's dominant peak to
            # tap 160 for phase-aware interpolation. Store its original position
            # separately so the renderer restores the measured interaural delay.
            payload = bytearray(struct.pack('<4sIII', b'HLH1', 48000, len(indices), 512))
            for i in indices:
                peaks = np.argmax(np.abs(ir[i]), axis=1)
                payload += struct.pack('<5f', *directions[i], *peaks)
                for ear in range(2):
                    aligned = np.zeros(512, dtype='<f4')
                    offset = 160 - int(peaks[ear])
                    if offset < 0:
                        raise ValueError('Unexpected HRIR timing')
                    aligned[offset:offset + 256] = ir[i, ear]
                    payload += aligned.tobytes()
            output = OUT / f'{subject}.hlhrtf'
            output.write_bytes(payload)
            manifest[subject] = dict(name=name, source=url,
                source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                asset_sha256=hashlib.sha256(payload).hexdigest(),
                directions=len(indices), sample_rate=48000, taps=512,
                source_license=license_text)
            print(subject, len(indices), len(payload))
    (OUT / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    main()
