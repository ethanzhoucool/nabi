import SwiftUI
import UIKit
import MWDATCamera
import MWDATCore
import MWDATDisplay
import MWDATInputs
import MWDATMockDevice

// Nabi on Meta Ray-Ban Display glasses: the glasses camera streams to the iPhone, Apple
// Vision finds the object straight ahead of the wearer and names it, and the glasses show a
// red dot on that object with its label. A Neural Band pinch locks the target (later, the
// robot arm picks up the locked object); another pinch unlocks it.
//
// Runs against real glasses on an iPhone, or a mock pair in the simulator (launch with
// --feed <video path> to give the mock camera something to look at).

struct ReadyTimeout: Error {}

@MainActor
@Observable
final class NabiModel {
  var status = "Starting"
  var needsRegistration = false
  var needsCameraPermission = false
  var previewDisplay: (any MockDisplayKit)?

  // What the phone shows: the latest camera frame, the target, and the last display frame.
  var cameraFrame: UIImage?
  var target: GazeTarget?
  var locked = false
  var lastDisplayFrame: UIImage?
  var visionMs = 0

  // Calibration: how a point in the camera image maps onto the glasses display.
  var calibration = Calibration.load() {
    didSet { calibration.save(); renderSoon() }
  }

  @ObservationIgnored private var mock: (any MockGlasses)?
  @ObservationIgnored private var session: DeviceSession?
  @ObservationIgnored private var display: Display?
  @ObservationIgnored private var inputs: Inputs?
  @ObservationIgnored private var camera: Camera?
  @ObservationIgnored private var tokens: [any AnyListenerToken] = []
  @ObservationIgnored private var inputTask: Task<Void, Never>?
  @ObservationIgnored private let vision = GazeVision()
  @ObservationIgnored private let tracker = TargetTracker()
  @ObservationIgnored private let visionQueue = DispatchQueue(label: "nabi.vision", qos: .userInitiated)
  @ObservationIgnored private var visionBusy = false
  @ObservationIgnored private var lastVisionAt: Double = 0

  // The simulator always uses the mock glasses. On an iPhone the app talks to real glasses
  // through the Meta AI app, unless it is launched with --mock.
  #if targetEnvironment(simulator)
  let usesMock = true
  #else
  let usesMock = CommandLine.arguments.contains("--mock")
  #endif

  // MARK: Startup

  func start() async {
    guard session == nil else { return }
    do {
      if usesMock {
        try startMock()
      } else {
        try await waitForRegistration()
      }
      setStatus(usesMock ? "Waiting for the mock glasses" : "Waiting for your glasses to connect")
      // Meta's CameraAccess sample waits on the selector's active-device stream, not on
      // Device.linkState: a Device read through deviceForIdentifier never updates on its own.
      let selector = AutoDeviceSelector(wearables: Wearables.shared)
      try await waitForActiveDevice(selector)

      let session = try Wearables.shared.createSession(deviceSelector: selector)
      self.session = session
      let states = session.stateStream()
      try session.start()
      setStatus("Starting the session")
      for await state in states {
        NSLog("NABI session state: \(state)")
        if state == .started { break }
      }

      try await startDisplay(session)
      startInputs(session)
      try await startCamera(session)

      if usesMock {
        // Chrome preview at http://127.0.0.1:9000/ with Meta's Display Simulator extension.
        do {
          let port = try await MockDeviceKit.shared.startTestServer(port: 9000)
          NSLog("NABI test server on port \(port)")
        } catch {
          NSLog("NABI test server failed: \(error)")
        }
      }
      renderSoon()
      if fakeVision != nil { driveFakeVision() }
      if CommandLine.arguments.contains("--demo") { runDemo() }
    } catch {
      setStatus("Error: \(error)")
    }
  }

