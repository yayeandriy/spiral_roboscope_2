import Foundation
import Network

/// Triggers iOS Local Network privacy prompt by briefly browsing a Bonjour service.
/// There is no direct API to query the authorization state, so we attempt a lightweight
/// NWBrowser on `_http._tcp` which is sufficient to trigger the system dialog if needed.
final class LocalNetworkPermission {
    static let shared = LocalNetworkPermission()
    private init() {}

    private var browser: NWBrowser?
    private var didComplete = false

    /// Request local network permission if needed. Completion is called after we made
    /// a best-effort attempt to trigger the prompt (or immediately if already authorized).
    func request(completion: @escaping () -> Void) {
        // If already in-flight, just return soon.
        if browser != nil { 
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { completion() }
            return
        }

        // Browse Bonjour HTTP services; this prompts the permission dialog if not granted.
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_http._tcp.", domain: nil)
        let params = NWParameters.tcp
        let browser = NWBrowser(for: descriptor, using: params)
        self.browser = browser
        self.didComplete = false

        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed(_), .cancelled:
                if !self.didComplete {
                    self.didComplete = true
                    DispatchQueue.main.async { completion() }
                }
            case .ready:
                // Permission likely granted; complete and stop browsing.
                if !self.didComplete {
                    self.didComplete = true
                    DispatchQueue.main.async { completion() }
                }
                self.stop()
            default:
                break
            }
        }

        browser.start(queue: .main)

        // Safety timeout: stop after 2 seconds to avoid lingering background work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self else { return }
            if !self.didComplete {
                self.didComplete = true
                self.stop()
                completion()
            }
        }
    }

    private func stop() {
        browser?.cancel()
        browser = nil
    }
}
