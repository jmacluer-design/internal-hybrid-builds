//! Evidence-backed boundary for Skate 3 TU3's riding-force, post-physics,
//! heading-factor, and body-tilt pipeline.
//!
//! This module deliberately stops at unresolved retail dependencies. In
//! particular, it does not invent force accumulation, contact response,
//! heading geometry, point-graph values, or body-tilt clamp attributes.
#![allow(dead_code)] // Central `sim.rs` integration is owned by the main agent.

/// `Skateboard::AddSkateboardForce` stores at most 21 records.
pub const MAX_QUEUED_SKATEBOARD_FORCES: usize = 21;

/// Raw TU3 `eSkateboardForceType`.
///
/// The enum's numeric variants have not yet been recovered, so assigning
/// semantic Rust variants would manufacture evidence.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
#[repr(transparent)]
pub struct SkateboardForceType(pub u32);

#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct RetailVec4 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl RetailVec4 {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0, 0.0);

    pub const fn new(x: f32, y: f32, z: f32, w: f32) -> Self {
        Self { x, y, z, w }
    }
}

/// Exact 48-byte record shape copied by `AddSkateboardForce` at `0x82C03EF0`.
///
/// TU3 stores the raw force type at byte 0, the first vector at byte 16, and
/// the second vector at byte 32. The meanings of both vectors remain
/// unresolved, hence the intentionally neutral field names.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C, align(16))]
pub struct SkateboardForce {
    pub force_type: SkateboardForceType,
    reserved_04_0f: [u32; 3],
    pub payload_0: RetailVec4,
    pub payload_1: RetailVec4,
}

impl SkateboardForce {
    pub const fn new(
        force_type: SkateboardForceType,
        payload_0: RetailVec4,
        payload_1: RetailVec4,
    ) -> Self {
        Self {
            force_type,
            reserved_04_0f: [0; 3],
            payload_0,
            payload_1,
        }
    }
}

/// Fixed-capacity queue matching the observed retail admission gate.
#[derive(Clone, Debug)]
pub struct SkateboardForceQueue {
    entries: [Option<SkateboardForce>; MAX_QUEUED_SKATEBOARD_FORCES],
    len: usize,
}

impl Default for SkateboardForceQueue {
    fn default() -> Self {
        Self {
            entries: [None; MAX_QUEUED_SKATEBOARD_FORCES],
            len: 0,
        }
    }
}

impl SkateboardForceQueue {
    pub const fn len(&self) -> usize {
        self.len
    }

    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Mirrors TU3's `count >= 21` early return. A rejected record leaves the
    /// queue unchanged.
    pub fn add(&mut self, force: SkateboardForce) -> bool {
        if self.len >= MAX_QUEUED_SKATEBOARD_FORCES {
            return false;
        }
        self.entries[self.len] = Some(force);
        self.len += 1;
        true
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = &SkateboardForce> {
        self.entries[..self.len]
            .iter()
            .map(|entry| entry.as_ref().expect("occupied queue prefix"))
    }

    pub fn clear(&mut self) {
        for entry in &mut self.entries[..self.len] {
            *entry = None;
        }
        self.len = 0;
    }
}

/// Raw `PostPhysicsResult` values returned by `UpdatePostPhysics`.
///
/// The semantic retail enum labels are not present in the available symbols.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum PostPhysicsResultCode {
    Variant0 = 0,
    Variant1 = 1,
    Variant2 = 2,
}

/// Source slots passed to `PostPhysics_AdjustHeading` by `UpdatePostPhysics`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeadingAdjustmentSource {
    PhysicsBlockOffset64,
    PhysicsBlockOffset128,
}