  private func startMock() throws {
    MockDeviceKit.shared.enable(
      config: MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true))
    let glasses = try MockDeviceKit.shared.pairGlasses(model: .metaRayBanDisplay)
    mock = glasses
    // Meta's BirdSpotter sample does all three: on, opened, worn.
    glasses.powerOn()
    glasses.unfold()
    glasses.don()
    // The mock camera needs something to show: a video file, or the phone's back camera.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--feed"), i + 1 < args.count {
      glasses.services.camera.setCameraFeed(fileURL: URL(fileURLWithPath: args[i + 1]))
    } else {
      glasses.services.camera.setCameraFeed(cameraFacing: .back)
    }
    previewDisplay = glasses.services.display
  }

  // Real glasses: the app has to be registered with the Meta AI app first. With Developer
  // Mode on for the glasses in Meta AI, no Meta app ID is needed. Registration opens Meta AI,
  // which sends the user back through the nabi:// link (handled in NabiApp).
  private func waitForRegistration() async throws {
    let states = Wearables.shared.registrationStateStream()
    if Wearables.shared.registrationState == .registered { return }
    needsRegistration = true
    setStatus("Tap Connect glasses. Developer Mode must be on for your glasses in Meta AI.")
    for await state in states {
      NSLog("NABI registration state: \(state)")
      if state == .registered { break }
    }
    needsRegistration = false
  }

  func connectGlasses() {
    Task {
      do {
        try await Wearables.shared.startRegistration()
      } catch {
        setStatus("Registration failed: \(error)")
      }
    }
  }

  private func waitForActiveDevice(_ selector: AutoDeviceSelector) async throws {
    let usesMock = self.usesMock
    let found = await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await id in selector.activeDeviceStream() {
          NSLog("NABI active device: \(String(describing: id))")
          if id != nil { return true }
        }
        return false
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(usesMock ? 10 : 60))
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    if !found { throw ReadyTimeout() }
  }

  private func setStatus(_ text: String) {
    status = text
    NSLog("NABI status: \(text)")
  }

  // MARK: Camera and vision

  private func startCamera(_ session: DeviceSession) async throws {
    if !usesMock {
      let status = try await Wearables.shared.checkPermissionStatus(.camera)
      NSLog("NABI camera permission: \(status)")
      if status != .granted {
        needsCameraPermission = true
        setStatus("Tap Allow camera. Meta AI will ask you to let Nabi use the glasses camera.")
        while try await Wearables.shared.checkPermissionStatus(.camera) != .granted {
          try await Task.sleep(for: .seconds(1))
        }
        needsCameraPermission = false
      }
    }
    // Low resolution is plenty for finding one object, and leaves room on the link.
    let config = StreamConfiguration(videoCodec: .raw, resolution: .low, frameRate: 15)
    guard let camera = try session.addCamera(config: config) else {
      setStatus("The glasses camera is not available")
      return
    }
    self.camera = camera
    let stream = camera.stream
    tokens.append(stream.statePublisher.listen { [weak self] state in
      NSLog("NABI camera state: \(state)")
      Task { @MainActor in
        if state == .streaming { self?.setStatus("Look at an object") }
      }
    })
    tokens.append(stream.errorPublisher.listen { [weak self] error in
      NSLog("NABI camera error: \(error)")
      Task { @MainActor in
        if case .deviceNotConnected = error {
          // Meta's camera sample also has the Wi-Fi Hotspot entitlement, which a free Apple
          // developer team can't sign. If the stream never connects, that is the likely cause.
          self?.setStatus("Camera stream could not connect (\(error)). It may need a paid Apple developer team.")
        } else {
          self?.setStatus("Camera: \(error.localizedDescription)")
        }
      }
    })
    tokens.append(stream.videoFramePublisher.listen { [weak self] frame in
      guard let image = frame.makeUIImage() else { return }
      Task { @MainActor in self?.received(image) }
    })
    stream.start()
    setStatus("Starting the glasses camera")
  }

  func requestCameraPermission() {
    Task {
      do {
        let status = try await Wearables.shared.requestPermission(.camera)
        NSLog("NABI camera permission after request: \(status)")
      } catch {
        setStatus("Camera permission failed: \(error)")
      }
    }
  }

  // Frames arrive at up to 15 per second. Vision runs on one at a time, at most about 8 times
  // a second; frames that arrive while it is busy are skipped, so it never falls behind.
  // Vision and the tracker run off the main thread, on visionQueue only.
  @ObservationIgnored private var lastRealFrameAt: Double = 0

  private func received(_ image: UIImage, real: Bool = true) {
    if real { lastRealFrameAt = Self.nowMs() }
    cameraFrame = image
    let now = Self.nowMs()
    guard !visionBusy, now - lastVisionAt > 120, let cg = Self.standardized(image) else { return }
    visionBusy = true
    lastVisionAt = now
    let locked = self.locked
    let calibration = self.calibration
    let vision = self.vision
    let tracker = self.tracker
    let fake = self.fakeVision
    visionQueue.async {
      let t0 = Self.nowMs()
      let boxes: [CGRect]
      let classify: (CGRect) -> (String, Float)?
      if let fake {
        boxes = fake.boxes(at: t0)
        classify = { fake.label(for: $0) }
      } else {
        vision.gaze = calibration.gaze
        let found = vision.objectBoxes(in: cg)
        // No object boxes: try a square around the gaze point instead.
        boxes = found.isEmpty ? [vision.fallbackBox(imageSize: CGSize(width: cg.width, height: cg.height))] : found
        classify = { vision.classify(cg, region: vision.padded($0, by: 0.12)) }
      }
      let target = tracker.update(
        boxes: boxes, gaze: calibration.gaze, locked: locked, now: t0,
        inSquare: { calibration.isOnDisplay($0) }, classify: classify)
      let event = tracker.lastEvent
      let ms = Int(Self.nowMs() - t0)
      Task { @MainActor [weak self] in self?.analyzed(target, event: event, ms: ms) }
    }
  }

  // Camera frames can come in a pixel layout Vision misreads, so each frame is redrawn into a
  // plain 8-bit sRGB image first, at most 480 pixels wide, which is plenty for one object and
  // keeps Vision fast.
  private static func standardized(_ image: UIImage) -> CGImage? {
    let scale = min(1, 480 / max(image.size.width, 1))
    let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    guard size.width > 0, size.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    format.preferredRange = .standard
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: size))
    }.cgImage
  }

  private func analyzed(_ next: GazeTarget?, event: String, ms: Int) {
    visionBusy = false
    visionMs = ms
    if !event.isEmpty { NSLog("NABI tracker: \(event)") }
    if next == nil && locked {
      locked = false
      NSLog("NABI lost the locked object")
    }
    guard next != target else { return }
    if next?.label != target?.label {
      NSLog("NABI target: \(next.map { "\($0.label) \(Int($0.confidence * 100))%" } ?? "none") (\(ms) ms)")
    }
    target = next
    renderSoon()
  }

  // With --fake-vision and no camera frames (the simulator's mock camera stops without a
  // video feed), feed a plain gray frame on a timer so the made-up detections still run.
  private func driveFakeVision() {
    let gray = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 640)).image { ctx in
      UIColor(white: 0.3, alpha: 1).setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 360, height: 640))
    }
    Task { @MainActor [weak self] in
      while let self {
        if Self.nowMs() - self.lastRealFrameAt > 1000 { self.received(gray, real: false) }
        try? await Task.sleep(for: .milliseconds(150))
      }
    }
  }

  // --fake-vision: made-up detections, for the simulator, where Vision can't run.
  @ObservationIgnored private lazy var fakeVision: FakeVision? =
    CommandLine.arguments.contains("--fake-vision") ? FakeVision(start: Self.nowMs()) : nil

  // MARK: Input

  private func startInputs(_ session: DeviceSession) {
    do {
      guard let inputs = try session.addInputs() else {
        NSLog("NABI inputs unavailable, using phone buttons only")
        return
      }
      self.inputs = inputs
      // Inputs needs no Developer Center step in Developer Mode (Meta, discussion #352).
      // Real glasses never send Back: the Neural Band Back gesture closes the app on the
      // glasses and ends the session (Meta, issue #349).
      tokens.append(inputs.errorPublisher.listen { [weak self] error in
        NSLog("NABI inputs error: \(error)")
        Task { @MainActor in
          if error == .communicationError {
            // A short Bluetooth stall: input resumes on its own, and late events are dropped.
            self?.setStatus("Neural Band link stalled for a moment. Late pinches are ignored.")
          } else {
            self?.setStatus("Neural Band input unavailable (\(error)). Use the phone button.")
          }
        }
      })
      let events = inputs.events
      inputTask = Task { [weak self] in
        for await event in events { self?.handle(event) }
      }
    } catch {
      NSLog("NABI addInputs failed: \(error)")
    }
  }

  // Over Bluetooth the band's events can stall and then arrive in a burst (seen on real
  // glasses: about 9 s of swipes delivered within 0.2 s). A late pinch could lock the wrong
  // object, so events that arrive more than lateLimitMs after they were made are dropped.
  // Each event carries the glasses' own clock; the smallest phone-minus-glasses gap seen so
  // far is the "on time" baseline.
  @ObservationIgnored private var bestGapMs: Double?
  private static let lateLimitMs: Double = 400

  private func isLate(_ timestampMs: Int64) -> Bool {
    // The mock's timestamps don't share a clock with the phone's, so only real glasses are checked.
    guard !usesMock else { return false }
    let gap = Self.nowMs() - Double(timestampMs)
    guard let best = bestGapMs, gap >= best else {
      bestGapMs = gap
      return false
    }
    return gap - best > Self.lateLimitMs
  }

  nonisolated private static func nowMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }

  private func handle(_ event: InputEvent) {
    switch event {
    case .select(_, let ts):
      if isLate(ts) { NSLog("NABI dropped late pinch"); return }
      NSLog("NABI input: select")
      toggleLock()
    case .nav(let direction, _, _):
      NSLog("NABI input: nav \(direction) (unused)")
    default:
      // Drags come with every pinch; Back never reaches apps on real glasses.
      break
    }
  }

  func toggleLock() {
    if locked {
      locked = false
      NSLog("NABI unlocked")
    } else if let target {
      locked = true
      NSLog("NABI locked: \(target.label)")
    } else {
      NSLog("NABI pinch with nothing to lock")
    }
    renderSoon()
  }

  // Stand-in for the Neural Band pinch: in the simulator it goes through the mock glasses'
  // input service, so it reaches the app the same way a real pinch would.
  func pinch() { if inputs != nil, let mock { mock.services.input.select() } else { toggleLock() } }

  // Used by CI: lock whatever is in view, then unlock, with time for a screenshot after each.
  private func runDemo() {
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(6)); self?.pinch()
      try? await Task.sleep(for: .seconds(4)); self?.pinch()
    }
  }

  // MARK: Display

  private func startDisplay(_ session: DeviceSession) async throws {
    let display = try session.addDisplay()
    self.display = display
    let (displayStates, cont) = AsyncStream.makeStream(of: DisplayState.self)
    tokens.append(display.statePublisher.listen { cont.yield($0) })
    display.start()
    for await state in displayStates {
      NSLog("NABI display state: \(state)")
      if state == .started { break }
    }
  }

  // Sending a frame to the glasses takes a while over Bluetooth (measured on real glasses:
  // a 600x600 image about 650 ms, a 300x85 image with native text about 200 ms, native text
  // alone about 70 ms). So the dot is drawn into a small image, the label is native text,
  // and only one frame is in flight at a time: when it lands, the newest state goes next.
  @ObservationIgnored private var sending = false
  @ObservationIgnored private var dirty = false
  @ObservationIgnored private var lastSent: DisplayContent?

  private func renderSoon() {
    dirty = true
    guard !sending else { return }
    Task { await sendLoop() }
  }

  private func sendLoop() async {
    sending = true
    defer { sending = false }
    while dirty {
      dirty = false
      let content = DisplayContent.make(target: target, locked: locked, calibration: calibration)
      // Skip frames that would look the same as the one already on the glasses.
      if let lastSent, !content.differsVisibly(from: lastSent) { continue }
      await send(content)
      lastSent = content
    }
  }

  private func send(_ content: DisplayContent) async {
    guard let display else { return }
    let field = content.drawField()
    let view = FlexBox(
      direction: .column, spacing: 6, alignment: .center, crossAlignment: .center,
      padding: EdgeInsets(top: 8, bottom: 20, leading: 20, trailing: 20)
    ) {
      MWDATDisplay.Image(image: field, sizePreset: .fill)
      MWDATDisplay.Text(content.title, style: .heading).alignSelf(.center)
      MWDATDisplay.Text(content.subtitle, style: .meta, color: .secondary).alignSelf(.center)
    }
    .onTap { [weak self] in Task { @MainActor in self?.toggleLock() } }
    let start = ContinuousClock.now
    do {
      try await display.send(view)
    } catch {
      NSLog("NABI send failed: \(error)")
      return
    }
    let d = start.duration(to: .now).components
    let ms = Int(Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15)
    NSLog("NABI frame sent in \(ms) ms: \(content.title)")
    lastDisplayFrame = field
  }
}

