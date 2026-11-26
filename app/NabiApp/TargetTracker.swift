import CoreGraphics
import Foundation

// Decides which object the dot sits on, frame after frame.
//
// The dot sticks to an object. It moves to a different one only when:
//   - the current object leaves the display square (its spot would fall off the glasses
//     display), or it hasn't been seen for holdMs, or
//   - another object is clearly more directly in front (much closer to the gaze point) for
//     several frames in a row. A locked target never switches this way.
//
// Plain CoreGraphics and Foundation so it also runs in a Mac test harness. Not thread-safe:
// call it from one queue.
nonisolated final class TargetTracker: @unchecked Sendable {
  private(set) var current: GazeTarget?

  // A challenger must be this much closer to the gaze point (as a fraction of the current
  // object's distance) to count, for this many analyses in a row.
  var challengeRatio: CGFloat = 0.6
  var challengeFrames = 3
  // Within this distance of the gaze point, the current object is "in front" already and
  // can't be challenged.
  var settledDistance: CGFloat = 0.06
  // An object near the gaze point (or containing it) can become the target from this far.
  var acquireDistance: CGFloat = 0.18
  // How long a target survives without being seen.
  var holdMs: Double = 1200
  // How many recent labels vote on the name.
  var labelWindow = 5

  private var lastSeenAt: Double = 0
  private var recentLabels: [String] = []
  private var challenger: CGRect?
  private var challengerCount = 0

  // Events from the last update, for logs.
  private(set) var lastEvent = ""

  func reset() {
    current = nil
    recentLabels.removeAll()
    challenger = nil
    challengerCount = 0
  }

  /// - boxes: candidate object boxes in this frame (normalized, origin top-left).
  /// - classify: names the object in a box, or nil if unsure.
  /// - inSquare: whether a camera point lands inside the glasses display square.
  func update(
    boxes: [CGRect], gaze: CGPoint, locked: Bool, now: Double,
    inSquare: (CGPoint) -> Bool, classify: (CGRect) -> (String, Float)?
  ) -> GazeTarget? {
    lastEvent = ""
    let nearest = boxes
      .filter { $0.contains(gaze) || distance($0.center, gaze) <= acquireDistance }
      .min { frontScore($0, gaze) < frontScore($1, gaze) }

    if let cur = current {
      if let match = bestMatch(for: cur.box, in: boxes), inSquare(match.center) {
        lastSeenAt = now
        // Is something else clearly more in front?
        if !locked, let n = nearest, iou(n, match) < 0.3,
           frontScore(match, gaze) > settledDistance,
           frontScore(n, gaze) < frontScore(match, gaze) * challengeRatio {
          if let c = challenger, iou(c, n) > 0.3 { challengerCount += 1 } else { challengerCount = 1 }
          challenger = n
          if challengerCount >= challengeFrames, let next = acquire(n, classify: classify, now: now) {
            lastEvent = "switched to a more central object"
            return next
          }
        } else {
          challenger = nil
          challengerCount = 0
        }
        follow(match, locked: locked, classify: classify)
        return current
      }
      // Not matched in this frame, or it left the display square.
      let leftSquare = !inSquare(cur.center)
      if !leftSquare && now - lastSeenAt <= holdMs {
        return current  // hold through a missed frame or two
      }
      lastEvent = leftSquare ? "target left the display square" : "target not seen for \(Int(holdMs)) ms"
      reset()
      if locked { return nil }
    }

    guard !locked, let n = nearest else { return nil }
    return acquire(n, classify: classify, now: now)
  }

  // MARK: Steps

  private func acquire(_ box: CGRect, classify: (CGRect) -> (String, Float)?, now: Double) -> GazeTarget? {
    guard let (label, confidence) = classify(box) else { return nil }
    reset()
    lastSeenAt = now
    recentLabels = [label]
    current = GazeTarget(label: label, confidence: confidence, box: box, fromFallback: false)
    if lastEvent.isEmpty { lastEvent = "new target" }
    return current
  }

  private func follow(_ box: CGRect, locked: Bool, classify: (CGRect) -> (String, Float)?) {
    guard var next = current else { return }
    // Glide toward the new position instead of jumping.
    let a: CGFloat = 0.5
    next.box = CGRect(
      x: next.box.minX + (box.minX - next.box.minX) * a,
      y: next.box.minY + (box.minY - next.box.minY) * a,
      width: next.box.width + (box.width - next.box.width) * a,
      height: next.box.height + (box.height - next.box.height) * a)
    // A locked target keeps its name. Otherwise the name is whatever most recent frames agree on.
    if !locked, let (label, confidence) = classify(box) {
      recentLabels.append(label)
      if recentLabels.count > labelWindow { recentLabels.removeFirst() }
      let counts = Dictionary(recentLabels.map { ($0, 1) }, uniquingKeysWith: +)
      if let (winner, votes) = counts.max(by: { $0.value < $1.value }),
         winner != next.label, votes * 2 > recentLabels.count {
        next.label = winner
      }
      if label == next.label { next.confidence = confidence }
    }
    current = next
  }

  // The box in this frame that is most likely the same object as `box`.
  private func bestMatch(for box: CGRect, in boxes: [CGRect]) -> CGRect? {
    if let byOverlap = boxes.max(by: { iou($0, box) < iou($1, box) }), iou(byOverlap, box) > 0.2 {
      return byOverlap
    }
    let near = boxes.min { distance($0.center, box.center) < distance($1.center, box.center) }
    if let near, distance(near.center, box.center) < 0.12 { return near }
    return nil
  }

  // How directly in front a box is: distance from its center to the gaze point, halved when
  // the gaze point is inside it.
  private func frontScore(_ b: CGRect, _ gaze: CGPoint) -> CGFloat {
    distance(b.center, gaze) * (b.contains(gaze) ? 0.5 : 1)
  }

  private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let i = a.intersection(b)
    guard !i.isNull else { return 0 }
    let inter = i.width * i.height
    return inter / (a.width * a.height + b.width * b.height - inter)
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
