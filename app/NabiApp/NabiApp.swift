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
    WindowGroup { ContentView() }
  }
}