/// Directly observed branch inputs, named by operation rather than guessed
/// gameplay meaning.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PostPhysicsBranchInput {
    /// Raw result written to byte `+291` by the call at `0x82C0215C`.
    pub precheck_flag: u8,
    /// Boolean returned by the call at `0x82C02168`.
    pub select_variant_2: bool,
    /// `component[1] > 0.0` from the first observed vector source.
    pub first_component_1_positive: bool,
    /// `component[1] < 0.0` from the queued physics block at `+400`.
    pub queued_component_1_negative: bool,
    /// Existing byte at physics-object offset `+290`.
    pub variant_1_latched: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PostPhysicsPlan {
    pub write_precheck_flag: u8,
    pub result: PostPhysicsResultCode,
    pub heading_adjustment: Option<HeadingAdjustmentSource>,
    pub set_flag_289: bool,
    pub clear_body_channel_0: bool,
    pub submit_force_queue_to_solver: bool,
    pub run_normal_finalizer: bool,
    /// Every return path rewinds the retail vector pointers to the empty
    /// position, including paths that skip force submission.
    pub clear_force_queue: bool,
}

/// Reproduces the observed top-level branch order in
/// `Skateboard::UpdatePostPhysics` (`0x82C02138`).
pub const fn plan_post_physics(input: PostPhysicsBranchInput) -> PostPhysicsPlan {
    if input.select_variant_2 {
        return PostPhysicsPlan {
            write_precheck_flag: input.precheck_flag,
            result: PostPhysicsResultCode::Variant2,
            heading_adjustment: Some(HeadingAdjustmentSource::PhysicsBlockOffset64),
            set_flag_289: true,
            clear_body_channel_0: false,
            submit_force_queue_to_solver: false,
            run_normal_finalizer: false,
            clear_force_queue: true,
        };
    }

    if input.first_component_1_positive
        && input.queued_component_1_negative
        && !input.variant_1_latched
    {
        return PostPhysicsPlan {
            write_precheck_flag: input.precheck_flag,
            result: PostPhysicsResultCode::Variant1,
            heading_adjustment: Some(HeadingAdjustmentSource::PhysicsBlockOffset128),
            set_flag_289: false,
            clear_body_channel_0: true,
            submit_force_queue_to_solver: false,
            run_normal_finalizer: false,
            clear_force_queue: true,
        };
    }

    PostPhysicsPlan {
        write_precheck_flag: input.precheck_flag,
        result: PostPhysicsResultCode::Variant0,
        heading_adjustment: None,
        set_flag_289: false,
        clear_body_channel_0: false,
        submit_force_queue_to_solver: true,
        run_normal_finalizer: true,
        clear_force_queue: true,
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ForceQueueCompletion {
    pub submitted_to_solver: usize,
    pub discarded_without_solver: usize,
}

/// Applies only the queue-lifetime behavior proven at `0x82C02350`.
///
/// Actual force/contact solving remains outside this module until the
/// consumer behind `0x82C07D20` has been recovered.
pub fn complete_force_queue(
    queue: &mut SkateboardForceQueue,
    plan: PostPhysicsPlan,
) -> ForceQueueCompletion {
    let queued = queue.len();
    let completion = if plan.submit_force_queue_to_solver {
        ForceQueueCompletion {
            submitted_to_solver: queued,
            discarded_without_solver: 0,
        }
    } else {
        ForceQueueCompletion {
            submitted_to_solver: 0,
            discarded_without_solver: queued,
        }
    };
    if plan.clear_force_queue {
        queue.clear();
    }
    completion
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnresolvedHeadingAdjustment {
    LocalHeadingAngleExtraction,
    BoardBasisAndQuaternionComposition,
    RuntimeMaximumAdjustmentRate,
    PhysicsWriteAt82C0B2C8,
}

/// Static analysis proves the call sites and their ordering but not enough
/// runtime structure semantics to reproduce `PostPhysics_AdjustHeading`
/// without guessing.
pub const UNRESOLVED_HEADING_ADJUSTMENT: [UnresolvedHeadingAdjustment; 4] = [
    UnresolvedHeadingAdjustment::LocalHeadingAngleExtraction,
    UnresolvedHeadingAdjustment::BoardBasisAndQuaternionComposition,
    UnresolvedHeadingAdjustment::RuntimeMaximumAdjustmentRate,
    UnresolvedHeadingAdjustment::PhysicsWriteAt82C0B2C8,
];

/// Counter/clock state used by `CalculateHeadingAdjustFactor` at `0x82D8A828`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeadingAdjustFactorState {
    pub previous_primary_mode: i32,
    pub mode_change_counter: u32,
    pub active_time_seconds: f32,
    pub counter_at_or_below_151: bool,
    pub last_resolved_factor: Option<f32>,
}

impl HeadingAdjustFactorState {
    /// Initial state is caller-supplied because the retail constructor's field
    /// initialization has not yet been recovered.
    pub const fn from_retail_snapshot(
        previous_primary_mode: i32,
        mode_change_counter: u32,
        active_time_seconds: f32,
    ) -> Self {
        Self {
            previous_primary_mode,
            mode_change_counter,
            active_time_seconds,
            counter_at_or_below_151: mode_change_counter <= 151,
            last_resolved_factor: None,
        }
    }

    /// Advances the recovered counter and curve-abscissa logic. Sampling the
    /// retail point graph is deliberately a separate evidence step.
    pub fn step(
        &mut self,
        input: HeadingAdjustFactorInput,
    ) -> Result<HeadingFactorCurveRequest, HeadingFactorStepError> {
        if !input.fixed_delta_seconds.is_finite() || input.fixed_delta_seconds < 0.0 {
            return Err(HeadingFactorStepError::InvalidFixedDelta);
        }

        if input.primary_mode != self.previous_primary_mode {
            self.mode_change_counter = self
                .mode_change_counter
                .wrapping_add(mode_change_increment(input.primary_mode));
            self.previous_primary_mode = input.primary_mode;
        }

        self.mode_change_counter = self.mode_change_counter.saturating_sub(1);
        self.counter_at_or_below_151 = self.mode_change_counter <= 151;

        if input.secondary_mode == 400 || input.primary_mode == 701 {
            self.active_time_seconds += input.fixed_delta_seconds;
        } else {
            self.active_time_seconds = 0.0;
        }

        Ok(HeadingFactorCurveRequest {
            abscissa_seconds: self.active_time_seconds,
        })
    }

    pub fn accept_curve_sample(
        &mut self,
        sample: HeadingFactorCurveSample,
    ) -> Result<f32, HeadingFactorStepError> {
        if !sample.0.is_finite() {
            return Err(HeadingFactorStepError::InvalidCurveSample);
        }
        self.last_resolved_factor = Some(sample.0);
        Ok(sample.0)
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HeadingAdjustFactorInput {
    /// Raw field at owner offset `+2508`.
    pub primary_mode: i32,
    /// Raw field at owner offset `+2512`.
    pub secondary_mode: i32,
    /// Raw fixed-step scalar at owner offset `+2604`.
    pub fixed_delta_seconds: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeadingFactorCurveRequest {
    pub abscissa_seconds: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HeadingFactorCurveSample(pub f32);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HeadingFactorStepError {
    InvalidFixedDelta,
    InvalidCurveSample,
}

/// Exact additions selected by primary modes 400 through 404 on a transition.
pub const fn mode_change_increment(primary_mode: i32) -> u32 {
    match primary_mode {
        400 | 402 | 404 => 50,
        403 => 20,
        401 => 0,
        _ => 0,
    }
}

/// Commands issued by `ApplyingBodyTilt`'s begin/end vtable methods.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ApplyingBodyTiltCommand {
    SetEnabled(bool),
}

pub const fn applying_body_tilt_begin() -> ApplyingBodyTiltCommand {
    ApplyingBodyTiltCommand::SetEnabled(true)
}

pub const fn applying_body_tilt_end() -> ApplyingBodyTiltCommand {
    ApplyingBodyTiltCommand::SetEnabled(false)
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BodyTiltState {
    /// Retail state-data field `+8`.
    pub value: f32,
    /// Retail state-data field `+12`.
    pub first_difference: f32,
    /// Retail state-data field `+16`.
    pub was_application_enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BodyTiltClampPair {
    /// First symmetric clamp in the recovered update.
    pub target_error_limit: f32,
    /// Second symmetric clamp in the recovered update.
    pub first_difference_change_limit: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyTiltClampClass {
    RawPhysicsState2,
    AnyOtherRawPhysicsState,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ResolvedBodyTiltFrame {
    pub application_enabled: bool,
    /// Scalar read from the board-physics transform result.
    pub board_tilt_scalar: f32,
    /// TU3 preserves the scalar for one orientation and flips its sign for the
    /// other. The gameplay meaning of the predicate remains unresolved.
    pub preserve_orientation_sign: bool,
    /// Resolved sample of the retail point graph evaluated at the absolute
    /// physics scalar read from field `+204`.
    pub speed_curve_sample: f32,
    pub clamp_class: BodyTiltClampClass,
    /// Resolved per-update limits selected from retail attribute offsets
    /// `1888/1892` or `1896/1900`.
    pub clamps: BodyTiltClampPair,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnresolvedBodyTiltInput {
    BoardTiltTransformScalar,
    OrientationSignPredicate,
    SpeedPointGraphSample,
    RawState2ClampPair,
    OtherStateClampPair,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum BodyTiltFrameEvidence {
    Resolved(ResolvedBodyTiltFrame),
    Unresolved(UnresolvedBodyTiltInput),
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BodyTiltOutput {
    pub value: f32,
    pub first_difference: f32,
    pub target: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BodyTiltStepError {
    Unresolved(UnresolvedBodyTiltInput),
    NonFiniteResolvedInput,
    NegativeClamp,
}

impl BodyTiltState {
    /// Ports `SettingBodyTilt`'s update at `0x82BA88A0`.
    ///
    /// This conditioner is discrete per behavior update. No `dt` multiplier is
    /// added because none exists in the recovered instruction sequence.
    pub fn step(
        &mut self,
        evidence: BodyTiltFrameEvidence,
    ) -> Result<Option<BodyTiltOutput>, BodyTiltStepError> {
        let frame = match evidence {
            BodyTiltFrameEvidence::Resolved(frame) => frame,
            BodyTiltFrameEvidence::Unresolved(field) => {
                return Err(BodyTiltStepError::Unresolved(field));
            }
        };

        if !frame.board_tilt_scalar.is_finite()
            || !frame.speed_curve_sample.is_finite()
            || !frame.clamps.target_error_limit.is_finite()
            || !frame.clamps.first_difference_change_limit.is_finite()
        {
            return Err(BodyTiltStepError::NonFiniteResolvedInput);
        }
        if frame.clamps.target_error_limit < 0.0 || frame.clamps.first_difference_change_limit < 0.0
        {
            return Err(BodyTiltStepError::NegativeClamp);
        }

        if !self.was_application_enabled && frame.application_enabled {
            self.value = 0.0;
            self.first_difference = 0.0;
        }
        self.was_application_enabled = frame.application_enabled;

        if !frame.application_enabled {
            return Ok(None);
        }

        let signed_board_tilt = if frame.preserve_orientation_sign {
            frame.board_tilt_scalar
        } else {
            -frame.board_tilt_scalar
        };
        let target = frame.speed_curve_sample * signed_board_tilt;

        let target_error = (target - self.value).clamp(
            -frame.clamps.target_error_limit,
            frame.clamps.target_error_limit,
        );
        let first_difference_change = (target_error - self.first_difference).clamp(
            -frame.clamps.first_difference_change_limit,
            frame.clamps.first_difference_change_limit,
        );
        self.first_difference += first_difference_change;
        self.value += self.first_difference;

        Ok(Some(BodyTiltOutput {
            value: self.value,
            first_difference: self.first_difference,
            target,
        }))
    }
}

const _: () = {
    assert!(size_of::<RetailVec4>() == 16);
    assert!(size_of::<SkateboardForce>() == 48);
    assert!(align_of::<SkateboardForce>() == 16);
};

#[cfg(test)]
mod tests {
    use super::*;

    fn force(index: u32) -> SkateboardForce {
        SkateboardForce::new(
            SkateboardForceType(index),
            RetailVec4::new(index as f32, 1.0, 2.0, 3.0),
            RetailVec4::new(4.0, 5.0, 6.0, 7.0),
        )
    }

    #[test]
    fn force_record_matches_observed_48_byte_layout() {
        assert_eq!(size_of::<SkateboardForce>(), 48);
        assert_eq!(align_of::<SkateboardForce>(), 16);
    }

    #[test]
    fn force_queue_accepts_21_then_drops_without_mutating() {
        let mut queue = SkateboardForceQueue::default();
        for index in 0..MAX_QUEUED_SKATEBOARD_FORCES as u32 {
            assert!(queue.add(force(index)));
        }
        assert!(!queue.add(force(99)));
        assert_eq!(queue.len(), 21);
        assert_eq!(
            queue
                .iter()
                .map(|entry| entry.force_type.0)
                .collect::<Vec<_>>(),
            (0..21).collect::<Vec<_>>()
        );
    }

    #[test]
    fn post_physics_variant_2_has_first_priority() {
        let plan = plan_post_physics(PostPhysicsBranchInput {
            precheck_flag: 7,
            select_variant_2: true,
            first_component_1_positive: true,
            queued_component_1_negative: true,
            variant_1_latched: false,
        });
        assert_eq!(plan.result, PostPhysicsResultCode::Variant2);
        assert_eq!(
            plan.heading_adjustment,
            Some(HeadingAdjustmentSource::PhysicsBlockOffset64)
        );
        assert!(plan.set_flag_289);
        assert!(!plan.submit_force_queue_to_solver);
        assert_eq!(plan.write_precheck_flag, 7);
    }

    #[test]
    fn post_physics_variant_1_requires_all_three_gate_terms() {
        let eligible = PostPhysicsBranchInput {
            first_component_1_positive: true,
            queued_component_1_negative: true,
            variant_1_latched: false,
            ..PostPhysicsBranchInput::default()
        };
        let plan = plan_post_physics(eligible);
        assert_eq!(plan.result, PostPhysicsResultCode::Variant1);
        assert_eq!(
            plan.heading_adjustment,
            Some(HeadingAdjustmentSource::PhysicsBlockOffset128)
        );
        assert!(plan.clear_body_channel_0);

        for ineligible in [
            PostPhysicsBranchInput {
                first_component_1_positive: false,
                ..eligible
            },
            PostPhysicsBranchInput {
                queued_component_1_negative: false,
                ..eligible
            },
            PostPhysicsBranchInput {
                variant_1_latched: true,
                ..eligible
            },
        ] {
            assert_eq!(
                plan_post_physics(ineligible).result,
                PostPhysicsResultCode::Variant0
            );
        }
    }

    #[test]
    fn every_post_physics_result_clears_the_queue() {
        for result_input in [
            PostPhysicsBranchInput::default(),
            PostPhysicsBranchInput {
                first_component_1_positive: true,
                queued_component_1_negative: true,
                ..PostPhysicsBranchInput::default()
            },
            PostPhysicsBranchInput {
                select_variant_2: true,
                ..PostPhysicsBranchInput::default()
            },
        ] {
            let mut queue = SkateboardForceQueue::default();
            assert!(queue.add(force(1)));
            let plan = plan_post_physics(result_input);
            let completion = complete_force_queue(&mut queue, plan);
            assert!(queue.is_empty());
            if plan.result == PostPhysicsResultCode::Variant0 {
                assert_eq!(completion.submitted_to_solver, 1);
            } else {
                assert_eq!(completion.discarded_without_solver, 1);
            }
        }
    }

    #[test]
    fn heading_mode_transition_additions_match_recovered_switch() {
        assert_eq!(mode_change_increment(400), 50);
        assert_eq!(mode_change_increment(401), 0);
        assert_eq!(mode_change_increment(402), 50);
        assert_eq!(mode_change_increment(403), 20);
        assert_eq!(mode_change_increment(404), 50);
        assert_eq!(mode_change_increment(405), 0);
    }

    #[test]
    fn heading_counter_adds_on_change_then_decays_and_sets_threshold_flag() {
        let mut state = HeadingAdjustFactorState::from_retail_snapshot(399, 102, 0.0);
        state
            .step(HeadingAdjustFactorInput {
                primary_mode: 400,
                secondary_mode: 0,
                fixed_delta_seconds: 1.0 / 60.0,
            })
            .unwrap();
        assert_eq!(state.mode_change_counter, 151);
        assert!(state.counter_at_or_below_151);

        state
            .step(HeadingAdjustFactorInput {
                primary_mode: 400,
                secondary_mode: 0,
                fixed_delta_seconds: 1.0 / 60.0,
            })
            .unwrap();
        assert_eq!(state.mode_change_counter, 150);
    }

    #[test]
    fn heading_curve_clock_accumulates_only_in_observed_modes() {
        let mut state = HeadingAdjustFactorState::from_retail_snapshot(0, 0, 2.0);
        let request = state
            .step(HeadingAdjustFactorInput {
                primary_mode: 0,
                secondary_mode: 400,
                fixed_delta_seconds: 0.25,
            })
            .unwrap();
        assert_eq!(request.abscissa_seconds, 2.25);

        let request = state
            .step(HeadingAdjustFactorInput {
                primary_mode: 701,
                secondary_mode: 0,
                fixed_delta_seconds: 0.25,
            })
            .unwrap();
        assert_eq!(request.abscissa_seconds, 2.5);

        let request = state
            .step(HeadingAdjustFactorInput {
                primary_mode: 0,
                secondary_mode: 0,
                fixed_delta_seconds: 0.25,
            })
            .unwrap();
        assert_eq!(request.abscissa_seconds, 0.0);
    }

    #[test]
    fn body_tilt_rising_edge_resets_then_runs_two_clamps() {
        let mut state = BodyTiltState {
            value: 8.0,
            first_difference: -3.0,
            was_application_enabled: false,
        };
        let output = state
            .step(BodyTiltFrameEvidence::Resolved(ResolvedBodyTiltFrame {
                application_enabled: true,
                board_tilt_scalar: 1.0,
                preserve_orientation_sign: true,
                speed_curve_sample: 2.0,
                clamp_class: BodyTiltClampClass::AnyOtherRawPhysicsState,
                clamps: BodyTiltClampPair {
                    target_error_limit: 0.5,
                    first_difference_change_limit: 0.1,
                },
            }))
            .unwrap()
            .unwrap();
        assert_eq!(output.target, 2.0);
        assert!((output.first_difference - 0.1).abs() < 1.0e-6);
        assert!((output.value - 0.1).abs() < 1.0e-6);
    }

    #[test]
    fn body_tilt_sign_flip_and_discrete_velocity_are_preserved() {
        let mut state = BodyTiltState {
            was_application_enabled: true,
            ..BodyTiltState::default()
        };
        let frame = ResolvedBodyTiltFrame {
            application_enabled: true,
            board_tilt_scalar: 0.75,
            preserve_orientation_sign: false,
            speed_curve_sample: 2.0,
            clamp_class: BodyTiltClampClass::RawPhysicsState2,
            clamps: BodyTiltClampPair {
                target_error_limit: 0.4,
                first_difference_change_limit: 0.15,
            },
        };
        let first = state
            .step(BodyTiltFrameEvidence::Resolved(frame))
            .unwrap()
            .unwrap();
        assert_eq!(first.target, -1.5);
        assert!((first.first_difference + 0.15).abs() < 1.0e-6);
        assert!((first.value + 0.15).abs() < 1.0e-6);

        let second = state
            .step(BodyTiltFrameEvidence::Resolved(frame))
            .unwrap()
            .unwrap();
        assert!((second.first_difference + 0.30).abs() < 1.0e-6);
        assert!((second.value + 0.45).abs() < 1.0e-6);
    }

    #[test]
    fn disabled_or_unresolved_body_tilt_never_invents_an_output() {
        let mut state = BodyTiltState::default();
        let disabled = state
            .step(BodyTiltFrameEvidence::Resolved(ResolvedBodyTiltFrame {
                application_enabled: false,
                board_tilt_scalar: 1.0,
                preserve_orientation_sign: true,
                speed_curve_sample: 1.0,
                clamp_class: BodyTiltClampClass::AnyOtherRawPhysicsState,
                clamps: BodyTiltClampPair {
                    target_error_limit: 1.0,
                    first_difference_change_limit: 1.0,
                },
            }))
            .unwrap();
        assert_eq!(disabled, None);

        assert_eq!(
            state.step(BodyTiltFrameEvidence::Unresolved(
                UnresolvedBodyTiltInput::SpeedPointGraphSample
            )),
            Err(BodyTiltStepError::Unresolved(
                UnresolvedBodyTiltInput::SpeedPointGraphSample
            ))
        );
    }
}
