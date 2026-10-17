"""Local, offline evaluation of captured phone motion. Never alters shared trails."""
import argparse
import csv
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import time
import zipfile

import numpy as np
import torch
from setup import ROOT, ASSETS, UPSTREAM

PERIOD = .005
MAX_GAP = .025


def read_capture(path):
    path = Path(path)
    if path.stat().st_size > 32 * 1024 * 1024:
        raise ValueError('Motion capture exceeds the size limit')
    return read_capture_text(path.read_text(encoding='utf-8'))


def read_capture_text(text):
    with io.StringIO(text, newline='') as stream:
        first = stream.readline()
        if not first.startswith('# '):
            raise ValueError('Missing motion metadata')
        metadata = json.loads(first[2:])
        if not isinstance(metadata, dict):
            raise ValueError('Invalid motion metadata')
        if (metadata.get('version') != 1 or metadata.get('source') != 'phone' or
            metadata.get('clock') != 'elapsedRealtimeNanos' or
            metadata.get('frame') != 'Android-game-rotation-z-up-yaw-unknown' or
            metadata.get('accelSensor') not in (1, 35) or metadata.get('gyroSensor') not in (4, 16) or
            metadata.get('rotationSensor') != 15 or
            metadata.get('accelerationUnits') != 'm/s^2-including-gravity' or metadata.get('angularRateUnits') != 'rad/s'):
            raise ValueError('Unsupported motion source, frame, sensors or units')
        origin = metadata['startedNs']
        if type(origin) is not int or origin < 0:
            raise ValueError('Invalid monotonic origin')
        lines = stream.readlines()
    if not lines or not lines[-1].startswith('# '):
        raise ValueError('Capture is incomplete; stop capture before exporting')
    footer = json.loads(lines[-1][2:])
    if not isinstance(footer, dict):
        raise ValueError('Invalid motion footer')
    if footer.get('complete') is not True or footer.get('reason') not in ('user-stopped', 'duration-limit', 'service-stopped'):
        raise ValueError('Capture ended with a sensor or storage failure')
    streams = {k: [] for k in ('accel', 'gyro', 'rotation')}
    reader = csv.DictReader(lines[:-1])
    if reader.fieldnames != ['t_ns', 'sensor', 'x', 'y', 'z', 'w', 'bx', 'by', 'bz']:
        raise ValueError('Unsupported motion columns')
    count = 0
    for row in reader:
        count += 1
        sensor = row['sensor']
        if sensor not in streams or None in row:
            raise ValueError('Unexpected sensor row')
        stamp = int(row['t_ns'])
        seconds = (stamp - origin) / 1e9
        if not 0 <= seconds <= 180:
            raise ValueError('Observation outside capture interval')
        values = np.array([float(row[k]) for k in ('x', 'y', 'z')], dtype=np.float64)
        if sensor == 'rotation':
            values = np.r_[float(row['w']), values]  # w,x,y,z
            norm = np.linalg.norm(values)
            if not .95 <= norm <= 1.05:
                raise ValueError('Invalid rotation quaternion')
            values /= norm
        else:
            uncalibrated = metadata['accelSensor' if sensor == 'accel' else 'gyroSensor'] in (35, 16)
            if uncalibrated:
                values -= np.array([float(row[k]) for k in ('bx', 'by', 'bz')])
            elif any(row[k] for k in ('bx', 'by', 'bz')):
                raise ValueError('Unexpected bias on calibrated Android sensor')
            if np.max(np.abs(values)) > (200 if sensor == 'accel' else 100):
                raise ValueError('Motion exceeds evaluation input limits')
        if not np.all(np.isfinite(values)):
            raise ValueError('Non-finite motion observation')
        if streams[sensor] and seconds <= streams[sensor][-1][0]:
            raise ValueError('Duplicate or reversed sensor timestamps')
        streams[sensor].append((seconds, values))
    if count != footer.get('samples'):
        raise ValueError('Motion footer count disagrees with rows')
    result, quality = {}, {}
    for sensor, rows in streams.items():
        if len(rows) < 200:
            raise ValueError(f'Insufficient {sensor} observations')
        stamps = np.array([r[0] for r in rows])
        values = np.stack([r[1] for r in rows])
        dt = np.diff(stamps)
        rate = 1 / np.median(dt)
        # Upsampling sparse step-era data does not create a real 200 Hz stream.
        if rate < 180:
            raise ValueError(f'{sensor} sample rate {rate:.1f} Hz is below the evaluation requirement')
        quality[sensor] = {'samples': len(rows), 'medianHz': float(rate),
            'maximumGapMs': float(dt.max() * 1000), 'gapsOver25ms': int(np.sum(dt > MAX_GAP))}
        result[sensor] = (stamps, values)
    return metadata, result, quality


