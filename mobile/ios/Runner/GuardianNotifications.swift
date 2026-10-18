import Flutter
import CryptoKit
import UIKit
import UserNotifications

// A local deadline is a prompt to review, never evidence of server-confirmed nonresponse.
struct GuardianReminderPlan {
  let deadline: Double
  let delay: Double
  init?(_ data: [String: Any]) {
    guard let phase = data["phase"] as? String, ["armed", "challenge", "alert"].contains(phase),
      data["acknowledged"] as? Bool != true,
      let now = (data["serverNow"] as? NSNumber)?.doubleValue, now.isFinite,
      let expires = (data["expiresAt"] as? NSNumber)?.doubleValue, expires.isFinite, expires > now,
      let due = (data["dueAt"] as? NSNumber)?.doubleValue, due.isFinite,
      let grace = (data["graceSeconds"] as? NSNumber)?.doubleValue, grace.isFinite, grace >= 0, grace <= 300
    else { return nil }
    deadline = due + grace * 1000
    guard deadline < expires else { return nil }
    delay = max(1, min(24 * 3600, (deadline - now) / 1000))
  }
}

final class GuardianNotifications {
  static let shared = GuardianNotifications()
  private let center = UNUserNotificationCenter.current()
  private let defaults = UserDefaults.standard
  private var state: [String: Any] {
    get { defaults.dictionary(forKey: "kazeGuardianNotifications") ?? [:] }
    set { defaults.set(newValue, forKey: "kazeGuardianNotifications") }
  }
  private var deviceToken: String?
  private var pendingToken: FlutterResult?
  private var tokenWait = UUID()
  private var operation = UUID()
  private var pushConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "KazePushEnabled") as? String == "YES" }
  private var environment: String { Bundle.main.object(forInfoDictionaryKey: "KazePushEnvironment") as? String ?? "development" }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "guardianPermissions":
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async {
          result(granted ? nil : FlutterError(code: "notifications", message: "Allow WalkWithMe notifications in iPhone Settings first.", details: nil))
        }
      }
    case "guardianStatus":
      center.getNotificationSettings { settings in
        DispatchQueue.main.async {
          let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
          var value = self.state
          value["notificationsAllowed"] = allowed
          value["pushAvailable"] = self.pushConfigured
          value["running"] = false // iOS has no continuously running monitor.
          value["mode"] = value["pushRegistered"] as? Bool == true ? "apple-push" : "local-reminder"
          value["status"] = !allowed ? "iPhone notifications blocked. Keep WalkWithMe open and review Settings." :
            value["tokenChanged"] as? Bool == true ? "Apple device registration changed. Turn notifications off and on while connected. Local review reminders only." :
            value["enabled"] as? Bool != true ?
              (value["pushRegistered"] as? Bool == true || value["pushPending"] as? Bool == true ?
                "Stopped locally. Remote removal is pending; reconnect and turn notifications off again." : "Off. Keep WalkWithMe open for updates.") :
            value["pushRegistered"] as? Bool == true ? "Apple push registered. Delivery still needs physical testing." :
            "Local review reminders only. Background session status is not verified."
          result(value)
        }
      }
    case "startGuardian":
      guard let raw = call.arguments as? String, let bytes = raw.data(using: .utf8),
        let data = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
        let id = data["id"] as? String, UUID(uuidString: id) != nil,
        GuardianReminderPlan(data) != nil else {
        result(FlutterError(code: "session", message: "Reconnect to an active guardian session first.", details: nil)); return
      }
      let started = UUID(); operation = started
      center.getNotificationSettings { settings in
        DispatchQueue.main.async {
          guard self.operation == started else {
            result(FlutterError(code: "cancelled", message: "Guardian setup cancelled.", details: nil)); return
          }
          guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            result(FlutterError(code: "notifications", message: "Allow WalkWithMe notifications in iPhone Settings first.", details: nil)); return
          }
          self.cancelReminder()
          // No guardian credential, private link or location is persisted by this helper.
          var next = self.state
          if next["sessionId"] as? String != id || next["registrationId"] == nil {
            next = ["sessionId": id, "registrationId": UUID().uuidString.lowercased()]
          }
          next["enabled"] = true; next.removeValue(forKey: "deadline")
          if next["pushRegistered"] as? Bool == true { next["pushPending"] = true }
          next["pushRegistered"] = false
          self.state = next
          self.update(data)
          result(nil)
        }
      }
    case "updateGuardian":
      if let data = call.arguments as? [String: Any] { update(data) }
      result(nil)
    case "stopGuardian":
      operation = UUID(); cancelReminder()
      if pendingToken != nil { registrationFailed() }
      var next = state; next["enabled"] = false; state = next
      // Keep registration metadata until the server confirms deregistration.
      result(nil)
    case "clearGuardianPush":
      cancelReminder(); state = [:]; result(nil)
    case "guardianPushRegistered":
      guard state["enabled"] as? Bool == true, call.arguments as? String == state["registrationId"] as? String else {
        result(FlutterError(code: "cancelled", message: "Guardian setup changed. Retry while WalkWithMe is open.", details: nil)); return
      }
      cancelReminder(); var next = state; next["pushRegistered"] = true; next["pushPending"] = false
      next["tokenFingerprint"] = deviceToken.map { fingerprint($0) }; next["tokenChanged"] = false
      state = next; result(nil)
    case "guardianPushPending":
      var next = state; next["pushPending"] = true; state = next; result(nil)
    case "guardianPushRegistration":
      guard pushConfigured, ["development", "production"].contains(environment), state["enabled"] as? Bool == true else {
        result(FlutterError(code: "push", message: "Apple push requires a paid-team signed build and server credentials. Local review reminders remain available.", details: nil)); return
      }
      guard pendingToken == nil else {
        result(FlutterError(code: "pending", message: "Apple registration already pending.", details: nil)); return
      }
      pendingToken = result
      if deviceToken != nil { finishToken(); return }
      let wait = UUID(); tokenWait = wait
      UIApplication.shared.registerForRemoteNotifications()
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
        if self.tokenWait == wait && self.pendingToken != nil {
          self.registrationFailed()
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  private func update(_ data: [String: Any]) {
    guard state["enabled"] as? Bool == true, data["id"] as? String == state["sessionId"] as? String else { return }
    guard let plan = GuardianReminderPlan(data) else { cancelReminder(); return }
    if state["pushRegistered"] as? Bool == true || state["deadline"] as? Double == plan.deadline { return }
    cancelReminder()
    let identifier = "kaze-guardian-review-" + UUID().uuidString
    var next = state; next["deadline"] = plan.deadline; next["requestIdentifier"] = identifier; state = next
    let content = UNMutableNotificationContent()
    content.title = "WalkWithMe guardian — simulation"
    content.body = "Time to review the session. Open WalkWithMe to check; background status has not been verified."
    content.sound = .default
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: plan.delay, repeats: false)
    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { error in
      DispatchQueue.main.async {
        guard self.state["requestIdentifier"] as? String == identifier else {
          self.center.removePendingNotificationRequests(withIdentifiers: [identifier]); return
        }
        if error != nil {
          var failed = self.state; failed["enabled"] = false; self.state = failed
        }
      }
    }
  }
  private func cancelReminder() {
    if let identifier = state["requestIdentifier"] as? String {
      center.removePendingNotificationRequests(withIdentifiers: [identifier])
      center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    var next = state; next.removeValue(forKey: "requestIdentifier"); state = next
    // Remove delivered pushes for this registration, without touching other sessions.
    if let registration = state["registrationId"] as? String {
      center.getDeliveredNotifications { delivered in
        self.center.removeDeliveredNotifications(withIdentifiers: delivered.filter {
          $0.request.content.userInfo["kazeRegistration"] as? String == registration
        }.map { $0.request.identifier })
      }
    }
  }
  func registered(_ token: Data) {
    deviceToken = token.map { String(format: "%02x", $0) }.joined()
    if let previous = state["tokenFingerprint"] as? String, let current = deviceToken,
      previous != fingerprint(current) {
      var next = state
      next["pushPending"] = next["pushRegistered"] as? Bool == true || next["pushPending"] as? Bool == true
      next["pushRegistered"] = false; next["tokenChanged"] = true; next.removeValue(forKey: "deadline")
      state = next
    }
    finishToken()
  }
  private func fingerprint(_ token: String) -> String {
    SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  func refreshRegistration() {
    if pushConfigured && state["enabled"] as? Bool == true { UIApplication.shared.registerForRemoteNotifications() }
  }
  func registrationFailed() {
    if state["pushRegistered"] as? Bool == true {
      var next = state; next["pushRegistered"] = false; next["pushPending"] = true
      next["tokenChanged"] = true; next.removeValue(forKey: "deadline"); state = next
    }
    let result = pendingToken; pendingToken = nil
    result?(FlutterError(code: "push", message: "Apple push registration failed. Local review reminders remain available. Check paid-team signing and Push Notifications capability.", details: nil))
  }
  private func finishToken() {
    guard let token = deviceToken, let registration = state["registrationId"] as? String, let result = pendingToken else { return }
    pendingToken = nil
    result(["deviceToken": token, "registrationId": registration, "environment": environment])
  }
  func shouldPresent(_ notification: UNNotification) -> Bool {
    if let registration = notification.request.content.userInfo["kazeRegistration"] as? String {
      return state["enabled"] as? Bool == true && state["registrationId"] as? String == registration
    }
    return notification.request.identifier == state["requestIdentifier"] as? String && state["enabled"] as? Bool == true
  }
}
