# Build plan

Nabi received a CA$2,000 grant from Western University in November 2026. This page covers how the money is spent, the order things get built in, and the points where the plan changes depending on what the first tests show. [design.md](design.md) explains how the system works.

## Budget

The [parts list](../hardware/bom.csv) comes to CA$1,965.35 with shipping and HST, which leaves CA$34.65 of the grant. That is too little to cover a broken servo or a price change, so two changes are made before ordering:

| Change | Effect |
|---|---|
| Delay the wrist camera (CA$42.00 + HST) until the learned grasp policy starts. The scripted version doesn't use it | Margin rises to about CA$82 |
| Buy the glasses in person at a Meta store in Toronto, or check that online shipping is free | The CA$50 shipping estimate only has to cover the other orders: Seeed, with duties, and four Canadian suppliers |

If the learned policy goes ahead and money is left, the wrist camera is bought then. If the margin is used up, the overhead webcam can be any USB webcam already on hand.

Things to confirm before ordering:

- **What the grant covers.** Whether HST and shipping count, the deadline for submitting receipts, and whether parts become Western's property.
- **The leader arm's power supply.** The wiring needs a 5 V supply for the leader arm. Seeed's page doesn't say whether the Pro kit includes one. If it doesn't, a 5 V 3 A supply costs about CA$15.
- **The Apple developer account.** A free account can install the app on our own iPhone, but apps expire after seven days and some entitlements aren't available. Meta's CameraAccess sample asks for the Hotspot Configuration and Access Wi-Fi Information entitlements, which a free account may not be able to sign. If that needs the paid program (US$99 a year), it doesn't fit the budget, so ask Western's engineering faculty for a seat on a university team first.
- **3D printer access.** About 1 kg of PLA goes into the two arms. If no printer is available, Seeed sells the printed parts for US$29.90, about the same as the filament budget. Check whether that covers one arm or both. The custom mounts would still need printing.
- **The glasses' return policy.** The glasses are the most expensive part and the least certain one. If the first test (Phase 1) shows the toolkit can't do what Nabi needs, knowing the return window matters.

## What the glasses can do

Meta's Wearables Device Access Toolkit reached version 1.0 in September 2026 ([Meta FAQ](https://developers.meta.com/wearables/faq/), [changelog](https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md)). Everything below works in Developer Mode on our own glasses without publishing anything. Developer Mode is turned on in the Meta AI app under Settings > App Info by tapping the version number five times ([getting started](https://wearables.developer.meta.com/docs/develop/dat/getting-started-toolkit/)).

| Nabi needs | What the toolkit offers | Status |
|---|---|---|
| Video from the glasses | `MWDATCamera` streams 720×1280, 504×896 or 360×640 at 2, 7, 15, 24 or 30 fps. Meta's docs don't give camera intrinsics, so we calibrate the camera ourselves | Stable |
| A dot over the object | `MWDATDisplay` draws on the 600×600 display with FlexBox, Text, Image, Button, Icon and Video. There is no absolute positioning, and every update replaces the whole screen | Stable, with limits (see below) |
| Swipe to move the dot | The Neural Band's swipe arrives as a `.nav(left/right/up/down)` event in `MWDATInputs` | Beta |
| Pinch to confirm and stop | The pinch arrives as `.select`. There is no separate stop gesture, and `.back` isn't delivered by real glasses yet. The toolkit keeps the touchpad's tap and tap-and-hold for pausing and stopping its own session | Beta |
| Develop before the glasses arrive | `MWDATMockDevice` uses the phone's camera or a video file as the glasses' feed, previews the display and injects swipes and pinches | Stable |

