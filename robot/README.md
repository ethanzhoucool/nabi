# robot

Arm control for Nabi. This drives the SO-101 follower arm from the laptop over USB with [LeRobot](https://github.com/huggingface/lerobot).

Status: Phase 0. The environment installs and the safety checks pass their tests, but nothing here has run on a real arm yet. The safety limits in `nabi_robot/config.py` are not set, so the code refuses to move the arm until they are filled in during Phase 2.

## What's here

| File | What it is |
|---|---|
| `requirements.txt` | Pinned top-level packages: `lerobot[feetech,hardware]==0.7.0` and pytest |
| `requirements-lock.txt` | Every package version from the tested install (`pip freeze`) |
| `nabi_robot/config.py` | Port, arm id and the safety limits from [docs/safety.md](../docs/safety.md) |
| `nabi_robot/limits.py` | The workspace box, speed limit and gripper torque checks |
| `nabi_robot/arm.py` | `NabiArm`, a small wrapper around LeRobot's `SO101Follower` |
| `tests/` | Tests for the checks. No hardware needed |

## Set up the environment

LeRobot 0.7.0 needs Python 3.12 or newer. Its guide uses 3.12 with conda, and says any environment manager works. This project uses a plain venv with Homebrew's Python 3.12.

```bash
cd robot
brew install python@3.12            # if python3.12 isn't installed yet
python3.12 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt      # or requirements-lock.txt for the exact tested set
pytest
```

The `feetech` extra adds the motor driver for the STS3215 servos. The `hardware` extra adds `pynput`, `pyserial` and `deepdiff`, which the calibrate and teleoperate commands use. Recording datasets and training come later (Phase 6) and need more extras, such as `dataset` and `training`. Those also need `ffmpeg`.

On Apple Silicon, PyTorch needs macOS 14 or newer.

## First run with the kit

Do these steps for the follower arm and then the leader arm. The follower uses `--robot.*` flags and the leader uses `--teleop.*` flags. Keep the follower's 12 V supply behind the emergency stop button, as in [hardware/README.md](../hardware/README.md#wiring).

### 1. Find the ports

Plug the motor board into USB and power, then run:

```bash
lerobot-find-port
```

Unplug the USB cable when it asks and press Enter. It prints the port, something like `/dev/tty.usbmodem585A0076841`. Do this for each arm and write down which port is which. Put the follower's port in `FOLLOWER_PORT` in `nabi_robot/config.py`.

### 2. Set the motor ids

New motors all start with id 1, so each one needs its own id once. The command asks you to plug in one motor at a time, starting with the gripper.

```bash
lerobot-setup-motors --robot.type=so101_follower --robot.port=<follower port>
lerobot-setup-motors --teleop.type=so101_leader --teleop.port=<leader port>
```

### 3. Calibrate

Move the arm so every joint is in the middle of its range, press Enter, then move each joint through its full range.

```bash
lerobot-calibrate --robot.type=so101_follower --robot.port=<follower port> --robot.id=nabi_follower
lerobot-calibrate --teleop.type=so101_leader --teleop.port=<leader port> --teleop.id=nabi_leader
```

Use `nabi_follower` as the follower id. That is `FOLLOWER_ID` in `config.py`, and `NabiArm` loads the calibration saved under that name (in `~/.cache/huggingface/lerobot/calibration/`).

### 4. Check it with the leader arm

```bash
lerobot-teleoperate \
    --robot.type=so101_follower --robot.port=<follower port> --robot.id=nabi_follower \
    --teleop.type=so101_leader --teleop.port=<leader port> --teleop.id=nabi_leader
```

Moving the leader by hand should move the follower. Follow the testing rules in [docs/safety.md](../docs/safety.md#rules-for-testing): nobody at the table, and a second person at the emergency stop.

## Safety limits (Phase 2)

`nabi_robot/config.py` has three limits from docs/safety.md, all marked TODO:

- `max_joint_speed_deg_s`: top joint speed. `move_to()` splits every move into steps that stay under it.
- `workspace`: the box the gripper must stay inside. `move_to_xyz()` refuses any point outside it.
- `gripper_max_torque_limit`: written to the gripper servo's `Max_Torque_Limit` register on connect (1000 means 100%). LeRobot already writes 500 there by default.

Until a limit is set, the check that uses it raises `LimitError` and the arm does not move. `tests/test_limits.py` has a test that fails once the real values go in, as a reminder to review the tests then.

`move_to_xyz()` does nothing past the box check, because inverse kinematics is Phase 4.

## LeRobot docs used

- [Installation](https://huggingface.co/docs/lerobot/installation)
- [SO-101](https://huggingface.co/docs/lerobot/so101): find port, setup motors, calibrate
- [Cheat sheet](https://huggingface.co/docs/lerobot/cheat-sheet): all CLI commands
- [lerobot 0.7.0 on PyPI](https://pypi.org/project/lerobot/0.7.0/)

The command names here (`lerobot-find-port`, `lerobot-setup-motors`, `lerobot-calibrate`, `lerobot-teleoperate`) and the `so101_follower` and `so101_leader` types were checked against the installed 0.7.0 package. Older guides use `python -m lerobot.find_port` and other names that no longer work.
