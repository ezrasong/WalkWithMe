import ARKit
import AVFoundation
import CoreLocation
import Flutter
import RealityKit
import UIKit

// No networking, frame extraction, image capture, recording or persistence.
final class GuardianArPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
  private let location = CLLocationManager()
  private var pending: FlutterResult?
  private var waitingLocation = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = GuardianArPlugin()
    plugin.location.delegate = plugin
    registrar.addMethodCallDelegate(plugin, channel: FlutterMethodChannel(
      name: "app.kaze/session", binaryMessenger: registrar.messenger()))
    registrar.register(GuardianArFactory(messenger: registrar.messenger()), withId: "app.kaze/guardian-ar")
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "prepareGuardianAr" else { result(FlutterMethodNotImplemented); return }
    guard ARWorldTrackingConfiguration.isSupported else { result("ARKit world tracking unsupported. Use the map."); return }
    guard pending == nil else { result("Permission request pending."); return }
    pending = result
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized: authorizeLocation()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { granted in
        DispatchQueue.main.async {
          if granted { self.authorizeLocation() } else { self.finish("Camera permission denied. Use the map.") }
        }
      }
    default: finish("Camera permission denied. Use the map.")
    }
  }

  private func authorizeLocation() {
    switch location.authorizationStatus {
    case .authorizedWhenInUse, .authorizedAlways:
      finish(location.accuracyAuthorization == .fullAccuracy ? "ready" : "Precise location required. Use the map.")
    case .notDetermined: waitingLocation = true; location.requestWhenInUseAuthorization()
    default: finish("Location permission denied. Use the map.")
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if waitingLocation && pending != nil && manager.authorizationStatus != .notDetermined { authorizeLocation() }
  }

  private func finish(_ value: String) { let result = pending; pending = nil; waitingLocation = false; result?(value) }
}

final class GuardianArFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    GuardianArView(frame: frame, id: viewId, messenger: messenger)
  }
}

final class GuardianArView: NSObject, FlutterPlatformView, ARSessionDelegate, CLLocationManagerDelegate {
  private let scene: ARView
  private let location = CLLocationManager()
  private let channel: FlutterMethodChannel
  private var fix: CLLocation?
  private var lastFix: TimeInterval = 0
  private var lease: TimeInterval = 0
  private var opened: TimeInterval = 0
  private var started = false
  private var tracked = false
  private let dots = AnchorEntity(world: SIMD3<Float>.zero)
  private var backgroundObserver: NSObjectProtocol?

