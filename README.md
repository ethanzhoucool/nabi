# Nabi

Look at an object on the table, pinch your fingers, and a robot arm picks it up and hands it to you.

Nabi is an open-source robot arm you control by looking and pinching, with nothing to hold and nothing to type. Meta Ray-Ban Display glasses see what you're facing, and the Meta Neural Band wristband picks up the pinch. The arm is the open-source SO-101. All of the parts together cost just under CA$2,000.

In November 2026 Nabi received a CA$2,000 grant from Western University to buy the parts, and the build is starting. The arm and the object detection are not built yet. The repository holds the design, a priced parts list, a [build plan](docs/plan.md) with dates, a first iPhone app in [`app/`](#iphone-app) and the arm control setup in [`robot/`](robot/README.md). More code and CAD files will be added as the build goes on.

## Why

Telling a robot which object to pick up usually means a controller, a touchscreen or a typed command. Nabi tries something more direct: you look at the object and pinch. The glasses and wristband that make this possible are now consumer products.

The application with the most to gain is accessibility. For someone with limited reach, such as a wheelchair user with limited shoulder movement, a phone or a remote at the far side of a table often means asking someone else to pass it. Wheelchair-mounted assistive arms can do this, but they have been quoted at over $40,000 ([NIBIB](https://www.nibib.nih.gov/sites/default/files/R-ARM.pdf)). Research at the University of Utah, funded by Meta, found that wrist muscle signals could still drive a virtual hand for people who couldn't extend their fingers ([Meta](https://www.meta.com/en-gb/blog/university-of-utah-accessibility-research-meta-neural-band/)). Whether the Neural Band's pinch works as well for those users is one of the questions this project will test.

Choosing objects for a robot by looking at them is not a new idea. A 2018 system built from eye-tracking glasses, a depth camera and a robot arm completed 96% of its pick-and-place tasks ([arXiv:1809.08095](https://arxiv.org/abs/1809.08095)). It ran on lab equipment. Nabi tests whether off-the-shelf consumer hardware can now do the same job at a small fraction of the cost, with every design file published.

## How it works

```mermaid
flowchart LR
    band[Meta Neural Band] -- pinch, swipe --> glasses[Ray-Ban Display<br/>camera and display]
    glasses <-- Bluetooth --> phone[iPhone app<br/>object detection]
    phone <-- Wi-Fi --> laptop[Laptop<br/>matching and motion]
    cam[Overhead camera] -- USB --> laptop
    laptop -- USB --> arm[SO-101 arm]
```

1. The iPhone app streams video from the glasses and runs an object detector on it. The glasses have no eye tracking, so you aim with your head, like a red dot sight. The object behind the display becomes the candidate.
2. A dot and a label appear over the candidate in the glasses' display. Swiping moves the dot to the next object. A pinch locks it, and the dot stays on the object while the arm works.
3. A camera above the table finds the same object. Printed ArUco markers on the table turn its position in the image into table coordinates.
4. The arm reaches down, grips the object and carries it to a fixed handover point at table height.
5. When the user pinches again, the gripper opens. A pinch while the arm is moving stops it, and so does a stop button in the phone app.

The first version uses scripted grasps. A learned grasp policy, trained with [LeRobot](https://github.com/huggingface/lerobot), comes after the scripted version works end to end. [docs/design.md](docs/design.md) explains each of these choices.

## iPhone app

The first app in `app/` tests the selection step on its own. The glasses' display shows a red dot over one of three candidate objects: cup, phone and keys. A Neural Band swipe (nav left or right) moves the dot, and a pinch (select) locks it. Object detection, the camera and the robot arm come later, so the candidates are fixed for now.

The phone screen shows the status, the locked or current candidate and three buttons (Swipe left, Pinch, Swipe right) that do the same as the Neural Band. With the mock glasses the buttons go through the mock's input service, so they reach the app the same way real swipes and pinches would. The dot is drawn into a 600x600 image on a black background, since black is see-through on the real glasses.

It is built on the [Meta Wearables Device Access Toolkit](https://github.com/facebook/meta-wearables-dat-ios) (DAT) for iOS, version 1.0.1, using `MWDATCore`, `MWDATDisplay`, `MWDATInputs` and `MWDATMockDevice`. It needs iOS 17.2 or later.

### Mock or real glasses

- **iOS Simulator:** always uses mock glasses from `MockDeviceKit`, set to the Ray-Ban Display model. The phone screen shows a preview of the mock display. The app also starts a test server on port 9000 (`http://127.0.0.1:9000/`) for Meta's Display Simulator Chrome extension.
- **iPhone:** uses real glasses, unless the app is launched with `--mock`.
- **`--demo`:** after the display starts, the app swipes right, pinches, then swipes right again. CI uses this.

### Real glasses setup

1. In the Meta AI app, turn on Developer Mode: Settings > App Info, then tap App version 5 times.
2. Open Nabi and tap **Connect glasses**. This opens Meta AI, which sends you back to Nabi through the `nabi://` link.
3. Nabi waits for the glasses to connect, then starts the session and the display.

`MetaAppID` is set to `"0"`, so no Meta app ID or client token is needed in Developer Mode. Meta staff have said that Inputs and Display need no Developer Center step in Developer Mode ([discussion #352](https://github.com/meta/meta-wearables-dat-ios/discussions/352), [discussion #193](https://github.com/meta/meta-wearables-dat-ios/discussions/193)). If the glasses refuse Neural Band input anyway, the app says so and the phone buttons still work.

Known limits:

- Real glasses never send Back to apps. The Neural Band Back gesture closes the app on the glasses and ends the session ([issue #349](https://github.com/meta/meta-wearables-dat-ios/issues/349)).
- Motion needs glasses firmware 129 or later ([issue #329](https://github.com/meta/meta-wearables-dat-ios/issues/329)). The app does not use Motion yet.
- Inputs and Motion are beta, available on the development and beta release channels only.

### Project setup

The Xcode project is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `app/project.yml`. `Nabi.xcodeproj` is gitignored, so generate it after cloning or after changing `project.yml`:

```bash
cd app
brew install xcodegen   # once
xcodegen generate
```

Info.plist keys live in `project.yml` under `info.properties`. XcodeGen rewrites `NabiApp/Info.plist` on every `xcodegen generate`, so edits made to the plist directly are lost. The same goes for the entitlements file.

### Build

Keep derived data outside `~/Desktop`, for example in `~/Library/Developer/NabiBuild`. Files under Desktop can pick up extended attributes that break code signing with "resource fork, Finder information, or similar detritus not allowed".

Simulator:

```bash
cd app
xcodebuild -project Nabi.xcodeproj -scheme Nabi \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ~/Library/Developer/NabiBuild \
  build
xcrun simctl install booted ~/Library/Developer/NabiBuild/Build/Products/Debug-iphonesimulator/Nabi.app
xcrun simctl launch booted org.nabi.app          # add --demo for the scripted run
```

iPhone (pass your own Apple developer team ID):

```bash
cd app
xcodebuild -project Nabi.xcodeproj -scheme Nabi \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath ~/Library/Developer/NabiBuild \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=<your team> \
  build
```

Then install `~/Library/Developer/NabiBuild/Build/Products/Debug-iphoneos/Nabi.app` on the phone, for example with `xcrun devicectl device install app --device <device> <path to Nabi.app>`. With a free Apple ID team, installed apps expire after 7 days and need to be installed again.

### CI

[`.github/workflows/ios.yml`](.github/workflows/ios.yml) runs on pushes and pull requests that change `app/` or the workflow, and can be started by hand. On a `macos-26` runner (toolkit 1.0.1 needs Xcode 26.4 or newer) it:

1. Installs XcodeGen and generates the project.
2. Builds the app for the iOS Simulator.
3. Boots an iPhone simulator, installs the app and launches it with `--demo`.
4. Takes five screenshots, 4 seconds apart, and saves the app's console output and system log.
5. Uploads the screenshots and logs as the `simulator-screenshots` artifact, even if an earlier step failed.

It only builds for the simulator. It does not sign the app or run tests.

## Hardware

| Part | Role | Approx. CA$ |
|---|---|---|
| Meta Ray-Ban Display with Meta Neural Band | Camera, in-lens display, gesture input | 1,149 |
| SO-ARM101 Pro servo kit | 12 V follower arm, plus a leader arm for recording demonstrations | 350 |
| 12 V 5 A power supply | Powers the follower arm | 30 |
| PLA filament, 2 kg | Arm parts and custom mounts | 40 |
| USB webcam and wrist camera | Overhead and wrist views | 82 |
| Emergency stop button | Cuts power to the arm | 38 |
| Shipping | Estimate, including duties on the Seeed order | 50 |

With shipping and 13% HST the total comes to CA$1,965. The wrist camera is only needed for the learned grasp policy, so its purchase is put off until then (see the [build plan](docs/plan.md#budget)). Sources and notes for every line are in [hardware/bom.csv](hardware/bom.csv), and [hardware/README.md](hardware/README.md) covers the arm, the wiring and the custom parts. You also need an iPhone on iOS 17.2 or later, a laptop and access to a 3D printer.

## Testing plan

Ten light household objects, set out four to six at a time in five layouts, for 50 trials:

| Measure | Target |
|---|---|
| The confirmed object is the one the user meant | 90% |
| The overhead camera finds the same object | 95% |
| Pick and handover succeed | 80% |
| Median time from confirming to handover | 25 s or less |
| The arm stops on a stop pinch or the emergency stop button | Every time, within 0.5 s |

The full protocol is in [docs/evaluation.md](docs/evaluation.md). Testing with people who have limited hand mobility will only start after ethics approval.

## Safety

The arm runs on small hobby servos and moves slowly. It hands objects over at table height, away from the face. Software limits its speed and the space it can reach, and a latching emergency stop button cuts its power. [docs/safety.md](docs/safety.md) goes through each hazard and how it is handled.

## Roadmap

The phases, dates and decision points are in [docs/plan.md](docs/plan.md).

- [ ] Order parts and set up the toolkit with Meta's mock device
- [ ] Print, assemble and calibrate both arms in LeRobot
- [ ] iPhone app showing the glasses' camera feed and a test dot on the display
- [ ] Test streaming, display updates and Neural Band input together, and how well a calibrated dot lines up with real objects
- [ ] Submit the ethics application
- [ ] Object detection and the selection dot
- [ ] Neural Band confirm and stop
- [ ] Overhead camera calibration with ArUco markers
- [ ] Matching objects between the glasses' view and the overhead view
- [ ] Scripted pick and handover
- [ ] 50-trial evaluation
- [ ] Learned grasp policy

## Repository layout

```
app/        iPhone app (XcodeGen project, Swift sources)
docs/       design notes, build plan, test plan, safety
hardware/   bill of materials, wiring, custom parts
robot/      arm control with LeRobot, safety limit checks and tests
```

## License

Software is released under the Apache License 2.0 ([LICENSE](LICENSE)). Hardware designs in `hardware/` are released under the CERN Open Hardware Licence v2, Strongly Reciprocal ([hardware/LICENSE](hardware/LICENSE)). Documentation is released under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

## Built on

- [SO-ARM100 and SO-101](https://github.com/TheRobotStudio/SO-ARM100) by The Robot Studio and Hugging Face
- [LeRobot](https://github.com/huggingface/lerobot) by Hugging Face
- [Meta Wearables Device Access Toolkit](https://wearables.developer.meta.com/docs/develop/)

## Author

Ethan Zhou, Western University
