# Evaluation plan

The first round of testing is done by the project team. Testing with people who have limited hand mobility needs ethics approval, so it is described separately at the end.

## Setup

The arm is clamped at a marked spot on the ArUco table mat. The user sits at the table facing the workspace, with the objects 50 to 80 cm away.

The starting object list is a TV remote, a phone, a pill bottle, a plastic cup, a granola bar, a glasses case, a pack of tissues, a hairbrush, a small notebook and a lip balm. It may change once the arm's payload has been measured.

There are five fixed layouts with four to six objects each. Each layout is photographed so it can be set up the same way every time.

## Trials

In each trial, the experimenter names a target. The user selects it with the glasses and pinches to confirm, and the system picks it up and brings it to the handover point. Ten trials per layout gives 50 in total.

For every trial we log:

- the named target
- the object on the selection card at the moment of the pinch
- the object matched in the overhead view
- whether the grasp and the handover succeeded
- timestamps for the confirm pinch, the grasp and arrival at the handover point
- any stop events

The overhead camera records every trial, and the glasses' built-in display recording captures what the user saw.

Each failure is put into one of five groups: selection, matching, grasp, handover or other. This shows which stage needs work next.

## Measures and targets

| Measure | How it's measured | Target |
|---|---|---|
| Selection accuracy | The first confirmed object matches the named target | 90% or more |
| Cross-view match | The overhead match is the confirmed object | 95% or more |
| Pick and handover | The object reaches the handover point and is released on the pinch | 80% or more |
| Time | Median time from the confirm pinch to arrival at the handover point | 25 s or less |
| Stopping | 20 separate tests of the stop pinch and the power switch during motion, timed from the overhead video | Every test stops within 0.5 s |
| Cost | Receipts for all purchased parts | Under CA$2,000 |

## User feedback

Once Western's research ethics board approves the study, occupational therapists and people with limited hand mobility will each use the system for a short session. Afterwards they fill in the System Usability Scale. The target is 68 or higher, which is the usual benchmark for average usability.

None of this happens before approval.