  init(frame: CGRect, id: Int64, messenger: FlutterBinaryMessenger) {
    scene = ARView(frame: frame, cameraMode: .ar, automaticallyConfigureSession: false)
    channel = FlutterMethodChannel(name: "app.kaze/guardian-ar/\(id)", binaryMessenger: messenger)
    super.init()
    scene.scene.anchors.append(dots)
    scene.session.delegate = self
    // All callbacks mutate scene, location and lease on one queue.
    scene.session.delegateQueue = .main
    location.delegate = self
    location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    location.distanceFilter = kCLDistanceFilterNone
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(nil); return }
      switch call.method {
      case "start": self.start(); result(nil)
      case "render":
        if self.started, self.tracked, let points = call.arguments as? [[String: Any]], points.count <= 200 {
          self.draw(points); self.lease = ProcessInfo.processInfo.systemUptime
        }
        result(nil)
      case "stop": self.stop(); result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
      object: nil, queue: .main) { [weak self] _ in self?.fail() }
  }

  func view() -> UIView { scene }
  private func start() {
    guard !started, ARWorldTrackingConfiguration.isSupported,
      AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
      location.authorizationStatus == .authorizedWhenInUse || location.authorizationStatus == .authorizedAlways,
      location.accuracyAuthorization == .fullAccuracy else { fail(); return }
    started = true
    opened = ProcessInfo.processInfo.systemUptime
    let configuration = ARWorldTrackingConfiguration()
    configuration.worldAlignment = .gravity
    // Local visual-inertial tracking only; no geo/cloud anchors or image upload.
    scene.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    location.startUpdatingLocation()
  }

  private func stop() {
    started = false; tracked = false; lease = 0; fix = nil
    scene.session.pause(); location.stopUpdatingLocation()
    dots.children.forEach { $0.removeFromParent() }
    scene.isHidden = true
  }
  private func fail() { stop(); channel.invokeMethod("failure", arguments: nil) }
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { fix = locations.last }
  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { fail() }
  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    if started && (manager.accuracyAuthorization != .fullAccuracy ||
      !(manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse)) { fail() }
  }
  func session(_ session: ARSession, didFailWithError error: Error) { fail() }
  func sessionWasInterrupted(_ session: ARSession) { fail() }
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard started else { return }
    let uptime = ProcessInfo.processInfo.systemUptime
    if (lease == 0 && uptime - opened > 15) || (lease > 0 && uptime - lease > 2.5) { fail(); return }
    guard case .normal = frame.camera.trackingState else {
      if tracked { fail() }; return
    }
    tracked = true
    guard let fix = fix, fix.timestamp.timeIntervalSince1970 > lastFix else { return }
    let age = Date().timeIntervalSince(fix.timestamp) - (uptime - frame.timestamp)
    // Do not pair cached positions with a newer camera pose.
    guard age >= 0 && age <= 0.2 else { return }
    lastFix = fix.timestamp.timeIntervalSince1970
    let p = frame.camera.transform.columns.3
    channel.invokeMethod("sample", arguments: [
      "t": lastFix, "x": Double(p.x), "y": Double(p.y), "z": Double(p.z),
      "latitude": fix.coordinate.latitude, "longitude": fix.coordinate.longitude,
      "accuracy": fix.horizontalAccuracy, "altitude": fix.ellipsoidalAltitude,
      "verticalAccuracy": fix.verticalAccuracy, "altitudeDatum": "WGS84-ellipsoid",
      "ageMs": age * 1000, "mock": fix.sourceInformation?.isSimulatedBySoftware ?? false
    ])
  }

  private func draw(_ points: [[String: Any]]) {
    dots.children.forEach { $0.removeFromParent() }
    for p in points {
      guard let x = p["x"] as? Double, let y = p["y"] as? Double, let z = p["z"] as? Double,
        let radius = p["uncertainty"] as? Double, let vertical = p["verticalUncertainty"] as? Double,
        [x, y, z, radius, vertical].allSatisfy({ $0.isFinite }),
        radius > 0, radius <= 10, vertical > 0, vertical <= 10 else { continue }
      let color: UIColor = p["source"] as? String == "watch" ? .systemOrange : .cyan
      let material = UnlitMaterial(color: color)
      let group = Entity()
      group.position = SIMD3<Float>(Float(x), Float(y), Float(z))
      group.addChild(ModelEntity(mesh: .generateSphere(radius: 0.18), materials: [material]))
      // A metric horizontal annulus, not a screen-space compass decoration.
      var positions = [SIMD3<Float>]()
      var indices = [UInt32]()
      for i in 0..<48 {
        let angle = Float(i) * .pi / 24
        for r in [max(0, Float(radius) - 0.025), Float(radius) + 0.025] {
          positions.append(SIMD3<Float>(r * cos(angle), 0, r * sin(angle)))
        }
        let a = UInt32(i * 2), b = UInt32(((i + 1) % 48) * 2)
        indices += [a, b, a + 1, a + 1, b, b + 1,
                    a + 1, b, a, b + 1, b, a + 1]
      }
      var descriptor = MeshDescriptor(name: "Reported uncertainty")
      descriptor.positions = MeshBuffers.Positions(positions)
      descriptor.primitives = .triangles(indices)
      guard let ring = try? MeshResource.generate(from: [descriptor]) else { fail(); return }
      group.addChild(ModelEntity(mesh: ring, materials: [material]))
      group.addChild(ModelEntity(mesh: .generateBox(size: SIMD3<Float>(0.04, Float(2 * vertical), 0.04)), materials: [material]))
      dots.addChild(group)
    }
  }
  deinit {
    if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    scene.session.pause(); location.stopUpdatingLocation(); channel.setMethodCallHandler(nil)
  }
}