// MARK: - Calibration

// The camera sees far more than the display covers. A point in the camera image (normalized)
// lands on the display at center + (point - gaze) * scale + offset, where the display's own
// coordinates run 0...1 across the dot field. Set by eye on the phone: look at an object and
// move the sliders until the dot sits on it.
struct Calibration: Equatable, Codable {
  var gazeX: Double = 0.5
  var gazeY: Double = 0.5
  var scale: Double = 3.0
  var offsetX: Double = 0
  var offsetY: Double = 0

  var gaze: CGPoint { CGPoint(x: gazeX, y: gazeY) }

  func toDisplay(_ p: CGPoint) -> CGPoint {
    CGPoint(x: 0.5 + (p.x - gazeX) * scale + offsetX, y: 0.5 + (p.y - gazeY) * scale + offsetY)
  }

  // Whether a camera point lands inside the glasses display square.
  func isOnDisplay(_ p: CGPoint) -> Bool {
    let d = toDisplay(p)
    return (0...1).contains(d.x) && (0...1).contains(d.y)
  }

  static func load() -> Calibration {
    guard let data = UserDefaults.standard.data(forKey: "calibration"),
          let c = try? JSONDecoder().decode(Calibration.self, from: data) else { return Calibration() }
    return c
  }

  func save() {
    if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "calibration") }
  }
}

