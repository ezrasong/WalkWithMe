import csv
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'src' / 'motion'))
import tempfile
import unittest
import numpy as np
import torch
import base64
import gzip
from evaluate import read_capture, features, rotate, interpolate, predict, compare_reference, load_model, ROOT
from worker import evaluate_batch


class ConstantVelocity(torch.nn.Module):
    def forward(self, x):
        return torch.tensor([1., 0.]).expand(len(x), 2)


def capture(path, hz=200, gap=False):
    metadata = {'version': 1, 'source': 'phone', 'clock': 'elapsedRealtimeNanos', 'startedNs': 1000000000000,
        'frame': 'Android-game-rotation-z-up-yaw-unknown', 'accelSensor': 35, 'gyroSensor': 16,
        'rotationSensor': 15, 'accelerationUnits': 'm/s^2-including-gravity', 'angularRateUnits': 'rad/s'}
    rows = []
    for t in np.arange(0, 4.001, 1/hz):
        if gap and 1.4 <= t <= 1.5:
            continue
        stamp = metadata['startedNs'] + round(t*1e9)
        rows += [[stamp, 'accel', .1, .2, 9.81+.3, '', .1, .2, .3],
            [stamp, 'gyro', .1, .2, .3, '', .1, .2, .3],
            [stamp, 'rotation', 0, 0, 0, 1, '', '', '']]
    with path.open('w', encoding='utf-8', newline='') as f:
        f.write('# '+json.dumps(metadata)+'\n')
        writer=csv.writer(f);writer.writerow(['t_ns','sensor','x','y','z','w','bx','by','bz']);writer.writerows(rows)
        f.write('# '+json.dumps({'complete':True,'reason':'user-stopped','samples':len(rows)})+'\n')


class MotionEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)/'capture.csv'
        capture(self.path)

    def test_real_units_bias_compensation_and_relative_frame(self):
        metadata, streams, quality=read_capture(self.path)
        grid,data,good,coverage=features(streams)
        self.assertEqual(metadata['source'],'phone')
        self.assertAlmostEqual(quality['gyro']['medianHz'],200)
        np.testing.assert_allclose(data[:, :3],0,atol=1e-6)
        np.testing.assert_allclose(data[:, 3:],[0,0,9.81]*np.ones((len(data),1)),atol=1e-5)
        self.assertTrue(good.all())

    def test_low_rate_data_is_rejected_instead_of_manufacturing_200hz(self):
        capture(self.path,hz=50)
        with self.assertRaisesRegex(ValueError,'sample rate'):read_capture(self.path)

    def test_streaming_batch_decompresses_bounded_data_and_returns_separate_relative_segments(self):
        encoded = base64.b64encode(gzip.compress(self.path.read_bytes())).decode()
        result = evaluate_batch(encoded, ConstantVelocity())
        self.assertTrue(result['independentBatchOrigin'])
        self.assertFalse(result['guidanceAllowed'])
        self.assertFalse(result['geographic'])
        self.assertLessEqual(len(result['segments'][0]), 17)
        self.assertAlmostEqual(result['segments'][0][0]['x'], 0)
        self.assertGreater(result['estimatedDistanceMeters'], 2)
        with self.assertRaisesRegex(ValueError, 'Expanded'):
            evaluate_batch(base64.b64encode(gzip.compress(b'x'*1_000_001)).decode(), ConstantVelocity())
        with self.assertRaises(ValueError): evaluate_batch('!'*100, ConstantVelocity())

    def test_mixed_sparse_windows_are_not_hidden_by_global_median_rate(self):
        _, streams, _ = read_capture(self.path)
        for name, (stamps, values) in list(streams.items()):
            keep = (stamps < 2) | (np.arange(len(stamps)) % 2 == 0)
            streams[name] = (stamps[keep], values[keep])
        grid, data, good, coverage = features(streams)
        segments, _ = predict(grid, data, good, coverage, ConstantVelocity())
        self.assertLess(segments[-1][-1]['t'], 2.3)

    def test_bad_units_and_incomplete_capture_are_rejected(self):
        s=self.path.read_text(encoding='utf-8')
        self.path.write_text(s.replace('m/s^2-including-gravity','g'),encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'units'):read_capture(self.path)
        self.path.write_text(s[:s.rfind('# ')],encoding='utf-8')
        with self.assertRaisesRegex(ValueError,'incomplete'):read_capture(self.path)

    def test_missing_samples_split_estimates_without_connecting_motion(self):
        capture(self.path,gap=True)
        _,streams,quality=read_capture(self.path)
        grid,data,good,coverage=features(streams)
        segments,_=predict(grid,data,good,coverage,ConstantVelocity())
        self.assertEqual(len(segments),2)
        self.assertEqual(segments[1][0]['x'],0)
        self.assertLess(segments[0][-1]['t'],1.4)
        self.assertGreater(segments[1][0]['t'],2.4)
        self.assertGreater(quality['accel']['gapsOver25ms'],0)
        self.assertIsNone(segments[0][0]['height'])
        self.assertIsNone(segments[0][0]['uncertaintyMeters'])

    def test_rotation_and_antipodal_quaternions_preserve_gravity(self):
        angle=np.pi/2;q=np.array([[np.cos(angle/2),0,0,np.sin(angle/2)]])
        np.testing.assert_allclose(rotate(q,np.array([[1.,0,0]])),[[0,1,0]],atol=1e-8)
        stamps=np.array([0.,.005]);values=np.concatenate([q,-q])
        out,good=interpolate(stamps,values,np.array([.0025]),rotation=True)
        np.testing.assert_allclose(out,q,atol=1e-8);self.assertTrue(good.all())

    def test_reference_uses_first_two_points_for_registration_and_later_points_for_error(self):
        ref=Path(self.tmp.name)/'reference.csv'
        ref.write_text('t_s,x_m,y_m\n1,0,0\n7,0,6\n13,0,12\n19,0,18\n',encoding='utf-8')
        segments=[[{'t':i,'x':i-1.,'y':0.} for i in range(1,20)]]
        report=compare_reference(segments,ref)
        self.assertAlmostEqual(report['rmseMeters'],0)
        self.assertEqual(report['registrationPoints'],2)
        self.assertEqual(report['evaluatedPoints'],2)
        self.assertFalse(report['scaleAdjusted'])
        with self.assertRaisesRegex(ValueError,'unsupported'):compare_reference([segments[0][:10],segments[0][11:]],ref)

    @unittest.skipUnless((ROOT/'ronin_resnet.zip').exists(),'Run setup.py for the checkpoint smoke test')
    def test_actual_pretrained_weights_load_and_run_with_finite_outputs(self):
        _,streams,_=read_capture(self.path)
        grid,data,good,coverage=features(streams)
        segments,performance=predict(grid,data,good,coverage,load_model())
        self.assertGreater(performance['windows'],0)
        self.assertTrue(all(np.isfinite(p['x']) for s in segments for p in s))
        # Synthetic input verifies execution, not measured physical accuracy.


if __name__=='__main__':unittest.main()