Publishing isn't open yet, and beta features can't be published even when it opens ([FAQ](https://developers.meta.com/wearables/faq/), [changelog](https://github.com/meta/meta-wearables-dat-ios/blob/main/CHANGELOG.md)). Nabi isn't being published, so neither matters.

Three things matter for the design:

1. **The dot has to be drawn as an image.** The display can't place an element at an arbitrary point, so the phone draws a 600×600 picture with the dot in the right place and sends it as an `Image`. Meta warns that large images lag over Bluetooth ([display overview](https://wearables.developer.meta.com/docs/develop/dat/display-overview/)), and no update rate is published. The image is mostly black, so it should compress well, but this has to be measured.
2. **Camera and display together is a known issue.** Meta's known issues page says display updates are delayed while a capture is transferred from the Ray-Ban Display, and suggests not combining the two ([known issues](https://wearables.developer.meta.com/docs/develop/dat/knownissues/)). It isn't clear whether this applies to continuous streaming or only to photo capture. One developer reported 40 to 100 ms display updates while streaming ([amanshah0729/vision](https://github.com/amanshah0729/vision)), which would be fine.
3. **Stopping uses the same pinch as confirming.** A `.select` while the arm moves means stop. The hardware emergency stop button stays as the backup, and the phone app gets a large stop button too.

Phase 1 tests all three before anything else is built on the glasses side.

## Phases

Dates assume the arm kit arrives from Seeed in early December, about two to three weeks after ordering with customs. Exams take most of December and April, so work in those months is light and may slip.

### Phase 0: order and set up

Nov 10 to Nov 23.

- Confirm the items above, then order the arm kit, power supply, filament and emergency stop. The arm kit goes first because it has the longest shipping time.
- Buy the glasses.
- Create the Xcode project in `app/`, add the toolkit as a Swift package (`https://github.com/facebook/meta-wearables-dat-ios`) and get the `CameraAccess` and `DisplayAccess` samples running with the mock device.
- Set up the Python environment for LeRobot in `robot/`.

### Phase 1: glasses test

Nov 17 to Dec 7.

One app that streams the camera, runs a detector, sends the dot image to the display and logs swipes and pinches, all at the same time. Measure:

- camera frame rate and delay at 504×896 and 360×640
- how often the display can take a new 600×600 image while the camera is streaming
- whether pinches and swipes still arrive during streaming
- how far the calibrated dot lands from real objects at 50 to 80 cm

**Decision at the end of Phase 1:**

| Result | Plan |
|---|---|
| The dot updates at 5 or more per second and lands on the right object | Keep the design as written |
| The display updates too slowly to follow the head | Freeze the dot: take a still, show the candidates as a card with labels and arrows ("cup, left"), swipe through them, pinch to confirm |
| Streaming and display can't run together at all | Show the candidates on the phone or a laptop screen, and use the glasses for the camera and the Neural Band only |
| The toolkit can't stream reliably | Use a phone camera on a head strap for selection. Nothing on the laptop changes ([design.md](design.md#risks)) |

### Phase 2: arm

From delivery, likely early December. Assembly may run past exams into early January.

- Print and assemble both arms, and calibrate them in LeRobot.
- Wire the emergency stop into the follower arm's 12 V line and test that it cuts power.
- Set the speed limits, the workspace box and the gripper torque cap from [safety.md](safety.md).
- Measure the payload at full reach and settle the object list.

This runs alongside Phase 1 and doesn't depend on the glasses.

### Phase 3: seeing the table

Jan 5 to Feb 1.

- Print the ArUco mat and the camera mast, and calibrate the homography from the overhead camera to the table.
- Run the detector on the overhead view.
- Set up the WebSocket between the phone and the laptop. Messages: `candidate`, `confirm` (label, crop, embedding), `stop`, `status`.
- Match the confirmed object across the two views.
- **Submit the ethics application in January.** Review takes weeks, and user testing in Phase 5 can't start without approval.

### Phase 4: picking

Feb 2 to Mar 1.

- Inverse kinematics from the SO-101 URDF.
- Scripted pick and handover as listed in [design.md](design.md#picking-and-handing-over).
- Stop on pinch, on the phone's stop button, on a dropped connection and on the hardware button.
- First full run: look, pinch, pick, hand over.

### Phase 5: evaluation

Mar 2 to Mar 29.

- Stop-time tests first. All 20 must pass before the trials start.
- The 50-trial protocol in [evaluation.md](evaluation.md).
- Sessions with occupational therapists and users with limited hand mobility, if ethics approval has come through.

### Phase 6: if time allows

April, around exams.

- Buy the wrist camera, record demonstrations with the leader arm and train an ACT policy in LeRobot.
- Write up the results and receipts for the grant report.

## Spending log

Receipts go in a private folder, not this repository. Each purchase is added here as it is made.

| Date | Item | CA$ incl. tax | Running total |
|---|---|---|---|
| | | | |
