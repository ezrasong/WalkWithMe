"""Bounded backend research evaluation. Raw batches remain in process memory."""
import base64
import gzip
import io
import json
import math
import sys
import re
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
    stream = None
    if metadata.get('streamVersion') not in (None, 2):
        raise ValueError('Unsupported stream version')
    if metadata.get('streamVersion') == 2:
        stream_id, sequence = metadata.get('streamId'), metadata.get('batchSequence')
        origin, utc = metadata.get('streamStartedNs'), metadata.get('streamStartedUtcMs')
        clock_error = metadata.get('clockUncertaintyMs')
        if (not isinstance(stream_id, str) or not re.fullmatch(r'[a-f0-9-]{36}', stream_id) or
            type(sequence) is not int or not 0 <= sequence <= 100000 or
            type(origin) is not int or not 0 <= origin <= metadata['startedNs'] <= 2**53-1 or
            type(utc) is not int or not 0 < utc < 2**53 or
            type(clock_error) is not int or not 0 <= clock_error <= 5000):
            raise ValueError('Invalid stream identity or clock')
        offset = (metadata['startedNs'] - origin) / 1e9
        if type(metadata.get('startedUtcMs')) is not int or abs(metadata['startedUtcMs'] - (utc + offset * 1000)) > 2:
            raise ValueError('Inconsistent monotonic and UTC mapping')
        if offset > 86400:
            raise ValueError('Stream exceeds session duration')
        # Grid and model stride share the stream monotonic origin. Overlap is
        # context, not another displacement; the server commits each time once.
        streams = {k: (stamps + offset, values) for k, (stamps, values) in streams.items()}
        stream = {'id': stream_id, 'sequence': sequence, 'startedNs': origin,
            'startedUtcMs': utc, 'clockUncertaintyMs': clock_error}
    grid, data, good, coverage = features(streams)
    if stream:
        # Align 20 Hz prediction ends across arbitrary batch boundary jitter.
        shift = (-round(grid[0] / .005)) % 10
        grid, data, good, coverage = grid[shift:], data[shift:], good[shift:], coverage[shift:]
    segments, performance = predict(grid, data, good, coverage, model, stationary_gate=bool(stream))
    distance = sum(sum(math.hypot(b['x']-a['x'], b['y']-a['y'])
        for a, b in zip(s, s[1:])) for s in segments)
    # Streaming returns 20 Hz velocities for integration; retained shared points
    # are reduced by the server. Legacy batch previews return at most 5 Hz.
    reduced = []
    for segment in segments:
        points = segment if stream else segment[::4]
        if points[-1] is not segment[-1]:
            points.append(segment[-1])
        reduced.append(points)
    return {'researchOnly': True, 'guidanceAllowed': False, 'geographic': False,
        'fieldAccuracyVerified': False, 'confidenceCalibrated': False,
        'frame': metadata['frame'], 'captureStartedUtcMs': metadata.get('startedUtcMs'),
        'independentBatchOrigin': stream is None, 'stream': stream, 'estimatedDistanceMeters': distance,
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
