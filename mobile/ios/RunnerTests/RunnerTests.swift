import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testReviewReminderUsesServerRelativeDeadlineAndNeverSurvivesKnownExpiry() {
    var data: [String: Any] = ["phase": "armed", "serverNow": 1000, "dueAt": 6000,
      "graceSeconds": 3, "expiresAt": 20000, "acknowledged": false]
    XCTAssertEqual(GuardianReminderPlan(data)?.delay, 8)
    data["serverNow"] = 10000
    XCTAssertEqual(GuardianReminderPlan(data)?.delay, 1)
    data["serverNow"] = 20000
    XCTAssertNil(GuardianReminderPlan(data))
  }

  func testEndedAcknowledgedOrInvalidSessionsCannotScheduleReviewReminders() {
    var data: [String: Any] = ["phase": "resolved", "serverNow": 1000, "dueAt": 6000,
      "graceSeconds": 3, "expiresAt": 20000, "acknowledged": false]
    XCTAssertNil(GuardianReminderPlan(data))
    data["phase"] = "alert"; data["acknowledged"] = true
    XCTAssertNil(GuardianReminderPlan(data))
    data["acknowledged"] = false; data["expiresAt"] = 8000
    XCTAssertNil(GuardianReminderPlan(data))
    data["expiresAt"] = 20000; data["dueAt"] = Double.nan
    XCTAssertNil(GuardianReminderPlan(data))
  }

}
