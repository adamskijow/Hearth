// SPDX-License-Identifier: MIT

import Foundation
import HearthMonitorCore

enum AppleModelSelfTest {
    static func run() async -> Int32 {
        let probe = AppleFoundationModelProbe()
        let availability = await probe.availability()
        switch availability {
        case .unavailable(let reason):
            fputs("Apple model self-test unavailable: \(reason.rawValue)\n", stderr)
            // This is an environment result rather than an app failure. Release
            // CI may run on an Intel Mac or with Apple Intelligence disabled.
            return 20
        case .available:
            break
        }

        switch await probe.runFunctionalCheck(timeout: 45) {
        case .completed(let elapsed):
            print(String(format: "Apple model self-test passed in %.2f seconds.", elapsed))
            return 0
        case .timedOut:
            fputs("Apple model self-test failed: functional request timed out.\n", stderr)
            return 21
        case .rateLimited:
            fputs("Apple model self-test deferred: system rate limited the request.\n", stderr)
            return 22
        case .requestStillRunning:
            fputs("Apple model self-test failed: another request remained in flight.\n", stderr)
            return 23
        case .modelNotReady:
            fputs("Apple model self-test unavailable: model assets are not ready.\n", stderr)
            return 20
        case .unsupportedLocale:
            fputs("Apple model self-test unavailable: current language or locale is unsupported.\n", stderr)
            return 20
        case .failed(let message):
            fputs("Apple model self-test failed: \(message)\n", stderr)
            return 24
        }
    }
}
