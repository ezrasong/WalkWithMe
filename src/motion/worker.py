"""Bounded backend research evaluation. Raw batches remain in process memory."""
import base64
import gzip
import io
import json
import math
import sys
import torch

from evaluate import read_capture_text, features, load_model, predict


def evaluate_batch(encoded, model):
    if not isinstance(encoded, str) or len(encoded) > 240000:
        raise ValueError('Motion batch exceeds the upload limit')
    compressed = base64.b64decode(encoded, validate=True)
    with gzip.GzipFile(fileobj=io.BytesIO(compressed)) as stream:
        raw = stream.read(1_000_001)
    if len(raw) > 1_000_000:
        raise ValueError('Expanded motion batch exceeds the limit')
    metadata, streams, quality = read_capture_text(raw.decode('utf-8'))
    if max(s[0][-1] for s in streams.values()) > 12:
        raise ValueError('Motion batch exceeds twelve seconds')
    grid, data, good, coverage = features(streams)
    segments, performance = predict(grid, data, good, coverage, model)
    distance = sum(sum(math.hypot(b['x']-a['x'], b['y']-a['y'])
        for a, b in zip(s, s[1:])) for s in segments)
    # Return at most 5 points/second. Model input stays at its required 200 Hz.
    reduced = []
    for segment in segments:
        points = segment[::4]
        if points[-1] is not segment[-1]:
            points.append(segment[-1])
        reduced.append(points)
    return {'researchOnly': True, 'guidanceAllowed': False, 'geographic': False,
        'fieldAccuracyVerified': False, 'confidenceCalibrated': False,
        'frame': metadata['frame'], 'captureStartedUtcMs': metadata.get('startedUtcMs'),
        'independentBatchOrigin': True, 'estimatedDistanceMeters': distance,
        'quality': quality, 'performance': performance, 'segments': reduced}


def main():
    torch.set_num_threads(4)
    model = load_model()
    print(json.dumps({'ready': True}), flush=True)
    while True:
        line = sys.stdin.buffer.readline(250001)
        if not line:
            return
        if len(line) > 250000 or not line.endswith(b'\n'):
            return  # Framing violated: do not attempt to recover in this process.
        try:
            request = json.loads(line)
            result = evaluate_batch(request['captureGzip'], model)
            print(json.dumps({'result': result}, allow_nan=False), flush=True)
        except (ValueError, KeyError, TypeError, OSError, EOFError) as error:
            # Do not emit raw samples or request contents in errors/logs.
            print(json.dumps({'error': 'Motion batch rejected: unsupported or incomplete sensor data.'}), flush=True)
        finally:
            # Do not keep the previous raw request while waiting for the next batch.
            line = None
            request = None
            result = None


if __name__ == '__main__':
    main()
