//! Evidence-backed TU3 manual MotionGraph state slice.
//!
//! Physical balance, contact loss, and virtual-resource leaf resolution are
//! intentionally supplied by callers. This module reproduces only observed
//! gates, bands, transitions, attributes, and animation-resource requests.
#![allow(dead_code)]

pub const MANUAL_BRAKE_MOVING_SPEED_THRESHOLD: f32 = 0.1;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualEntryContext {
    pub manual: f32,
    pub manual_engage_time_seconds: f32,
    pub last_state_was_air: bool,
    pub center_of_mass_velocity_y: f32,
    pub surface_slope_degrees: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualKind {
    Tail,
    Nose,
}

/// Recovered `OnGround.Turning.Manual` precondition.
pub fn requested_manual_kind(context: ManualEntryContext) -> Option<ManualKind> {
    if context.manual_engage_time_seconds <= 0.2 {
        return None;
    }
    let rejected_air_impact = context.last_state_was_air
        && context.center_of_mass_velocity_y < -8.0
        && context.surface_slope_degrees > 45.0;
    if rejected_air_impact {
        return None;
    }
    Some(if context.manual < 0.0 {
        ManualKind::Tail
    } else {
        ManualKind::Nose
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualSpeedBand {
    TailRollingBackward,
    TailForwardOrStationary,
    NoseRollingForward,
    NoseBackwardOrStationary,
}

pub fn manual_speed_band(kind: ManualKind, board_local_speed_z: f32) -> ManualSpeedBand {
    match kind {
        ManualKind::Tail if board_local_speed_z < -0.5 => ManualSpeedBand::TailRollingBackward,
        ManualKind::Tail => ManualSpeedBand::TailForwardOrStationary,
        ManualKind::Nose if board_local_speed_z > 0.5 => ManualSpeedBand::NoseRollingForward,
        ManualKind::Nose => ManualSpeedBand::NoseBackwardOrStationary,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualRevertDirection {
    Fs,
    Bs,
}

impl ManualRevertDirection {
    pub const fn attribute(self) -> f32 {
        match self {
            Self::Fs => -1.0,
            Self::Bs => 1.0,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManualPhase {
    NoseInto,
    Cycle,
    Brake,
    NoseOut,
    Revert(ManualRevertDirection),
    ExitRequested,
    Complete,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualSignals {
    pub manual: f32,
    /// Retail `AttachIntent intentname="Turn" attr="spin"` value.
    pub spin: f32,
    pub manual_brake: bool,
    pub board_local_speed_z: f32,
    pub physics_wants_manual_exit: bool,
    pub slide_fs_180: bool,
    pub slide_bs_180: bool,
    /// Remaining time in the currently resolved physical animation leaf.
    /// Virtual graph resources have no reliable duration until their concrete
    /// runtime leaf is known.
    pub animation_remaining_seconds: Option<f32>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ManualAnimationRequest {
    /// This is a MotionGraph resource. `B_*` names must be resolved to a
    /// physical ABIN leaf before the Bevy animation player consumes it.
    pub resource: &'static str,
    pub transition_seconds: f32,
    pub repeats: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ManualRuntime {
    pub kind: ManualKind,
    pub phase: ManualPhase,
    pub speed_band: ManualSpeedBand,
    /// The retail Brake child enters Moving when `abs(local Z) > 0.1` and
    /// transitions one-way to Stationary. It is selected on Brake entry,
    /// rather than recomputed as a stateless clip choice every frame.
    pub brake_moving: bool,
    pub board_local_speed_z: f32,
    pub balance: f32,
    pub spin: f32,
}

impl ManualRuntime {
    pub fn begin(kind: ManualKind, board_local_speed_z: f32) -> Self {
        Self {
            kind,
            phase: if kind == ManualKind::Nose {
                ManualPhase::NoseInto
            } else {
                ManualPhase::Cycle
            },
            speed_band: manual_speed_band(kind, board_local_speed_z),
            brake_moving: board_local_speed_z.abs() > MANUAL_BRAKE_MOVING_SPEED_THRESHOLD,
            board_local_speed_z,
            balance: if kind == ManualKind::Tail { -1.0 } else { 1.0 },
            spin: 0.0,
        }
    }

    pub fn animation_request(&self) -> Option<ManualAnimationRequest> {
        let (resource, transition_seconds, repeats) = match self.phase {
            ManualPhase::NoseInto => ("B_NOSE_MANUAL_INTO", 0.1, false),
            ManualPhase::Cycle => match self.speed_band {
                ManualSpeedBand::TailRollingBackward => ("B_TAIL_MANUAL", 0.3, true),
                ManualSpeedBand::TailForwardOrStationary => ("B_TAIL_MANUAL_LOW", 0.3, true),
                ManualSpeedBand::NoseRollingForward => ("B_NOSE_MANUAL", 0.3, true),
                ManualSpeedBand::NoseBackwardOrStationary => ("B_NOSE_MANUAL_LOW", 0.3, true),
            },
            ManualPhase::Brake => match (self.kind, self.brake_moving) {
                (ManualKind::Tail, true) => ("M_BRAKE_N_0_CYC", 0.2, true),
                (ManualKind::Tail, false) => ("M_BRAKE_STAT_0_CYC", 0.5, true),
                (ManualKind::Nose, true) => ("S_M_NOSEBRAKE_N_0_CYC", 0.2, true),
                (ManualKind::Nose, false) => ("M_NOSEBRAKE_STAT_0_CYC", 0.5, true),
            },
            ManualPhase::NoseOut => ("B_NOSE_MANUAL_OUT", 0.1, false),
            ManualPhase::Revert(direction) => {
                let resource = match (self.kind, direction) {
                    (ManualKind::Tail, ManualRevertDirection::Fs) => "B_TAIL_MANUAL_FS_REVERT",
                    (ManualKind::Tail, ManualRevertDirection::Bs) => "B_TAIL_MANUAL_BS_REVERT",
                    (ManualKind::Nose, ManualRevertDirection::Fs) => "B_NOSE_MANUAL_FS_REVERT",
                    (ManualKind::Nose, ManualRevertDirection::Bs) => "B_NOSE_MANUAL_BS_REVERT",
                };
                (resource, 0.2, false)
            }
            ManualPhase::ExitRequested | ManualPhase::Complete => return None,
        };
        Some(ManualAnimationRequest {
            resource,
            transition_seconds,
            repeats,
        })
    }

    pub fn step(&mut self, signals: ManualSignals) {
        if matches!(
            self.phase,
            ManualPhase::Complete | ManualPhase::ExitRequested
        ) {
            return;
        }

        // Brake owns a CreateAttribute(balance, +/-1) in both retail XML
        // branches. Live Manual remains attached only by Cycle; replacing
        // this forced value with a 0.9..1.0 stick sample invalidates the
        // authored brake selector and makes the visible action disappear.
        self.balance = if self.phase == ManualPhase::Brake {
            if self.kind == ManualKind::Tail {
                -1.0
            } else {
                1.0
            }
        } else {
            signals.manual
        };
        self.board_local_speed_z = signals.board_local_speed_z;
        self.spin = signals.spin;
        self.speed_band = manual_speed_band(self.kind, signals.board_local_speed_z);

        if let Some(direction) = requested_revert(signals) {
            self.phase = ManualPhase::Revert(direction);
            return;
        }

        match self.phase {
            ManualPhase::NoseInto => {
                if signals.manual <= 0.0 {
                    self.phase = ManualPhase::Complete;
                } else if signals.manual_brake
                    && will_expire_within(signals.animation_remaining_seconds, 0.1)
                {
                    self.balance = 1.0;
                    self.brake_moving =
                        signals.board_local_speed_z.abs() > MANUAL_BRAKE_MOVING_SPEED_THRESHOLD;
                    self.phase = ManualPhase::Brake;
                } else if !signals.manual_brake
                    && will_expire_within(signals.animation_remaining_seconds, 0.05)
                {
                    self.phase = ManualPhase::Cycle;
                }
            }
            ManualPhase::Cycle => {
                if signals.physics_wants_manual_exit {
                    self.phase = if self.kind == ManualKind::Nose {
                        ManualPhase::NoseOut
                    } else {
                        ManualPhase::ExitRequested
                    };
                } else if self.kind == ManualKind::Nose && signals.manual <= 0.0 {
                    self.phase = ManualPhase::NoseOut;
                } else if signals.manual_brake {
                    self.balance = if self.kind == ManualKind::Tail {
                        -1.0
                    } else {
                        1.0
                    };
                    self.brake_moving =
                        signals.board_local_speed_z.abs() > MANUAL_BRAKE_MOVING_SPEED_THRESHOLD;
                    self.phase = ManualPhase::Brake;
                }
            }
            ManualPhase::Brake => {
                if self.brake_moving
                    && signals.board_local_speed_z.abs() <= MANUAL_BRAKE_MOVING_SPEED_THRESHOLD
                {
                    self.brake_moving = false;
                }
                if signals.physics_wants_manual_exit {
                    self.phase = if self.kind == ManualKind::Nose {
                        ManualPhase::NoseOut
                    } else {
                        ManualPhase::ExitRequested
                    };
                } else if self.kind == ManualKind::Nose && signals.manual <= 0.0 {
                    self.phase = ManualPhase::NoseOut;
                } else if !signals.manual_brake {
                    self.balance = signals.manual;
                    self.phase = ManualPhase::Cycle;
                }
            }
            ManualPhase::NoseOut => {
                if will_expire_within(signals.animation_remaining_seconds, 0.1) {
                    self.phase = ManualPhase::Complete;
                }
            }
            ManualPhase::Revert(_) => {
                if will_expire_within(signals.animation_remaining_seconds, 0.01) {
                    self.phase = if self.kind == ManualKind::Nose && signals.manual <= 0.0 {
                        ManualPhase::Complete
                    } else {
                        ManualPhase::Cycle
                    };
                }
            }
            ManualPhase::ExitRequested | ManualPhase::Complete => {}
        }
    }
}

fn requested_revert(signals: ManualSignals) -> Option<ManualRevertDirection> {
    if signals.slide_bs_180 {
        Some(ManualRevertDirection::Bs)
    } else if signals.slide_fs_180 {
        Some(ManualRevertDirection::Fs)
    } else {
        None
    }
}

fn will_expire_within(remaining_seconds: Option<f32>, window_seconds: f32) -> bool {
    remaining_seconds.is_some_and(|remaining| remaining <= window_seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn entry_requires_strict_engage_time_and_rejects_observed_air_impact_case() {
        assert_eq!(
            requested_manual_kind(ManualEntryContext {
                manual: -1.0,
                manual_engage_time_seconds: 0.2,
                ..ManualEntryContext::default()
            }),
            None
        );
        assert_eq!(
            requested_manual_kind(ManualEntryContext {
                manual: -1.0,
                manual_engage_time_seconds: 0.201,
                ..ManualEntryContext::default()
            }),
            Some(ManualKind::Tail)
        );
        assert_eq!(
            requested_manual_kind(ManualEntryContext {
                manual: 1.0,
                manual_engage_time_seconds: 0.3,
                last_state_was_air: true,
                center_of_mass_velocity_y: -8.01,
                surface_slope_degrees: 45.01,
            }),
            None
        );
    }

    #[test]
    fn speed_bands_use_strict_retail_local_z_thresholds() {
        assert_eq!(
            manual_speed_band(ManualKind::Tail, -0.501),
            ManualSpeedBand::TailRollingBackward
        );
        assert_eq!(
            manual_speed_band(ManualKind::Tail, -0.5),
            ManualSpeedBand::TailForwardOrStationary
        );
        assert_eq!(
            manual_speed_band(ManualKind::Nose, 0.501),
            ManualSpeedBand::NoseRollingForward
        );
        assert_eq!(
            manual_speed_band(ManualKind::Nose, 0.5),
            ManualSpeedBand::NoseBackwardOrStationary
        );
    }

    #[test]
    fn nose_into_uses_distinct_cycle_and_brake_expiry_windows() {
        let mut nose = ManualRuntime::begin(ManualKind::Nose, 1.0);
        nose.step(ManualSignals {
            manual: 1.0,
            animation_remaining_seconds: Some(0.051),
            ..ManualSignals::default()
        });
        assert_eq!(nose.phase, ManualPhase::NoseInto);
        nose.step(ManualSignals {
            manual: 1.0,
            animation_remaining_seconds: Some(0.05),
            ..ManualSignals::default()
        });
        assert_eq!(nose.phase, ManualPhase::Cycle);

        let mut braking_nose = ManualRuntime::begin(ManualKind::Nose, 1.0);
        braking_nose.step(ManualSignals {
            manual: 1.0,
            manual_brake: true,
            animation_remaining_seconds: Some(0.1),
            ..ManualSignals::default()
        });
        assert_eq!(braking_nose.phase, ManualPhase::Brake);
    }

    #[test]
    fn brake_resources_use_strict_absolute_local_speed_threshold() {
        for (kind, speed, expected) in [
            (ManualKind::Tail, 0.1, "M_BRAKE_STAT_0_CYC"),
            (ManualKind::Tail, -0.1, "M_BRAKE_STAT_0_CYC"),
            (ManualKind::Tail, 0.100_1, "M_BRAKE_N_0_CYC"),
            (ManualKind::Tail, -0.100_1, "M_BRAKE_N_0_CYC"),
            (ManualKind::Nose, 0.1, "M_NOSEBRAKE_STAT_0_CYC"),
            (ManualKind::Nose, -0.1, "M_NOSEBRAKE_STAT_0_CYC"),
            (ManualKind::Nose, 0.100_1, "S_M_NOSEBRAKE_N_0_CYC"),
            (ManualKind::Nose, -0.100_1, "S_M_NOSEBRAKE_N_0_CYC"),
        ] {
            let mut runtime = ManualRuntime::begin(kind, speed);
            runtime.phase = ManualPhase::Brake;
            assert_eq!(
                runtime.animation_request().map(|request| request.resource),
                Some(expected)
            );
        }
    }

    #[test]
    fn brake_forces_the_authored_balance_and_latches_stationary_child() {
        for (kind, manual, forced_balance) in [
            (ManualKind::Tail, -0.99, -1.0),
            (ManualKind::Nose, 0.99, 1.0),
        ] {
            let mut runtime = ManualRuntime::begin(kind, 2.0);
            runtime.phase = ManualPhase::Brake;
            runtime.step(ManualSignals {
                manual,
                manual_brake: true,
                board_local_speed_z: 2.0,
                ..ManualSignals::default()
            });
            assert_eq!(runtime.balance, forced_balance);
            assert!(runtime.brake_moving);

            runtime.step(ManualSignals {
                manual,
                manual_brake: true,
                board_local_speed_z: 0.1,
                ..ManualSignals::default()
            });
            assert!(!runtime.brake_moving);
            let stationary = runtime.animation_request().unwrap().resource;
            runtime.step(ManualSignals {
                manual,
                manual_brake: true,
                board_local_speed_z: 0.2,
                ..ManualSignals::default()
            });
            assert_eq!(runtime.animation_request().unwrap().resource, stationary);
        }
    }

    #[test]
    fn nose_release_uses_out_resource_before_completion() {
        let mut nose = ManualRuntime::begin(ManualKind::Nose, 1.0);
        nose.phase = ManualPhase::Cycle;
        nose.step(ManualSignals {
            manual: 0.0,
            ..ManualSignals::default()
        });
        assert_eq!(nose.phase, ManualPhase::NoseOut);
        assert_eq!(
            nose.animation_request().map(|request| request.resource),
            Some("B_NOSE_MANUAL_OUT")
        );
        nose.step(ManualSignals {
            animation_remaining_seconds: Some(0.1),
            ..ManualSignals::default()
        });
        assert_eq!(nose.phase, ManualPhase::Complete);
    }

    #[test]
    fn revert_direction_attributes_and_resources_match_xml() {
        let mut tail = ManualRuntime::begin(ManualKind::Tail, 1.0);
        tail.step(ManualSignals {
            manual: -0.8,
            slide_bs_180: true,
            ..ManualSignals::default()
        });
        assert_eq!(tail.phase, ManualPhase::Revert(ManualRevertDirection::Bs));
        assert_eq!(ManualRevertDirection::Bs.attribute(), 1.0);
        assert_eq!(
            tail.animation_request().map(|request| request.resource),
            Some("B_TAIL_MANUAL_BS_REVERT")
        );
        assert_eq!(ManualRevertDirection::Fs.attribute(), -1.0);
    }

    #[test]
    fn virtual_manual_resources_are_not_claimed_as_physical_leaves() {
        let tail = ManualRuntime::begin(ManualKind::Tail, -1.0);
        let request = tail.animation_request().unwrap();
        assert!(request.resource.starts_with("B_"));
        assert_eq!(request.resource, "B_TAIL_MANUAL");
    }
}
