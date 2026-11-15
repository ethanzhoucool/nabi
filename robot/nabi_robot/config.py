"""Settings and safety limits for the Nabi follower arm.

The limits come from docs/safety.md. That page says what to limit but gives no
numbers yet, so every limit below is None and marked TODO. They get set in
Phase 2 of docs/plan.md, after the arm is assembled and measured.

While a limit is None, the matching check refuses to move the arm. That way a
missing number stops the arm instead of letting it move unchecked.
"""

from dataclasses import dataclass


@dataclass(frozen=True)
class WorkspaceBox:
    """Box over the table that the gripper must stay inside, in metres.

    Coordinates are in the arm's base frame. Which way x, y and z point gets
    fixed when the ArUco mat is made (Phase 3).
    """

    x_min: float
    x_max: float
    y_min: float
    y_max: float
    z_min: float
    z_max: float

    def __post_init__(self) -> None:
        for axis in ("x", "y", "z"):
            lo, hi = getattr(self, f"{axis}_min"), getattr(self, f"{axis}_max")
            if lo >= hi:
                raise ValueError(f"{axis}_min ({lo}) must be less than {axis}_max ({hi})")

    def contains(self, xyz: tuple[float, float, float]) -> bool:
        x, y, z = xyz
        return (
            self.x_min <= x <= self.x_max
            and self.y_min <= y <= self.y_max
            and self.z_min <= z <= self.z_max
        )


@dataclass(frozen=True)
class SafetyLimits:
    # "Joint speeds are capped well below the servos' maximum" (safety.md).
    # Degrees per second, applied to every joint.
    max_joint_speed_deg_s: float | None

    # "Software keeps the gripper inside a box over the table" (safety.md).
    workspace: WorkspaceBox | None

    # "The gripper's closing torque is capped in the servo settings" (safety.md).
    # Written to the gripper servo's Max_Torque_Limit register, where 1000 is
    # 100%. LeRobot 0.7.0 already writes 500 (50%) at connect to protect the
    # motor. Nabi's cap is for fingers and should come out at or below that.
    gripper_max_torque_limit: int | None


# TODO(Phase 2): fill these in from measurements. Do not guess them.
SAFETY = SafetyLimits(
    max_joint_speed_deg_s=None,  # TODO
    workspace=None,  # TODO: WorkspaceBox(x_min=..., x_max=..., ...)
    gripper_max_torque_limit=None,  # TODO
)

# Rate move_to() sends joint targets at. 60 Hz is the default fps of
# LeRobot 0.7.0's lerobot-teleoperate.
CONTROL_HZ = 60

# TODO: set after running lerobot-find-port with the kit plugged in.
FOLLOWER_PORT: str | None = None

# Name used for the calibration file. Use the same --robot.id when running
# lerobot-calibrate, so this package loads that calibration.
FOLLOWER_ID = "nabi_follower"

# Gripper positions on LeRobot's 0 to 100 scale for the gripper joint.
# TODO(Phase 2): confirm which end is open after calibration.
GRIPPER_OPEN = 100.0
GRIPPER_CLOSED = 0.0
