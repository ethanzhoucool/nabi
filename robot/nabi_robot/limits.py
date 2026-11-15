"""Safety checks that need no hardware, so they can be tested on a laptop."""

import math

from .config import SafetyLimits


class LimitError(Exception):
    """Raised when a target breaks a safety limit or a limit is not set yet."""


def check_in_workspace(xyz: tuple[float, float, float], limits: SafetyLimits) -> None:
    """Refuse a gripper target outside the workspace box."""
    if limits.workspace is None:
        raise LimitError("Workspace box is not set (TODO in config.py). Refusing to move.")
    if not all(math.isfinite(v) for v in xyz):
        raise LimitError(f"Target {xyz} is not a finite point.")
    if not limits.workspace.contains(xyz):
        raise LimitError(f"Target {xyz} is outside the workspace box {limits.workspace}.")


def max_step_deg(limits: SafetyLimits, control_hz: float) -> float:
    """Largest joint change allowed in one control tick."""
    if limits.max_joint_speed_deg_s is None:
        raise LimitError("Joint speed limit is not set (TODO in config.py). Refusing to move.")
    if limits.max_joint_speed_deg_s <= 0 or control_hz <= 0:
        raise LimitError("Speed limit and control rate must be positive.")
    return limits.max_joint_speed_deg_s / control_hz


def plan_joint_steps(
    start: dict[str, float],
    target: dict[str, float],
    limits: SafetyLimits,
    control_hz: float,
) -> list[dict[str, float]]:
    """Split a joint move into steps no joint can take faster than the speed limit.

    Returns one dict per control tick. The last one equals the target. Joints
    in `start` but not in `target` stay where they are.
    """
    unknown = set(target) - set(start)
    if unknown:
        raise LimitError(f"Unknown joints in target: {sorted(unknown)}")
    if not all(math.isfinite(v) for v in target.values()):
        raise LimitError("Target has a non-finite joint value.")

    step = max_step_deg(limits, control_hz)
    biggest = max((abs(target[j] - start[j]) for j in target), default=0.0)
    n = max(1, math.ceil(biggest / step))
    return [
        {j: start[j] + (target.get(j, start[j]) - start[j]) * (i / n) for j in start}
        for i in range(1, n + 1)
    ]


def check_gripper_torque(limits: SafetyLimits) -> int:
    """Return the gripper torque cap, or refuse if it is missing or out of range."""
    cap = limits.gripper_max_torque_limit
    if cap is None:
        raise LimitError("Gripper torque cap is not set (TODO in config.py). Refusing to connect.")
    if not 0 < cap <= 1000:
        raise LimitError(f"Gripper torque cap {cap} must be between 1 and 1000.")
    return cap
