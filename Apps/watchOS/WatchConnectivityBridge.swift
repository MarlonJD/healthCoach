import Foundation
import HealthCoachKit
import WatchConnectivity

final class WatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let session = WCSession.default
    var onTransfer: (@Sendable (Data) -> Void)?
    var onActivated: (@Sendable () -> Void)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func send(command: WatchCommand) {
        send(WatchTransfer(kind: "command", command: command))
    }

    func send(acknowledgment: WatchCommandAck) {
        send(WatchTransfer(kind: "acknowledgment", acknowledgment: acknowledgment))
    }

    func send(_ transfer: WatchTransfer) {
        guard isCounterpartReady, let data = try? HealthCoachJSON.encode(transfer) else { return }
        session.transferUserInfo(["healthcoach.transfer": data])
    }

    func receiveInitialContext() -> Data? {
        session.receivedApplicationContext["healthcoach.snapshot"] as? Data
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated, error == nil else { return }
        onActivated?()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["healthcoach.snapshot"] as? Data else { return }
        guard let snapshot = try? HealthCoachJSON.decode(WatchWorkoutSnapshot.self, from: data),
              let transfer = try? HealthCoachJSON.encode(WatchTransfer(kind: "snapshot", snapshot: snapshot)) else { return }
        onTransfer?(transfer)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["healthcoach.transfer"] as? Data else { return }
        onTransfer?(data)
    }

    private var isCounterpartReady: Bool {
        guard WCSession.isSupported(), session.activationState == .activated else { return false }
        return session.isCompanionAppInstalled
    }
}
