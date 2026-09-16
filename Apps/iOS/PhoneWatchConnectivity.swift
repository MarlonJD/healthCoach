import Foundation
import HealthCoachKit
import WatchConnectivity

final class PhoneWatchConnectivityBridge: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let session = WCSession.default
    var onTransfer: (@Sendable (Data) -> Void)?
    var onActivated: (@Sendable () -> Void)?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
    }

    func send(_ transfer: WatchTransfer) {
        guard isCounterpartReady, let data = try? HealthCoachJSON.encode(transfer) else { return }
        session.transferUserInfo(["healthcoach.transfer": data])
    }

    func send(snapshot: WatchWorkoutSnapshot) {
        guard isCounterpartReady, let data = try? HealthCoachJSON.encode(snapshot) else { return }
        do { try session.updateApplicationContext(["healthcoach.snapshot": data]) } catch { }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated, error == nil else { return }
        onActivated?()
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        // The phone is canonical; a Watch snapshot is never accepted as phone state.
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["healthcoach.transfer"] as? Data else { return }
        onTransfer?(data)
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) { }
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    #endif

    private var isCounterpartReady: Bool {
        guard WCSession.isSupported(), session.activationState == .activated else { return false }
        #if os(iOS)
        return session.isPaired && session.isWatchAppInstalled
        #else
        return session.isCompanionAppInstalled
        #endif
    }
}