// MARK: - Simulated vision

// Two made-up objects for testing the tracker and display where Vision can't run: a cup that
// drifts side to side near the middle, and a mouse that appears right at the center from 8 s
// to 20 s, so the dot should switch to the mouse and then back.
nonisolated struct FakeVision: Sendable {
  let start: Double

  private func cupBox(_ s: Double) -> CGRect {
    let x = 0.5 + 0.12 * sin(s * 0.6)
    return CGRect(x: x - 0.09, y: 0.52 - 0.07, width: 0.18, height: 0.14)
  }
  private let mouseBox = CGRect(x: 0.46, y: 0.46, width: 0.1, height: 0.07)

  func boxes(at now: Double) -> [CGRect] {
    let s = (now - start) / 1000
    var boxes = [cupBox(s)]
    if (8...20).contains(s) { boxes.append(mouseBox) }
    return boxes
  }

  func label(for box: CGRect) -> (String, Float)? {
    hypot(box.midX - mouseBox.midX, box.midY - mouseBox.midY) < 0.02 ? ("mouse", 0.8) : ("cup", 0.9)
  }
}

// MARK: - What the glasses show

struct DisplayContent: Equatable {
  // Dot position in the field, 0...1; nil when there is no target.
  var dot: CGPoint?
  var locked: Bool
  var title: String
  var subtitle: String