def interpolate(stamps, values, grid, rotation=False):
    left = np.clip(np.searchsorted(stamps, grid, side='right') - 1, 0, len(stamps) - 2)
    dt = stamps[left + 1] - stamps[left]
    fraction = ((grid - stamps[left]) / dt)[:, None]
    good = (grid >= stamps[left] - 1e-9) & (grid <= stamps[left + 1] + 1e-9) & (dt <= MAX_GAP + 1e-9)
    a, b = values[left], values[left + 1]
    if not rotation:
        return a + fraction * (b - a), good
    # Quaternion SLERP handles antipodal representations of the same attitude.
    dot = np.sum(a * b, axis=1, keepdims=True)
    b = np.where(dot < 0, -b, b)
    dot = np.abs(dot).clip(0, 1)
    angle = np.arccos(dot)
    sine = np.sin(angle)
    near = sine < 1e-6
    safe = np.where(near, 1, sine)
    curved = np.sin((1 - fraction) * angle) / safe * a + np.sin(fraction * angle) / safe * b
    q = np.where(near, a + fraction * (b - a), curved)
    return q / np.linalg.norm(q, axis=1, keepdims=True), good


def rotate(q, vector):
    # Android quaternion rotates device-frame vectors into game-rotation world.
    xyz = q[:, 1:]
    twice = 2 * np.cross(xyz, vector)
    return vector + q[:, :1] * twice + np.cross(xyz, twice)


def features(streams):
    start = max(s[0][0] for s in streams.values())
    end = min(s[0][-1] for s in streams.values())
    grid = np.arange(math.ceil(start / PERIOD), math.floor(end / PERIOD) + 1) * PERIOD
    if len(grid) < 211:
        raise ValueError('Need more than one second of overlapping motion')
    accel, ga = interpolate(*streams['accel'], grid)
    gyro, gg = interpolate(*streams['gyro'], grid)
    q, gr = interpolate(*streams['rotation'], grid, rotation=True)
    data = np.c_[rotate(q, gyro), rotate(q, accel)].astype(np.float32)
    coverage = np.ones(len(grid), dtype=bool)
    for stamps, _ in streams.values():
        counts = np.searchsorted(stamps, grid, side='right') - np.searchsorted(stamps, grid-1, side='left')
        coverage &= counts >= 180
    return grid, data, ga & gg & gr, coverage


