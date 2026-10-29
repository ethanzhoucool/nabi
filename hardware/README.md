# Hardware

## Parts

The full list with prices and sources is in [bom.csv](bom.csv). Prices were checked in October 2026. Seeed sells in US dollars, so those lines are converted at 1.40 CAD/USD, and shipping is an estimate.

## Arm

LookGrab uses the SO-101 arm from the [SO-ARM100](https://github.com/TheRobotStudio/SO-ARM100) project, which is released under Apache-2.0. Its parts are printed from the upstream STL files using the print settings in that repository.

The servos come from the SO-ARM101 Pro kit. The follower arm, which does the picking, uses 12 V STS3215 servos rated at 30 kg·cm, and Seeed lists its payload as 500 g. The leader arm uses 7.4 V servos and is only plugged in when recording demonstrations for the learned grasp policy.

## Wiring

```mermaid
flowchart LR
    psu12[12 V 5 A supply] --> estop[Emergency stop button] --> fb[Follower motor board]
    fb --> fs[6 x STS3215 12 V servos]
    psu5[5 V supply] --> lb[Leader motor board] --> ls[6 x STS3215 7.4 V servos]
    fb -- USB-C --> laptop[Laptop]
    lb -- USB-C --> laptop
    webcam[Overhead webcam] -- USB --> laptop
    wrist[Wrist camera] -- USB --> laptop
```

The servos on each arm are daisy-chained on one bus. The emergency stop button sits on the follower arm's 12 V line, so it cuts power to the moving arm without touching the laptop or the cameras. It latches when pressed and has to be twisted to reset, so the arm stays off until someone turns it back on. The button is rated for 10 A, twice what the supply can deliver.

## Custom parts

These will be designed in OpenSCAD and published in this folder under the CERN-OHL-S v2 licence.

| Part | Purpose |
|---|---|
| Overhead camera mast | Clamps to the table and holds the webcam above the workspace |
| ArUco table mat | Printable sheet with four markers and an outline for the arm's base |
| Handover cradle | Marks the handover point and catches an object released early |
| Emergency stop enclosure | Holds the 22 mm button on the table, within reach of the user and the person supervising |
| Wrist camera mount | Only needed if no existing mount fits the Seeed wrist camera |