  static let fieldSize = CGSize(width: 240, height: 150)

  static func make(target: GazeTarget?, locked: Bool, calibration: Calibration) -> DisplayContent {
    guard let target else {
      return DisplayContent(dot: nil, locked: false, title: "Look at an object", subtitle: "Nabi finds what is in front of you")
    }
    let p = calibration.toDisplay(target.center)
    let percent = Int((target.confidence * 100).rounded())
    return DisplayContent(
      dot: p, locked: locked, title: target.label.capitalized,
      subtitle: locked ? "Locked. Pinch to release" : "\(percent)% sure. Pinch to lock")
  }

  // Small dot moves are not worth a 200 ms send.
  func differsVisibly(from other: DisplayContent) -> Bool {
    if title != other.title || subtitle != other.subtitle || locked != other.locked { return true }
    switch (dot, other.dot) {
    case (nil, nil): return false
    case let (a?, b?): return hypot(a.x - b.x, a.y - b.y) > 0.03
    default: return true
    }
  }

  // The display can't place elements at a point, so the dot is drawn into a small image.
  // Black is see-through on the glasses.
  func drawField() -> UIImage {
    let size = Self.fieldSize
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
      let cg = ctx.cgContext
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      guard let dot else {
        // No target: a faint ring where the gaze point is.
        cg.setStrokeColor(UIColor(white: 0.35, alpha: 1).cgColor)
        cg.setLineWidth(2)
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        cg.strokeEllipse(in: CGRect(x: c.x - 10, y: c.y - 10, width: 20, height: 20))
        return
      }
      let red = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
      let inside = (0.04...0.96).contains(dot.x) && (0.04...0.96).contains(dot.y)
      // Off the display: pin to the edge, smaller, so it reads as "over there".
      let x = min(max(dot.x, 0.04), 0.96) * size.width
      let y = min(max(dot.y, 0.06), 0.94) * size.height
      let r: CGFloat = inside ? 9 : 6
      for (g, a) in [(r + 9, 0.12), (r + 5, 0.22), (r + 2, 0.35)] {
        cg.setFillColor(red.withAlphaComponent(a).cgColor)
        cg.fillEllipse(in: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2))
      }
      cg.setFillColor(UIColor.white.cgColor)
      cg.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
      cg.setFillColor(red.cgColor)
      cg.fillEllipse(in: CGRect(x: x - r + 2.5, y: y - r + 2.5, width: (r - 2.5) * 2, height: (r - 2.5) * 2))
      if locked {
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(2)
        cg.strokeEllipse(in: CGRect(x: x - r - 7, y: y - r - 7, width: (r + 7) * 2, height: (r + 7) * 2))
      }
    }
  }
}

