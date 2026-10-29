# Safety

Nabi puts a moving robot arm near a person who may not be able to get out of its way. This page lists the hazards we know about and how each one is handled. It will be reviewed again before anyone outside the project team uses the system.

## Hazards and controls

| Hazard | Control |
|---|---|
| The arm hits the user | Software keeps the gripper inside a box over the table. The only point near the user is the handover point, fixed at table height and never near the face |
| A finger gets pinched in the gripper | The gripper's closing torque is capped in the servo settings |
| The arm moves when it shouldn't | It only moves after a confirm pinch. Any pinch during a move stops it, and so does a dropped connection between the phone and the laptop |
| Software fails to stop the arm | A latching emergency stop button cuts the follower arm's power. With no power the arm goes limp and sags onto the table, so it only carries light objects |
| A dropped object causes harm | No hot drinks, glass or sharp objects |
| The arm moves too fast | Joint speeds are capped well below the servos' maximum for all testing |
| Electrical faults | Off-the-shelf power supplies, no exposed 12 V wiring, and an emergency stop rated for twice the supply's current |

## Rules for testing

- During every test, a second person stands within reach of the emergency stop button.
- New code is first run with nobody sitting at the table.
- Nobody outside the project team uses the system until Western's research ethics board has approved the study.
