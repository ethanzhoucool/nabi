import CoreGraphics
import Foundation
import Vision

// Finds the object the wearer is looking at in one glasses camera frame, and names it.
//
// There is no eye tracking on the glasses, so "looking at" means "in line with the head":
// the gaze point is a fixed spot in the camera image (the center by default, tunable by
// calibration). On-device Apple Vision only, nothing to download:
//   1. Objectness saliency proposes boxes around distinct objects.
//   2. The box the gaze point falls in wins (the smallest one, if several overlap); else the
//      box nearest the gaze point, if it is close enough; else a fixed square around the gaze.
//   3. That region is cropped and classified against Vision's 1,303 built-in labels, skipping
//      labels that name a scene or a broad category instead of a thing.
//
// Everything here is plain CoreGraphics so it also runs on a Mac for quick tests.

struct GazeTarget: Equatable, Sendable {
  var label: String
  var confidence: Float
  // Normalized to the camera image, origin top-left.
  var box: CGRect
  // True when no object box was found and the label comes from a square around the gaze.
  var fromFallback: Bool
  var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

nonisolated final class GazeVision: @unchecked Sendable {
  // Where the wearer is looking, normalized to the camera image (origin top-left).
  var gaze = CGPoint(x: 0.5, y: 0.5)
  // Below this, a label is treated as a guess and not shown.
  var minConfidence: Float = 0.25

  // How far (normalized) a box center may be from the gaze point and still count.
  private let nearEnough: CGFloat = 0.18
  // Side of the fallback square around the gaze, as a fraction of the shorter image side.
  private let fallbackSide: CGFloat = 0.35

  // A one-line summary of the last analysis, for logs.
  private(set) var lastDebug = ""
  private(set) var lastError = ""

  func analyze(_ image: CGImage) -> GazeTarget? {
    let boxes = objectBoxes(in: image)
    let chosen = pickBox(boxes)
    let region = chosen ?? fallbackBox(imageSize: CGSize(width: image.width, height: image.height))
    lastDebug = "\(image.width)x\(image.height) boxes=\(boxes.count) chosen=\(chosen != nil) \(lastError)"
    guard let (label, confidence) = classify(image, region: padded(region, by: 0.12)) else { return nil }
    return GazeTarget(label: label, confidence: confidence, box: region, fromFallback: chosen == nil)
  }

  // MARK: Steps

  func objectBoxes(in image: CGImage) -> [CGRect] {
    let request = VNGenerateObjectnessBasedSaliencyImageRequest()
    do {
      try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
    } catch {
      lastError = "saliency: \(error)"
      return []
    }
    let objects = request.results?.first?.salientObjects ?? []
    // Vision boxes are normalized with the origin bottom-left; flip to top-left.
    return objects.map { o in
      let b = o.boundingBox
      return CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
    }
    // A box covering most of the frame is the whole scene, not an object.
    .filter { $0.width * $0.height < 0.8 }
  }

  func pickBox(_ boxes: [CGRect]) -> CGRect? {
    let containing = boxes.filter { $0.contains(gaze) }
    if let smallest = containing.min(by: { $0.width * $0.height < $1.width * $1.height }) {
      return smallest
    }
    let nearest = boxes.min { distance($0.center, gaze) < distance($1.center, gaze) }
    if let nearest, distance(nearest.center, gaze) < nearEnough { return nearest }
    return nil
  }

  func fallbackBox(imageSize: CGSize) -> CGRect {
    let side = fallbackSide * min(imageSize.width, imageSize.height)
    let w = side / imageSize.width
    let h = side / imageSize.height
    return CGRect(x: gaze.x - w / 2, y: gaze.y - h / 2, width: w, height: h)
  }

  func classify(_ image: CGImage, region: CGRect) -> (String, Float)? {
    let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let pixels = CGRect(
      x: region.minX * full.width, y: region.minY * full.height,
      width: region.width * full.width, height: region.height * full.height
    ).integral.intersection(full)
    guard pixels.width >= 16, pixels.height >= 16, let crop = image.cropping(to: pixels) else { return nil }
    let request = VNClassifyImageRequest()
    do {
      try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
    } catch {
      lastError = "classify: \(error)"
      return nil
    }
    let ranked = (request.results ?? [])
      .filter { !Self.broadLabels.contains($0.identifier) }
      .sorted { $0.confidence > $1.confidence }
    lastDebug += " top=" + ranked.prefix(3).map { "\($0.identifier):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ",")
    guard let best = ranked.first, best.confidence >= minConfidence else { return nil }
    return (Self.displayName(best.identifier), best.confidence)
  }

  // Note: Vision's neural models don't run in the iOS simulator (default device: "Failed to
  // create espresso context"; CPU: the same wrong label for every image; GPU: refused). Test
  // on an iPhone or a Mac; the simulator uses --fake-vision instead.

  // MARK: Labels

  // Labels that describe a scene, a room, a material or a whole category rather than one
  // object you could pick up. Picked by hand from Vision's label list.
  static let broadLabels: Set<String> = [
    "adult", "baby", "child", "teen", "people", "crowd",
    "structure", "building", "interior_room", "interior_shop", "outdoor", "land", "sky",
    "blue_sky", "cloudy", "daytime", "night_sky", "water", "water_body", "waterways",
    "furniture", "table", "desk", "material", "textile", "wood_processed", "wood_natural",
    "raw_glass", "machine", "tool", "container", "consumer_electronics", "housewares",
    "appliance", "office_supplies", "document", "printed_page", "screenshot", "illustrations",
    "art", "decoration", "light", "conveyance", "vehicle", "clothing", "food", "drink",
    "liquid", "animal", "mammal", "vegetation", "grass", "rocks", "sand", "snow", "dirt_road", "foliage", "games", "sport", "media",
    "music", "recreation", "celebration", "diagram", "chart", "handwriting", "frame",
    "living_room", "bedroom", "kitchen", "kitchen_room", "dining_room", "bathroom",
    "bathroom_room", "classroom", "cubicle", "conference", "office", "room",
    "utensil", "tableware", "cookware", "sports_equipment", "musical_instrument",
    "optical_equipment", "headgear", "footwear", "jewelry", "seat", "chair_other",
    "glove_other", "road_other", "snake_other", "candy_other", "celestial_body_other",
  ]

  // Shorter names for labels that read oddly on the glasses.
  static let renames: [String: String] = [
    "computer_mouse": "mouse", "computer_keyboard": "keyboard",
    "computer_monitor": "monitor", "computer_tower": "computer",
    "drinking_glass": "glass", "basket_container": "basket", "trash_can": "trash can",
    "wine_bottle": "bottle", "cardboard_box": "box", "speakers_music": "speaker",
    "pot_cooking": "pot", "light_bulb": "light bulb", "iron_clothing": "iron",
    "tea_drink": "tea", "sticky_note": "sticky note", "credit_card": "card",
    "play_card": "playing card", "eyeglasses": "glasses", "timepiece": "watch",
  ]

  static func displayName(_ identifier: String) -> String {
    if let renamed = renames[identifier] { return renamed }
    return identifier.replacingOccurrences(of: "_", with: " ")
  }

  // MARK: Geometry

  func padded(_ r: CGRect, by f: CGFloat) -> CGRect {
    r.insetBy(dx: -r.width * f, dy: -r.height * f)
      .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

extension CGRect {
  var center: CGPoint { CGPoint(x: midX, y: midY) }
}