// MARK: - Phone UI

struct DisplayPreview: UIViewRepresentable {
  let display: any MockDisplayKit
  func makeUIView(context: Context) -> UIView { display.createPreviewView() }
  func updateUIView(_ uiView: UIView, context: Context) {}
}

// The camera frame with the target's box drawn over it, so the phone shows what Nabi sees.
struct CameraView: View {
  let frame: UIImage
  let target: GazeTarget?
  let locked: Bool
  let gaze: CGPoint

  var body: some View {
    SwiftUI.Image(uiImage: frame).resizable().scaledToFit()
      .overlay {
        GeometryReader { geo in
          let w = geo.size.width, h = geo.size.height
          if let target {
            let b = target.box
            Rectangle()
              .stroke(locked ? Color.red : Color.white, lineWidth: locked ? 3 : 2)
              .frame(width: b.width * w, height: b.height * h)
              .position(x: b.midX * w, y: b.midY * h)
            SwiftUI.Text(target.label)
              .font(.caption.bold()).padding(4)
              .background(locked ? Color.red : Color.black.opacity(0.6))
              .foregroundStyle(.white)
              .position(x: b.midX * w, y: max(b.minY * h - 12, 10))
          }
          Circle().stroke(Color.yellow, lineWidth: 1.5)
            .frame(width: 14, height: 14)
            .position(x: gaze.x * w, y: gaze.y * h)
        }
      }
  }
}

