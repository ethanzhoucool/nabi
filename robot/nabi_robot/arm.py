"""Thin wrapper around LeRobot's SO-101 follower with Nabi's safety checks.

This is a stub for Phase 0. It has not been run against a real arm yet.
Moving to an xyz point needs inverse kinematics, which comes in Phase 4, so
move_to_xyz() only checks the workspace box for now.
"""

import time

from . import config
from .config import SafetyLimits
from .limits import check_gripper_torque, check_in_workspace, plan_joint_steps

JOINTS = ("shoulder_pan", "shoulder_lift", "elbow_flex", "wrist_flex", "wrist_roll", "gripper")


class NabiArm:
    def __init__(
        self,
        port: str | None = config.FOLLOWER_PORT,
        robot_id: str = config.FOLLOWER_ID,
        limits: SafetyLimits = config.SAFETY,
        control_hz: float = config.CONTROL_HZ,
    ):
        if port is None:
            raise ValueError("No port given. Run lerobot-find-port and set FOLLOWER_PORT in config.py.")
        self.port = port
        self.robot_id = robot_id
        self.limits = limits
        self.control_hz = control_hz
        self._robot = None
        self._stop_requested = False

    def connect(self) -> None:
        """Connect to the follower and apply the gripper torque cap."""
        # Imported here so the limit checks and tests work without LeRobot hardware.
        from lerobot.robots.so_follower import SO101Follower, SO101FollowerConfig

        cap = check_gripper_torque(self.limits)  # refuse to connect without a cap
        robot = SO101Follower(SO101FollowerConfig(port=self.port, id=self.robot_id))
        # calibrate=False: calibration is done once with lerobot-calibrate, not here.
        robot.connect(calibrate=False)
        if not robot.is_calibrated:
            robot.disconnect()
            raise RuntimeError(
                f"No calibration found for id '{self.robot_id}'. Run lerobot-calibrate first (see README)."
            )
        # LeRobot writes its own gripper limit during connect(). Write ours after it.
        with robot.bus.torque_disabled("gripper"):
            robot.bus.write("Max_Torque_Limit", "gripper", cap)
        self._robot = robot

    def disconnect(self) -> None:
        if self._robot is not None:
            self._robot.disconnect()
            self._robot = None

    def joint_positions(self) -> dict[str, float]:
        obs = self._require_robot().get_observation()
        return {j: obs[f"{j}.pos"] for j in JOINTS}

    def move_to(self, target: dict[str, float]) -> None:
        """Move joints to `target` (degrees, gripper 0 to 100) under the speed limit.

        stop() from another thread ends the move at the next tick.
        """
        robot = self._require_robot()
        steps = plan_joint_steps(self.joint_positions(), target, self.limits, self.control_hz)
        self._stop_requested = False
        period = 1.0 / self.control_hz
        for step in steps:
            if self._stop_requested:
                return
            robot.send_action({f"{j}.pos": v for j, v in step.items()})
            time.sleep(period)

    def move_to_xyz(self, xyz: tuple[float, float, float]) -> None:
        """Placeholder until inverse kinematics exists (Phase 4).

        The workspace check runs first, so an out-of-box target is refused
        even now.
        """
        check_in_workspace(xyz, self.limits)
        raise NotImplementedError("Inverse kinematics comes in Phase 4.")

    def open_gripper(self) -> None:
        self.move_to({"gripper": config.GRIPPER_OPEN})

    def close_gripper(self) -> None:
        # TODO(Phase 4): stop closing when the load reading shows contact (design.md).
        self.move_to({"gripper": config.GRIPPER_CLOSED})

    def stop(self) -> None:
        """Stop moving and hold the current position.

        This is a software stop. The hardware emergency stop button is the backup.
        """
        self._stop_requested = True
        if self._robot is not None:
            here = self.joint_positions()
            self._robot.send_action({f"{j}.pos": v for j, v in here.items()})

    def _require_robot(self):
        if self._robot is None:
            raise RuntimeError("Arm is not connected. Call connect() first.")
        return self._robot
