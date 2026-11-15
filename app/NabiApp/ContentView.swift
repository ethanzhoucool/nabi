import SwiftUI
import UIKit
import MWDATCore
import MWDATDisplay
import MWDATInputs
import MWDATMockDevice

// First Nabi app: runs against a mock Meta Ray-Ban Display (no glasses needed).
// The glasses' display shows a red dot over one of three candidate objects.
// Swipe left/right (Neural Band nav) moves the dot, a pinch (select) locks it.
// Object detection and the camera come later; the candidates are fixed for now.

struct ReadyTimeout: Error {}

@MainActor
@Observable
final class NabiModel {
  let candidates = ["cup", "phone", "keys"]
  var index = 0
  var locked: String?
  var status = "Starting"
  var previewDisplay: (any MockDisplayKit)?

  @ObservationIgnored private var mock: (any MockGlasses)?
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var tokens: [any AnyListenerToken] = []
  @ObservationIgnored private var inputTask: Task<Void, Never>?

  func start() async {
    guard session == nil else { return }
    do {
      MockDeviceKit.shared.enable()
      let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
      mock = glasses
      glasses.powerOn()
      glasses.don()
      previewDisplay = glasses.services.display
      setStatus("Waiting for the mock glasses")
      try await waitUntilReady(glasses.deviceIdentifier)

      let session = try Wearables.shared.createSession(
        deviceSelector: SpecificDeviceSelector(device: glasses.deviceIdentifier))
      self.session = session
      let states = session.stateStream()
      try session.start()
      for await state in states where state == .started { break }

      let display = try session.addDisplay()
      self.display = display
      let (displayStates, cont) = AsyncStream.makeStream(of: DisplayState.self)
      tokens.append(display.statePublisher.listen { cont.yield($0) })
      display.start()
      for await state in displayStates where state == .started { break }

      if let inputs = try session.addInputs() {
        self.inputs = inputs
        let events = inputs.events
        inputTask = Task { [weak self] in
          for await event in events { self?.handle(event) }
        }
      } else {
        NSLog("NABI inputs unavailable, using display buttons only")
      }

      // Chrome preview at http://127.0.0.1:9000/ with Meta's Display Simulator extension.
      do {
        let port = try await MockDeviceKit.shared.startTestServer(port: 9000)
        NSLog("NABI test server on port \(port)")
      } catch {
        NSLog("NABI test server failed: \(error)")
      }

      setStatus("Display on")
      render()
      if CommandLine.arguments.contains("--demo") { runDemo() }
    } catch {
      setStatus("Error: \(error)")
    }
  }

  private func setStatus(_ text: String) {
    status = text
    NSLog("NABI status: \(text)")
  }

  private func waitUntilReady(_ id: DeviceIdentifier) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(10))
    while true {
      if let device = Wearables.shared.deviceForIdentifier(id),
         device.linkState == .connected, device.compatibility() == .compatible { return }
      guard clock.now < deadline else { throw ReadyTimeout() }
      try await clock.sleep(for: .milliseconds(50))
    }
  }

  private func handle(_ event: InputEvent) {
    NSLog("NABI input: \(event)")
    switch event {
    case .nav(let direction, _, _):
      if direction == .left { move(-1) } else if direction == .right { move(1) }
    case .select:
      lockCurrent()
    default:
      break
    }
  }

  func move(_ delta: Int) {
    locked = nil
    index = (index + delta + candidates.count) % candidates.count
    NSLog("NABI candidate: \(candidates[index])")
    render()
  }

  func lockCurrent() {
    locked = candidates[index]
    NSLog("NABI locked: \(candidates[index])")
    render()
  }

  // Stand-ins for the Neural Band: these go through the mock glasses' input service,
  // so they reach the app the same way real swipes and pinches would.
  func swipeLeft() { if inputs != nil { mock?.services.input.navLeft() } else { move(-1) } }
  func swipeRight() { if inputs != nil { mock?.services.input.navRight() } else { move(1) } }
  func pinch() { if inputs != nil { mock?.services.input.select() } else { lockCurrent() } }

  // Used by CI: swipe right, pinch, swipe left, with time for a screenshot after each.
  private func runDemo() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(2)); self?.swipeRight()
      try? await Task.sleep(for: .seconds(4)); self?.pinch()
      try? await Task.sleep(for: .seconds(4)); self?.swipeRight()
    }
  }

  private func render() {
    guard let display else { return }
    let frame = Self.drawFrame(candidates: candidates, index: index, locked: locked)
    let view = FlexBox(direction: .column, spacing: 0, alignment: .center, crossAlignment: .center) {
      MWDATDisplay.Image(image: frame, sizePreset: .fill)
    }
    .onTap { [weak self] in Task { @MainActor in self?.lockCurrent() } }
    Task {
      do { try await display.send(view) } catch { NSLog("NABI send failed: \(error)") }
    }
  }

  // The display can't place elements at a point, so the dot is drawn into a 600x600 image.
  // Black is see-through on the real glasses.
  static func drawFrame(candidates: [String], index: Int, locked: String?) -> UIImage {
    let size = CGSize(width: 600, height: 600)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      let xs: [CGFloat] = [120, 300, 480]
      for (i, name) in candidates.enumerated() {
        let attrs: [NSAttributedString.Key: Any] = [
          .font: UIFont.systemFont(ofSize: 36, weight: .semibold),
          .foregroundColor: i == index ? UIColor.white : UIColor(white: 0.45, alpha: 1),
        ]
        let text = name as NSString
        let w = text.size(withAttributes: attrs).width
        text.draw(at: CGPoint(x: xs[i] - w / 2, y: 340), withAttributes: attrs)
      }
      let dot = CGRect(x: xs[index] - 26, y: 260, width: 52, height: 52)
      UIColor.white.setFill()
      ctx.cgContext.fillEllipse(in: dot)
      UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).setFill()
      ctx.cgContext.fillEllipse(in: dot.insetBy(dx: 7, dy: 7))
      let headline = locked.map { "Locked: \($0)" } ?? "Swipe to choose, pinch to lock"
      let attrs: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: locked == nil ? 30 : 44, weight: .bold),
        .foregroundColor: UIColor.white,
      ]
      let text = headline as NSString
      let w = text.size(withAttributes: attrs).width
      text.draw(at: CGPoint(x: 300 - w / 2, y: 110), withAttributes: attrs)
    }
  }
}

struct DisplayPreview: UIViewRepresentable {
  let display: any MockDisplayKit
  func makeUIView(context: Context) -> UIView { display.createPreviewView() }
  func updateUIView(_ uiView: UIView, context: Context) {}
}

struct ContentView: View {
  @State private var model = NabiModel()

  var body: some View {
    VStack(spacing: 16) {
      SwiftUI.Text("Nabi").font(.largeTitle.bold())
      SwiftUI.Text(model.status).font(.footnote).foregroundStyle(.secondary)
      ZStack {
        Color.black
        if let display = model.previewDisplay { DisplayPreview(display: display) }
      }
      .aspectRatio(1, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 12))
      HStack(spacing: 28) {
        SwiftUI.Button("Swipe left") { model.swipeLeft() }
        SwiftUI.Button("Pinch") { model.pinch() }.bold()
        SwiftUI.Button("Swipe right") { model.swipeRight() }
      }
      SwiftUI.Text(model.locked.map { "Locked: \($0)" } ?? "Candidate: \(model.candidates[model.index])")
    }
    .padding()
    .task { await model.start() }
  }
}