struct ContentView: View {
  @State private var model = NabiModel()
  @State private var showCalibration = false

  var body: some View {
    ScrollView {
      VStack(spacing: 14) {
        SwiftUI.Text("Nabi").font(.largeTitle.bold())
        SwiftUI.Text(model.status).font(.footnote).foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        if model.needsRegistration {
          SwiftUI.Button("Connect glasses") { model.connectGlasses() }.buttonStyle(.borderedProminent)
        }
        if model.needsCameraPermission {
          SwiftUI.Button("Allow camera") { model.requestCameraPermission() }.buttonStyle(.borderedProminent)
        }

        HStack(alignment: .top, spacing: 10) {
          // What the glasses camera sees.
          ZStack {
            Color.black
            if let frame = model.cameraFrame {
              CameraView(frame: frame, target: model.target, locked: model.locked, gaze: model.calibration.gaze)
            } else {
              SwiftUI.Text("Camera").foregroundStyle(.gray)
            }
          }
          .aspectRatio(9.0 / 16.0, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 10))

          // What the glasses display shows.
          ZStack {
            Color.black
            if let display = model.previewDisplay {
              DisplayPreview(display: display)
            } else if let frame = model.lastDisplayFrame {
              SwiftUI.Image(uiImage: frame).resizable().scaledToFit()
            } else {
              SwiftUI.Text("Display").foregroundStyle(.gray)
            }
          }
          .aspectRatio(1, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxHeight: 300)

        HStack {
          SwiftUI.Text(model.target.map { "\($0.label) (\(Int($0.confidence * 100))%)" } ?? "No target")
            .font(.headline)
          Spacer()
          SwiftUI.Text("vision \(model.visionMs) ms").font(.caption).foregroundStyle(.secondary)
        }

        SwiftUI.Button(model.locked ? "Release" : "Lock (pinch)") { model.pinch() }
          .buttonStyle(.borderedProminent)
          .tint(model.locked ? .gray : .red)

        DisclosureGroup("Calibrate the dot", isExpanded: $showCalibration) {
          VStack(alignment: .leading, spacing: 8) {
            SwiftUI.Text("Look at an object and move these until the dot on the glasses sits on it.")
              .font(.caption).foregroundStyle(.secondary)
            CalibrationSlider(label: "Gaze left/right", value: $model.calibration.gazeX, range: 0.2...0.8)
            CalibrationSlider(label: "Gaze up/down", value: $model.calibration.gazeY, range: 0.2...0.8)
            CalibrationSlider(label: "Spread", value: $model.calibration.scale, range: 1...6)
            CalibrationSlider(label: "Dot left/right", value: $model.calibration.offsetX, range: -0.5...0.5)
            CalibrationSlider(label: "Dot up/down", value: $model.calibration.offsetY, range: -0.5...0.5)
            SwiftUI.Button("Reset") { model.calibration = Calibration() }
          }
        }
      }
      .padding()
    }
    .task { await model.start() }
  }
}

struct CalibrationSlider: View {
  let label: String
  @Binding var value: Double
  let range: ClosedRange<Double>

  var body: some View {
    HStack {
      SwiftUI.Text(label).font(.caption).frame(width: 110, alignment: .leading)
      Slider(value: $value, in: range)
      SwiftUI.Text(String(format: "%.2f", value)).font(.caption.monospacedDigit()).frame(width: 40)
    }
  }
}