def load_model():
    for name in ('model_resnet1d.py', 'ronin_resnet.zip'):
        path = ROOT / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != ASSETS[name][1]:
            raise ValueError('Missing or changed model asset; run scripts/motion/setup.py')
    spec = importlib.util.spec_from_file_location('kaze_pinned_resnet', ROOT / 'model_resnet1d.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    with zipfile.ZipFile(ROOT / 'ronin_resnet.zip') as archive:
        item = archive.getinfo('ronin_resnet/checkpoint_gsn_latest.pt')
        if item.file_size > 80_000_000:
            raise ValueError('Unexpected checkpoint size')
        checkpoint = torch.load(io.BytesIO(archive.read(item)), map_location='cpu', weights_only=True)
    state = checkpoint['model_state_dict']
    if any(not isinstance(v, torch.Tensor) or not torch.isfinite(v).all() for v in state.values()):
        raise ValueError('Invalid checkpoint tensors')
    model = module.ResNet1D(6, 2, module.BasicBlock1D, [2, 2, 2, 2], base_plane=64,
        output_block=module.FCOutputModule, fc_dim=512, in_dim=7, dropout=.5, trans_planes=128)
    model.load_state_dict(state, strict=True)
    model.eval()
    return model


def predict(grid, data, good, coverage, model):
    ends = np.array([i for i in range(200, len(grid), 10) if good[i-200:i+1].all() and coverage[i]])
    if len(ends) < 2:
        raise ValueError('No adequate continuous windows; missing data remains a gap')
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    velocities = []
    started = time.perf_counter()
    with torch.inference_mode():
        for offset in range(0, len(ends), 64):
            batch = np.stack([data[i-200:i].T for i in ends[offset:offset+64]])
            value = model(torch.from_numpy(batch)).cpu().numpy()
            if value.shape != (len(batch), 2) or not np.isfinite(value).all():
                raise ValueError('Invalid model output')
            velocities.extend(value)
    elapsed = time.perf_counter() - started
    segments, segment, previous = [], None, None
    for index, velocity in zip(ends, velocities):
        if np.linalg.norm(velocity) > 5:
            segment = None; previous = None; continue
        if previous is None or index != previous[0] + 10:
            segment = []; segments.append(segment); position = np.zeros(2)
        else:
            position += .5 * (velocity + previous[1]) * (grid[index] - grid[previous[0]])
        segment.append({'t': float(grid[index]), 'x': float(position[0]), 'y': float(position[1]),
            'height': None, 'estimated': True, 'uncertaintyMeters': None})
        previous = (index, velocity)
    segments = [s for s in segments if len(s) >= 2]
    if not segments:
        raise ValueError('No supported motion estimates')
    return segments, {'windows': len(ends), 'inferenceSeconds': elapsed,
        'millisecondsPerWindow': elapsed * 1000 / len(ends), 'device': 'cpu'}


def compare_reference(segments, reference):
    with Path(reference).open(encoding='utf-8', newline='') as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != ['t_s', 'x_m', 'y_m']:
            raise ValueError('Reference requires t_s,x_m,y_m columns in a measured local frame')
        rows = [[float(r[k]) for k in reader.fieldnames] for r in reader]
    ref = np.array(rows)
    if len(ref) < 4 or not np.isfinite(ref).all() or np.any(np.diff(ref[:, 0]) <= 0):
        raise ValueError('Need four or more chronological independently measured reference points')
    # Never interpolate a trajectory across a missing-motion segment.
    eligible = [s for s in segments if s[0]['t'] <= ref[0, 0] and s[-1]['t'] >= ref[-1, 0]]
    if not eligible:
        raise ValueError('Reference crosses unsupported motion or lies outside a continuous segment')
    s = eligible[0]
    stamps = np.array([p['t'] for p in s])
    xy = np.array([[p['x'], p['y']] for p in s])
    prediction = np.column_stack([np.interp(ref[:, 0], stamps, xy[:, i]) for i in range(2)])
    a, b = prediction[1] - prediction[0], ref[1, 1:] - ref[0, 1:]
    na, nb = np.linalg.norm(a), np.linalg.norm(b)
    if min(na, nb) < 5:
        raise ValueError('First two reference points need a baseline of at least 5 m')
    c, sine = np.dot(a, b)/(na*nb), (a[0]*b[1] - a[1]*b[0])/(na*nb)
    rotation = np.array([[c, -sine], [sine, c]])
    aligned = (prediction - prediction[0]) @ rotation.T + ref[0, 1:]
    error = np.linalg.norm(aligned[2:] - ref[2:, 1:], axis=1)
    return {'registrationPoints': 2, 'evaluatedPoints': len(error),
        'rmseMeters': float(np.sqrt(np.mean(error**2))), 'maximumErrorMeters': float(error.max()),
        'endpointErrorMeters': float(error[-1]), 'referenceBaselineMeters': float(nb),
        'estimatedBaselineMeters': float(na), 'scaleAdjusted': False,
        'independentReferenceSuppliedByUser': True,
        'note': 'First two points set yaw and translation; errors use later points. No scale fitting or uncertainty calibration.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path)
    parser.add_argument('--out', type=Path, required=True, help='New ignored directory for local results')
    parser.add_argument('--reference', type=Path, help='Independent measured waypoints: t_s,x_m,y_m')
    args = parser.parse_args()
    try:
        if args.out.exists():
            raise ValueError('Output directory already exists; choose a new directory to preserve previous evidence')
        metadata, streams, quality = read_capture(args.capture)
        grid, data, good, coverage = features(streams)
        model = load_model()
        segments, performance = predict(grid, data, good, coverage, model)
        reference = compare_reference(segments, args.reference) if args.reference else None
        distance = sum(sum(math.hypot(b['x']-a['x'], b['y']-a['y']) for a,b in zip(s,s[1:])) for s in segments)
        report = {'version': 1, 'researchOnly': True, 'guidanceAllowed': False,
            'source': 'phone', 'frame': metadata['frame'], 'units': 'meters', 'geographic': False,
            'model': 'RoNIN ResNet', 'upstreamCommit': UPSTREAM,
            'checkpointArchiveSha256': ASSETS['ronin_resnet.zip'][1], 'captureSha256': hashlib.sha256(args.capture.read_bytes()).hexdigest(),
            'quality': quality, 'performance': performance, 'estimatedDistanceMeters': distance,
            'independentReference': reference, 'fieldAccuracyVerified': False, 'confidenceCalibrated': False,
            'segments': segments, 'warnings': [
                'Relative motion only: geographic position and yaw are unknown.',
                'Reported Android bias compensation is used; no laboratory sensor scale calibration was performed.',
                'The initial second, gaps, unsupported sampling and outputs over 5 m/s are not reconstructed.',
                'No height, floors, walls, stairs or navigation guidance are inferred.',
                'A measured reference comparison is required before claiming improvement.']}
        args.out.mkdir(parents=True)
        (args.out / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False), encoding='utf-8')
        with (args.out / 'estimated-trail.csv').open('w', newline='', encoding='utf-8') as stream:
            writer = csv.writer(stream); writer.writerow(['segment', 't_s', 'x_m', 'y_m'])
            for index, segment in enumerate(segments):
                writer.writerows([index, p['t'], p['x'], p['y']] for p in segment)
        print(json.dumps({'segments': len(segments), 'performance': performance, 'referenceComparison': reference,
            'estimatedDistanceMeters': distance, 'fieldAccuracyVerified': False}, allow_nan=False))
    except (ValueError, KeyError, OSError, csv.Error, json.JSONDecodeError) as error:
        parser.exit(2, f'Motion evaluation refused: {error}\n')


if __name__ == '__main__':
    main()
