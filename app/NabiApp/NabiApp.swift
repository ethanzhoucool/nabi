import SwiftUI
import MWDATCore

@main
struct NabiApp: App {
  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("NABI configure failed: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        // The Meta AI app returns here after registration through the nabi:// link.
        .onOpenURL { url in
          Task {
            do {
              let handled = try await Wearables.shared.handleUrl(url)
              NSLog("NABI handled url \(url): \(handled)")
            } catch {
              NSLog("NABI handleUrl failed: \(error)")
            }
          }
        }
    }
  }
}
