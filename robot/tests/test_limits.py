"""Tests for the safety checks. No hardware needed.

The limit values here are test fixtures only, not the real limits for the arm.
"""

import pytest

from nabi_robot import config
from nabi_robot.arm import NabiArm
from nabi_robot.config import SafetyLimits, WorkspaceBox
from nabi_robot.limits import (
    LimitError,
    check_gripper_torque,
    check_in_workspace,
    plan_joint_steps,
)

BOX = WorkspaceBox(x_min=0.0, x_max=1.0, y_min=-1.0, y_max=1.0, z_min=0.0, z_max=1.0)
LIMITS = SafetyLimits(max_joint_speed_deg_s=30.0, workspace=BOX, gripper_max_torque_limit=300)
UNSET = SafetyLimits(max_joint_speed_deg_s=None, workspace=None, gripper_max_torque_limit=None)


def test_point_inside_box_passes():
    check_in_workspace((0.5, 0.0, 0.5), LIMITS)
    check_in_workspace((0.0, -1.0, 0.0), LIMITS)  # edges count as inside


@pytest.mark.parametrize("xyz", [(1.01, 0, 0.5), (0.5, -1.5, 0.5), (0.5, 0, -0.01), (float("nan"), 0, 0)])
def test_point_outside_box_is_refused(xyz):
    with pytest.raises(LimitError):
        check_in_workspace(xyz, LIMITS)


def test_bad_box_is_rejected():
    with pytest.raises(ValueError):
        WorkspaceBox(x_min=1.0, x_max=0.0, y_min=0, y_max=1, z_min=0, z_max=1)


def test_unset_limits_refuse_to_move():
    with pytest.raises(LimitError):
        check_in_workspace((0.5, 0, 0.5), UNSET)
    with pytest.raises(LimitError):
        plan_joint_steps({"a": 0.0}, {"a": 10.0}, UNSET, control_hz=60)
    with pytest.raises(LimitError):
        check_gripper_torque(UNSET)


def test_shipped_config_is_still_unset():
    # Fails on purpose once real limits are filled in, as a reminder to update these tests.
    assert config.SAFETY == UNSET


def test_steps_never_exceed_speed_limit():
    hz = 60
    start = {"a": 0.0, "b": 10.0}
    target = {"a": 90.0, "b": -20.0}
    steps = plan_joint_steps(start, target, LIMITS, control_hz=hz)
    max_step = LIMITS.max_joint_speed_deg_s / hz
    prev = start
    for step in steps:
        for j in start:
            assert abs(step[j] - prev[j]) <= max_step + 1e-9
        prev = step
    assert steps[-1] == pytest.approx(target)
    # 90 degrees at 30 deg/s takes 3 s, which is 180 ticks at 60 Hz.
    assert len(steps) == 180


def test_joints_not_in_target_stay_put():
    steps = plan_joint_steps({"a": 0.0, "b": 5.0}, {"a": 1.0}, LIMITS, control_hz=60)
    assert all(s["b"] == 5.0 for s in steps)


def test_unknown_joint_is_refused():
    with pytest.raises(LimitError):
        plan_joint_steps({"a": 0.0}, {"z": 1.0}, LIMITS, control_hz=60)


@pytest.mark.parametrize("cap", [0, 1001])
def test_gripper_torque_out_of_range(cap):
    limits = SafetyLimits(max_joint_speed_deg_s=30.0, workspace=BOX, gripper_max_torque_limit=cap)
    with pytest.raises(LimitError):
        check_gripper_torque(limits)


def test_xyz_move_checks_box_before_anything_else():
    arm = NabiArm(port="/dev/null", limits=LIMITS)
    with pytest.raises(LimitError):
        arm.move_to_xyz((5.0, 0.0, 0.0))
    with pytest.raises(NotImplementedError):
        arm.move_to_xyz((0.5, 0.0, 0.5))


def test_arm_needs_a_port():
    with pytest.raises(ValueError):
        NabiArm(port=None)
