# Design notes

How Nabi is meant to work, and why each part was chosen. This will change as the build goes on.

## Goals

A person who can turn their head and make a small finger movement should be able to get an object from a table without help. The parts should cost under CA$2,000, and anyone should be able to buy or print them. All code and design files are public.

The first version does not try to feed anyone, open doors, lift heavy objects or mount on a wheelchair.

## System overview

The work is split across three devices:

| Device | Runs | Talks to |
|---|---|---|
| Ray-Ban Display and Neural Band | Nothing custom. Camera, display and gesture input only | iPhone, over Bluetooth |
| iPhone | Swift app using the Meta Wearables Device Access Toolkit. Object detection, the selection dot, input handling | Glasses; laptop over a local WebSocket |
| Laptop | Python with LeRobot. Overhead camera, object matching, motion planning, servo control | iPhone; arm and cameras over USB |

Meta's toolkit is a mobile SDK, so the glasses have to connect through a phone app. LeRobot and the arm's servo bus need a computer. Keeping the robot side on the laptop has a second benefit: the arm can be built and tested before the glasses work, and it doesn't care where the selection comes from.

## Selecting an object

The hardware sets a few limits:

- The toolkit streams the glasses' camera over Bluetooth at up to 720×1280 and 30 fps. One developer measured 504×896 at 29 to 32 fps from a Ray-Ban Display, and reported display updates of 40 to 100 ms while streaming ([amanshah0729/vision](https://github.com/amanshah0729/vision)).
- There is no eye tracking, so head direction stands in for gaze.
- Apps only receive Neural Band gestures as events, through the toolkit's beta Inputs capability: a swipe arrives as a direction and a pinch as "select". The raw muscle signal isn't available.
- The display is 600×600 pixels in the right lens and covers only a small part of the view. It isn't anchored to the world, so anything drawn over a real object has to be lined up by calibration.
- The display API lays out text, images and buttons with FlexBox and replaces the whole screen on every update. Nothing can be placed at an exact pixel, so the dot is drawn into a 600×600 image on the phone and sent as one picture ([display overview](https://wearables.developer.meta.com/docs/develop/dat/display-overview/)).
- Meta lists a known issue with combining camera capture and the display on the Ray-Ban Display ([known issues](https://wearables.developer.meta.com/docs/develop/dat/knownissues/)). The [build plan](plan.md#what-the-glasses-can-do) tests this first.

Selection works like a red dot sight. The user turns their head so the object sits behind the display. Each frame goes through an object detector (a YOLO-family model converted to Core ML), and every detection gets a score based on how close it is to the display's line of sight and how confident the detector is. The best one becomes the candidate once it has stayed on top for about half a second, which keeps the dot from jumping between objects.

A dot is drawn where the candidate appears through the lens, with its label beside it. Swiping moves the dot to the next detection. A pinch locks it: the dot changes colour, the phone tracks the object from frame to frame so the dot stays on it, and the label, the crop and an image embedding go to the laptop.

### Lining up the dot

The camera sits on the frame rather than at the eye, and the display sits slightly differently for each wearer, so a pixel in the camera image doesn't land on the same spot through the lens. A one-time calibration fixes this. The user looks at an object on the mat and swipes the dot until it sits on the object, at a few points across the table, and the app fits a mapping from camera pixels to display pixels. Objects on the table are 50 to 80 cm away, so one mapping should hold across the workspace. The dot only has to be close enough to tell neighbouring objects apart.

If display updates while streaming really take 40 to 100 ms, the dot will trail fast head movements and settle when the head is still. Phase 1 of the [build plan](plan.md#phase-1-glasses-test) measures this. The display is in the right lens only, which may make aiming harder for people whose left eye is dominant.

Nobody has published how well this lines up on these glasses, so it is the first thing tested once they arrive. If the dot can't be lined up well enough, the fallback is a still card of candidates with labels, or the phone screen, as set out in the [Phase 1 decisions](plan.md#phase-1-glasses-test).

## Finding the object on the table

The glasses and the overhead camera see the table from different angles, so the selection has to be matched across the two views. The laptop runs the same detector on the overhead image and keeps detections with the same label. If more than one is left (two cups, say), it compares image embeddings of the crops and picks the closest. When the top two are too close to call, the glasses show both and the user swipes to choose.

Four ArUco markers at known spots on a [printed table mat](../hardware/README.md#custom-parts) give a homography from the overhead image to the table surface. The arm's base sits at a marked position on the same mat, so a point on the table converts straight to arm coordinates. The first version assumes one grasp height per object type rather than measuring depth.

## Picking and handing over

Version 1 is scripted:

1. Move above the object at a safe height.
2. Turn the gripper to line up with the object's short side, taken from its outline in the overhead image.
3. Lower, and close the gripper until the servo's load reading shows contact.
4. Lift, move to the handover point and wait.
5. Open the gripper when the user pinches.

Inverse kinematics uses the arm's published URDF model.

Version 2 replaces steps 2 and 3 with a learned policy (ACT or SmolVLA in LeRobot), trained on demonstrations recorded by moving the leader arm by hand. That is deliberately the second step. In a 2026 benchmark on the SO-101, both policies succeeded on roughly a third of attempts across four tabletop tasks, even after 100 demonstrations per task ([arXiv:2606.08881](https://arxiv.org/abs/2606.08881)). A scripted grasp on simple shapes should do better than that, and it gives the project a working baseline.

The follower arm's 12 V servos are rated at 30 kg·cm, and Seeed lists a 500 g payload. How much it can actually lift at full reach is the first thing to measure, and the [object list for testing](evaluation.md#setup) gets fixed after that.

## Risks

| Risk | Plan |
|---|---|
| Glasses video is slow or drops out | Selection only needs a few frames per second. If the toolkit fails entirely, a phone camera on a head strap can do the selecting and nothing on the laptop changes |
| The wrong object gets selected | The label shows next to the dot before anything moves, swiping corrects it, and the arm never moves without a pinch |
| The dot doesn't line up with the real object | Recalibrate for each wearer. If that isn't enough, switch to a still card of labelled candidates |
| Scripted grasps fail on some shapes | Limit version 1 to shapes that work, log the failures, and use them to train the learned policy |
| Neural Band input is still a beta feature in the toolkit | The prototype runs on our own glasses in Developer Mode and isn't published, so beta features are allowed. The phone app is the backup. The touchpad is limited, because the toolkit keeps tap and tap-and-hold for its own session controls |
| The display can't keep up with the camera stream | Show a still card of candidates with labels instead of a moving dot, or show them on the phone. See the decision table in the [build plan](plan.md#phase-1-glasses-test) |
| A pinch to stop is the same event as a pinch to confirm | Any pinch while the arm moves means stop. The phone app has a stop button, and the hardware emergency stop stays in reach |
| The arm is too weak | Measure payload first and choose test objects to fit |
