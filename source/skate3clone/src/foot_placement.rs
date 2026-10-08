//! Evidence-backed coordination for Skate 3 TU3 foot targets and contacts.
//!
//! This module deliberately stops at the boundary consumed by the existing
//! Bevy leg solver. It selects authored compact-animation targets or externally
//! observed ground targets, preserves observed IK weights, and tracks contact
//! ownership. Bone lookup, ray casts, sole offsets, contact-marker extraction,
//! and the final two-bone solve remain caller-owned.
//!
//! Retail facts represented here:
//! - compact OnBoard hierarchy channel 33 is the left reparented toe target;
//! - compact OnBoard hierarchy channel 32 is the right reparented toe target;
//! - `SkeletonIK::BlendTransforms` iterates four parts in left foot, right
//!   foot, left hand, right hand order;
//! - the runtime carries a primary weight, a transition weight, and a raw
//!   four-state mode per part;
//! - idle, carving, and push clips author both toe targets;
//! - push uses Start, Contact, Cycle, and End graph phases;
//! - OffBoard locomotion owns a BipedCadence controller, but no retail
//!   foot-contact event times have yet been recovered.
//!
//! No contact time is inferred from animation height or normalized phase.
//! `ExternalContactEvent` is therefore mandatory for push-foot and offboard
//! contact changes.
#![allow(dead_code)] // Standalone Wave 4 module; central Bevy wiring is separate.

use std::fmt;

/// The two feet in retail SkeletonIK part order.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum Foot {
    Left,
    Right,
}

impl Foot {
    pub const ALL: [Self; 2] = [Self::Left, Self::Right];

    pub const fn opposite(self) -> Self {
        match self {
            Self::Left => Self::Right,
            Self::Right => Self::Left,
        }
    }
}

/// A value indexed without relying on a numeric left/right convention.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FootPair<T> {
    pub left: T,
    pub right: T,
}

impl<T> FootPair<T> {
    pub const fn new(left: T, right: T) -> Self {
        Self { left, right }
    }

    pub const fn get(&self, foot: Foot) -> &T {
        match foot {
            Foot::Left => &self.left,
            Foot::Right => &self.right,
        }
    }

    pub fn get_mut(&mut self, foot: Foot) -> &mut T {
        match foot {
            Foot::Left => &mut self.left,
            Foot::Right => &mut self.right,
        }
    }

    pub fn map<U>(self, mut map: impl FnMut(Foot, T) -> U) -> FootPair<U> {
        FootPair {
            left: map(Foot::Left, self.left),
            right: map(Foot::Right, self.right),
        }
    }
}

impl<T: Default> Default for FootPair<T> {
    fn default() -> Self {
        Self {
            left: T::default(),
            right: T::default(),
        }
    }
}

/// Compact OnBoard hierarchy indices recovered from the retail ABIN.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum CompactToeTarget {
    LeftReparented,
    RightReparented,
}

impl CompactToeTarget {
    pub const fn hierarchy_index(self) -> u16 {
        match self {
            Self::LeftReparented => 33,
            Self::RightReparented => 32,
        }
    }

    pub const fn skeleton_ik_part(self) -> u8 {
        match self {
            Self::LeftReparented => 0,
            Self::RightReparented => 1,
        }
    }

    pub const fn foot(self) -> Foot {
        match self {
            Self::LeftReparented => Foot::Left,
            Self::RightReparented => Foot::Right,
        }
    }

    pub const fn for_foot(foot: Foot) -> Self {
        match foot {
            Foot::Left => Self::LeftReparented,
            Foot::Right => Self::RightReparented,
        }
    }
}

/// Affine target matrix in the caller's explicitly identified coordinate
/// space. The twelve values are three rows of four scalars.
///
/// The module does not transpose, rebase, offset, or normalize this matrix.
/// That prevents a Bevy convention from being mistaken for retail's row-vector
/// runtime basis.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TargetMatrix {
    pub rows: [[f32; 4]; 3],
}

impl TargetMatrix {
    pub const IDENTITY: Self = Self {
        rows: [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
        ],
    };

    pub fn is_finite(self) -> bool {
        self.rows
            .iter()
            .flatten()
            .all(|component| component.is_finite())
    }
}

/// The coordinate-space contract for a target matrix.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum TargetSpace {
    /// Matrix decoded from a compact OnBoard animation channel.
    CompactOnboard(CompactToeTarget),
    /// World-space matrix produced by the caller's proven contact provider.
    World,
}

/// A target plus its exact source-space declaration.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FootTarget {
    pub matrix: TargetMatrix,
    pub space: TargetSpace,
}

impl FootTarget {
    pub const fn compact(target: CompactToeTarget, matrix: TargetMatrix) -> Self {
        Self {
            matrix,
            space: TargetSpace::CompactOnboard(target),
        }
    }

    pub const fn world(matrix: TargetMatrix) -> Self {
        Self {
            matrix,
            space: TargetSpace::World,
        }
    }
}

/// A normalized weight observed at the SkeletonIK boundary.
///
/// TU3's blend path compares against zero and constructs `1 - weight`.
/// Inputs outside `[0, 1]` are rejected instead of clamped.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct IkWeight(f32);

impl IkWeight {
    pub const ZERO: Self = Self(0.0);
    pub const ONE: Self = Self(1.0);

    pub fn new(value: f32) -> Result<Self, FootPlacementError> {
        if !value.is_finite() {
            return Err(FootPlacementError::NonFiniteWeight);
        }
        if !(0.0..=1.0).contains(&value) {
            return Err(FootPlacementError::WeightOutsideUnitInterval);
        }
        Ok(Self(value))
    }

    pub const fn get(self) -> f32 {
        self.0
    }
}

/// Raw retail part mode consumed by `SkeletonIK::BlendTransforms`.
///
/// The numeric states are proven. Their complete semantic names are not, so
/// the public API does not pretend that these are equivalent to this module's
/// higher-level contact ownership.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum RawSkeletonIkMode {
    State0,
    State1,
    State2,
    State3,
}

impl RawSkeletonIkMode {
    pub const fn from_raw(raw: u32) -> Option<Self> {
        match raw {
            0 => Some(Self::State0),
            1 => Some(Self::State1),
            2 => Some(Self::State2),
            3 => Some(Self::State3),
            _ => None,
        }
    }

    pub const fn raw(self) -> u32 {
        match self {
            Self::State0 => 0,
            Self::State1 => 1,
            Self::State2 => 2,
            Self::State3 => 3,
        }
    }
}

/// Optional raw values captured from the retail SkeletonIK object.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ObservedSkeletonIkPart {
    pub primary_weight: IkWeight,
    pub transition_weight: IkWeight,
    pub mode: RawSkeletonIkMode,
}

/// Authored compact-channel target sampled for one rendered/fixed frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CompactTargetSample {
    pub target: FootTarget,
    pub observed_ik: ObservedSkeletonIkPart,
}

impl CompactTargetSample {
    pub fn new(foot: Foot, matrix: TargetMatrix, observed_ik: ObservedSkeletonIkPart) -> Self {
        Self {
            target: FootTarget::compact(CompactToeTarget::for_foot(foot), matrix),
            observed_ik,
        }
    }
}

/// Motion-graph context relevant to target ownership.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum PlacementContext {
    Onboard(OnboardMotion),
    Push {
        push_foot: Foot,
        phase: PushGraphPhase,
    },
    Offboard(OffboardMotion),
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum OnboardMotion {
    Idle,
    Carving,
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum PushGraphPhase {
    Start,
    Contact,
    Cycle,
    End,
}

/// The graph uses a `WillExpire` window of 0.01 seconds between the push
/// sequence leaves. This is not a foot-contact marker.
pub const PUSH_SEQUENCE_WILL_EXPIRE_SECONDS: f32 = 0.01;

/// PushEnd transitions to Idle with a `WillExpire` window of 0.1 seconds.
/// This is not used as a replant threshold.
pub const PUSH_END_WILL_EXPIRE_SECONDS: f32 = 0.1;

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum OffboardMotion {
    Stand,
    Walk,
    Run,
    Sprint,
}

/// Stable surface identity supplied by the raycast/contact implementation.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct SurfaceIdentity {
    pub surface: u32,
    pub primitive: u32,
}

/// Opaque monotonically increasing identity for an externally recovered clip
/// event. It intentionally does not assign a normalized-time threshold.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct ClipEventSequence(pub u64);

/// Contact marker metadata supplied by telemetry or an exact asset-event
/// extractor.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub struct ClipEventMarker {
    pub sequence: ClipEventSequence,
    pub animation_revision: u64,
    pub sample_index: u32,
    pub external_marker_id: u32,
}

/// Target and surface data emitted by the external ground-contact path.
///
/// `target` must already include the proven raycast result, foot orientation,
/// and sole offset. This module does not manufacture any of those values.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceTargetSample {
    pub target: FootTarget,
    pub surface: SurfaceIdentity,
    pub primary_weight: IkWeight,
    pub transition_weight: IkWeight,
    pub raw_mode: RawSkeletonIkMode,
}

/// Externally proven contact changes.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ExternalContactEvent {
    /// The foot no longer owns a board or ground contact.
    Release {
        marker: ClipEventMarker,
        primary_weight: IkWeight,
        transition_weight: IkWeight,
        raw_mode: RawSkeletonIkMode,
    },
    /// Acquire a raycast/contact-provider target.
    AcquireSurface {
        marker: ClipEventMarker,
        sample: SurfaceTargetSample,
    },
    /// Refresh an already acquired surface target.
    MaintainSurface {
        marker: ClipEventMarker,
        sample: SurfaceTargetSample,
    },
    /// Return the push foot to its authored compact board target.
    ReplantBoard {
        marker: ClipEventMarker,
        observed_ik: ObservedSkeletonIkPart,
    },
}

impl ExternalContactEvent {
    pub const fn marker(self) -> ClipEventMarker {
        match self {
            Self::Release { marker, .. }
            | Self::AcquireSurface { marker, .. }
            | Self::MaintainSurface { marker, .. }
            | Self::ReplantBoard { marker, .. } => marker,
        }
    }
}

/// High-level ownership of the current foot contact.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContactOwnership {
    /// Awaiting an exact external marker; no contact conclusion is asserted.
    Unresolved,
    Released,
    Board,
    Surface(SurfaceIdentity),
}

/// Complete command for one foot after coordination.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FootPlacementState {
    pub target: Option<FootTarget>,
    pub primary_weight: IkWeight,
    pub transition_weight: IkWeight,
    pub raw_mode: Option<RawSkeletonIkMode>,
    pub contact: ContactOwnership,
    pub last_marker: Option<ClipEventMarker>,
}

impl FootPlacementState {
    pub const fn unresolved() -> Self {
        Self {
            target: None,
            primary_weight: IkWeight::ZERO,
            transition_weight: IkWeight::ZERO,
            raw_mode: None,
            contact: ContactOwnership::Unresolved,
            last_marker: None,
        }
    }

    fn board(sample: CompactTargetSample, last_marker: Option<ClipEventMarker>) -> Self {
        Self {
            target: Some(sample.target),
            primary_weight: sample.observed_ik.primary_weight,
            transition_weight: sample.observed_ik.transition_weight,
            raw_mode: Some(sample.observed_ik.mode),
            contact: ContactOwnership::Board,
            last_marker,
        }
    }
}

impl Default for FootPlacementState {
    fn default() -> Self {
        Self::unresolved()
    }
}

/// Inputs for one deterministic coordination update.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FootPlacementFrame {
    pub tick: u64,
    pub context: PlacementContext,
    /// Required for Onboard and Push. Ignored for Offboard.
    pub compact_targets: FootPair<Option<CompactTargetSample>>,
    /// Only the active push foot may receive a push event.
    pub push_event: Option<ExternalContactEvent>,
    /// Offboard contact changes are supplied independently per foot.
    pub offboard_events: FootPair<Option<ExternalContactEvent>>,
}

impl FootPlacementFrame {
    pub const fn onboard(
        tick: u64,
        motion: OnboardMotion,
        compact_targets: FootPair<Option<CompactTargetSample>>,
    ) -> Self {
        Self {
            tick,
            context: PlacementContext::Onboard(motion),
            compact_targets,
            push_event: None,
            offboard_events: FootPair::new(None, None),
        }
    }
}

/// Evidence that remains required after a successful update.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UnresolvedFootInput {
    PushContactMarker { foot: Foot },
    PushReplantMarker { foot: Foot },
    OffboardContactMarker { foot: Foot },
}

#[derive(Clone, Debug, PartialEq)]
pub struct FootPlacementOutput {
    pub tick: u64,
    pub context: PlacementContext,
    pub feet: FootPair<FootPlacementState>,
    pub unresolved: Vec<UnresolvedFootInput>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FootPlacementCoordinator {
    last_tick: Option<u64>,
    context: Option<PlacementContext>,
    feet: FootPair<FootPlacementState>,
}

impl FootPlacementCoordinator {
    pub const fn new() -> Self {
        Self {
            last_tick: None,
            context: None,
            feet: FootPair {
                left: FootPlacementState::unresolved(),
                right: FootPlacementState::unresolved(),
            },
        }
    }

    pub const fn states(&self) -> &FootPair<FootPlacementState> {
        &self.feet
    }

    /// Apply one frame atomically.
    ///
    /// Validation runs against a copy. A rejected marker, target, or context
    /// leaves the coordinator unchanged.
    pub fn step(
        &mut self,
        frame: FootPlacementFrame,
    ) -> Result<FootPlacementOutput, FootPlacementError> {
        let mut next = self.clone();
        let output = next.step_inner(frame)?;
        *self = next;
        Ok(output)
    }

    fn step_inner(
        &mut self,
        frame: FootPlacementFrame,
    ) -> Result<FootPlacementOutput, FootPlacementError> {
        if self.last_tick.is_some_and(|last| frame.tick <= last) {
            return Err(FootPlacementError::NonIncreasingTick);
        }

        validate_context_events(frame)?;
        validate_compact_targets(frame.context, frame.compact_targets)?;

        let ownership_changed =
            self.context.map(ownership_domain) != Some(ownership_domain(frame.context));
        if ownership_changed {
            self.enter_context(frame.context, frame.compact_targets)?;
        }

        let mut unresolved = Vec::new();
        match frame.context {
            PlacementContext::Onboard(_) => {
                for foot in Foot::ALL {
                    let sample = required_compact(frame.compact_targets, foot)?;
                    let last_marker = self.feet.get(foot).last_marker;
                    *self.feet.get_mut(foot) = FootPlacementState::board(sample, last_marker);
                }
            }
            PlacementContext::Push { push_foot, phase } => {
                let support_foot = push_foot.opposite();
                let support = required_compact(frame.compact_targets, support_foot)?;
                let support_last_marker = self.feet.get(support_foot).last_marker;
                *self.feet.get_mut(support_foot) =
                    FootPlacementState::board(support, support_last_marker);

                // The push clip authors this target every frame. Contact
                // ownership is still driven only by an external marker.
                let push_sample = required_compact(frame.compact_targets, push_foot)?;
                if !matches!(
                    self.feet.get(push_foot).contact,
                    ContactOwnership::Surface(_)
                ) {
                    self.feet.get_mut(push_foot).target = Some(push_sample.target);
                }

                if let Some(event) = frame.push_event {
                    self.apply_event(push_foot, event, Some(push_sample), EventDomain::Push)?;
                }

                let push_contact = self.feet.get(push_foot).contact;
                if matches!(push_contact, ContactOwnership::Unresolved) {
                    unresolved.push(UnresolvedFootInput::PushContactMarker { foot: push_foot });
                }
                if phase == PushGraphPhase::End && push_contact != ContactOwnership::Board {
                    unresolved.push(UnresolvedFootInput::PushReplantMarker { foot: push_foot });
                }
            }
            PlacementContext::Offboard(_) => {
                for foot in Foot::ALL {
                    if let Some(event) = *frame.offboard_events.get(foot) {
                        self.apply_event(foot, event, None, EventDomain::Offboard)?;
                    }
                    if matches!(self.feet.get(foot).contact, ContactOwnership::Unresolved) {
                        unresolved.push(UnresolvedFootInput::OffboardContactMarker { foot });
                    }
                }
            }
        }

        self.last_tick = Some(frame.tick);
        self.context = Some(frame.context);
        Ok(FootPlacementOutput {
            tick: frame.tick,
            context: frame.context,
            feet: self.feet,
            unresolved,
        })
    }

    fn enter_context(
        &mut self,
        context: PlacementContext,
        compact_targets: FootPair<Option<CompactTargetSample>>,
    ) -> Result<(), FootPlacementError> {
        match context {
            PlacementContext::Onboard(_) => {
                for foot in Foot::ALL {
                    let sample = required_compact(compact_targets, foot)?;
                    let last_marker = self.feet.get(foot).last_marker;
                    *self.feet.get_mut(foot) = FootPlacementState::board(sample, last_marker);
                }
            }
            PlacementContext::Push { push_foot, .. } => {
                let support_foot = push_foot.opposite();
                let support = required_compact(compact_targets, support_foot)?;
                let support_last_marker = self.feet.get(support_foot).last_marker;
                *self.feet.get_mut(support_foot) =
                    FootPlacementState::board(support, support_last_marker);

                let push = required_compact(compact_targets, push_foot)?;
                let last_marker = self.feet.get(push_foot).last_marker;
                *self.feet.get_mut(push_foot) = FootPlacementState {
                    target: Some(push.target),
                    primary_weight: push.observed_ik.primary_weight,
                    transition_weight: push.observed_ik.transition_weight,
                    raw_mode: Some(push.observed_ik.mode),
                    contact: ContactOwnership::Unresolved,
                    last_marker,
                };
            }
            PlacementContext::Offboard(_) => {
                for foot in Foot::ALL {
                    let last_marker = self.feet.get(foot).last_marker;
                    *self.feet.get_mut(foot) = FootPlacementState {
                        last_marker,
                        ..FootPlacementState::unresolved()
                    };
                }
            }
        }
        Ok(())
    }

    fn apply_event(
        &mut self,
        foot: Foot,
        event: ExternalContactEvent,
        compact_target: Option<CompactTargetSample>,
        domain: EventDomain,
    ) -> Result<(), FootPlacementError> {
        validate_marker_order(self.feet.get(foot).last_marker, event.marker())?;

        let current = *self.feet.get(foot);
        let next = match event {
            ExternalContactEvent::Release {
                marker,
                primary_weight,
                transition_weight,
                raw_mode,
            } => {
                let target = match domain {
                    EventDomain::Push => compact_target.map(|sample| sample.target),
                    EventDomain::Offboard => None,
                };
                FootPlacementState {
                    target,
                    primary_weight,
                    transition_weight,
                    raw_mode: Some(raw_mode),
                    contact: ContactOwnership::Released,
                    last_marker: Some(marker),
                }
            }
            ExternalContactEvent::AcquireSurface { marker, sample } => {
                validate_surface_sample(sample)?;
                if matches!(current.contact, ContactOwnership::Surface(_)) {
                    return Err(FootPlacementError::SurfaceAlreadyAcquired { foot });
                }
                FootPlacementState {
                    target: Some(sample.target),
                    primary_weight: sample.primary_weight,
                    transition_weight: sample.transition_weight,
                    raw_mode: Some(sample.raw_mode),
                    contact: ContactOwnership::Surface(sample.surface),
                    last_marker: Some(marker),
                }
            }
            ExternalContactEvent::MaintainSurface { marker, sample } => {
                validate_surface_sample(sample)?;
                let ContactOwnership::Surface(current_surface) = current.contact else {
                    return Err(FootPlacementError::SurfaceNotAcquired { foot });
                };
                if current_surface != sample.surface {
                    return Err(FootPlacementError::SurfaceIdentityChangedWithoutAcquire { foot });
                }
                FootPlacementState {
                    target: Some(sample.target),
                    primary_weight: sample.primary_weight,
                    transition_weight: sample.transition_weight,
                    raw_mode: Some(sample.raw_mode),
                    contact: ContactOwnership::Surface(sample.surface),
                    last_marker: Some(marker),
                }
            }
            ExternalContactEvent::ReplantBoard {
                marker,
                observed_ik,
            } => {
                if domain != EventDomain::Push {
                    return Err(FootPlacementError::BoardReplantOutsidePush { foot });
                }
                let sample =
                    compact_target.ok_or(FootPlacementError::MissingCompactTarget { foot })?;
                FootPlacementState::board(sample_with_ik(sample, observed_ik), Some(marker))
            }
        };

        *self.feet.get_mut(foot) = next;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EventDomain {
    Push,
    Offboard,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum OwnershipDomain {
    Onboard,
    Push(Foot),
    Offboard,
}

const fn ownership_domain(context: PlacementContext) -> OwnershipDomain {
    match context {
        PlacementContext::Onboard(_) => OwnershipDomain::Onboard,
        PlacementContext::Push { push_foot, .. } => OwnershipDomain::Push(push_foot),
        PlacementContext::Offboard(_) => OwnershipDomain::Offboard,
    }
}

fn sample_with_ik(
    mut sample: CompactTargetSample,
    observed_ik: ObservedSkeletonIkPart,
) -> CompactTargetSample {
    sample.observed_ik = observed_ik;
    sample
}

fn validate_context_events(frame: FootPlacementFrame) -> Result<(), FootPlacementError> {
    match frame.context {
        PlacementContext::Onboard(_) => {
            if frame.push_event.is_some()
                || frame.offboard_events.left.is_some()
                || frame.offboard_events.right.is_some()
            {
                return Err(FootPlacementError::ContactEventOutsideOwnedContext);
            }
        }
        PlacementContext::Push { .. } => {
            if frame.offboard_events.left.is_some() || frame.offboard_events.right.is_some() {
                return Err(FootPlacementError::ContactEventOutsideOwnedContext);
            }
        }
        PlacementContext::Offboard(_) => {
            if frame.push_event.is_some() {
                return Err(FootPlacementError::ContactEventOutsideOwnedContext);
            }
            for foot in Foot::ALL {
                if matches!(
                    *frame.offboard_events.get(foot),
                    Some(ExternalContactEvent::ReplantBoard { .. })
                ) {
                    return Err(FootPlacementError::BoardReplantOutsidePush { foot });
                }
            }
        }
    }
    Ok(())
}

fn validate_compact_targets(
    context: PlacementContext,
    targets: FootPair<Option<CompactTargetSample>>,
) -> Result<(), FootPlacementError> {
    if matches!(context, PlacementContext::Offboard(_)) {
        return Ok(());
    }
    for foot in Foot::ALL {
        let sample = required_compact(targets, foot)?;
        if !sample.target.matrix.is_finite() {
            return Err(FootPlacementError::NonFiniteTarget { foot });
        }
        let expected = TargetSpace::CompactOnboard(CompactToeTarget::for_foot(foot));
        if sample.target.space != expected {
            return Err(FootPlacementError::CompactTargetChannelMismatch { foot });
        }
    }
    Ok(())
}

fn required_compact(
    targets: FootPair<Option<CompactTargetSample>>,
    foot: Foot,
) -> Result<CompactTargetSample, FootPlacementError> {
    (*targets.get(foot)).ok_or(FootPlacementError::MissingCompactTarget { foot })
}

fn validate_surface_sample(sample: SurfaceTargetSample) -> Result<(), FootPlacementError> {
    if sample.target.space != TargetSpace::World {
        return Err(FootPlacementError::SurfaceTargetNotWorldSpace);
    }
    if !sample.target.matrix.is_finite() {
        return Err(FootPlacementError::NonFiniteSurfaceTarget);
    }
    Ok(())
}

fn validate_marker_order(
    previous: Option<ClipEventMarker>,
    next: ClipEventMarker,
) -> Result<(), FootPlacementError> {
    if previous.is_some_and(|previous| next.sequence <= previous.sequence) {
        return Err(FootPlacementError::NonIncreasingMarkerSequence);
    }
    Ok(())
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum FootPlacementError {
    NonIncreasingTick,
    MissingCompactTarget { foot: Foot },
    CompactTargetChannelMismatch { foot: Foot },
    NonFiniteTarget { foot: Foot },
    NonFiniteWeight,
    WeightOutsideUnitInterval,
    ContactEventOutsideOwnedContext,
    NonIncreasingMarkerSequence,
    SurfaceTargetNotWorldSpace,
    NonFiniteSurfaceTarget,
    SurfaceAlreadyAcquired { foot: Foot },
    SurfaceNotAcquired { foot: Foot },
    SurfaceIdentityChangedWithoutAcquire { foot: Foot },
    BoardReplantOutsidePush { foot: Foot },
}

impl fmt::Display for FootPlacementError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            Self::NonIncreasingTick => formatter.write_str("tick did not increase"),
            Self::MissingCompactTarget { foot } => {
                write!(formatter, "missing compact target for {foot:?}")
            }
            Self::CompactTargetChannelMismatch { foot } => {
                write!(formatter, "compact target channel does not match {foot:?}")
            }
            Self::NonFiniteTarget { foot } => {
                write!(formatter, "target for {foot:?} contains a non-finite value")
            }
            Self::NonFiniteWeight => formatter.write_str("IK weight is not finite"),
            Self::WeightOutsideUnitInterval => formatter.write_str("IK weight is outside [0, 1]"),
            Self::ContactEventOutsideOwnedContext => {
                formatter.write_str("contact event does not belong to this graph context")
            }
            Self::NonIncreasingMarkerSequence => {
                formatter.write_str("clip-event marker sequence did not increase")
            }
            Self::SurfaceTargetNotWorldSpace => {
                formatter.write_str("surface target is not declared in world space")
            }
            Self::NonFiniteSurfaceTarget => {
                formatter.write_str("surface target contains a non-finite value")
            }
            Self::SurfaceAlreadyAcquired { foot } => {
                write!(formatter, "{foot:?} already owns a surface contact")
            }
            Self::SurfaceNotAcquired { foot } => {
                write!(formatter, "{foot:?} has no surface contact to maintain")
            }
            Self::SurfaceIdentityChangedWithoutAcquire { foot } => {
                write!(
                    formatter,
                    "{foot:?} surface identity changed without an acquire event"
                )
            }
            Self::BoardReplantOutsidePush { foot } => {
                write!(formatter, "{foot:?} board replant occurred outside Push")
            }
        }
    }
}

impl std::error::Error for FootPlacementError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn weight(value: f32) -> IkWeight {
        IkWeight::new(value).unwrap()
    }

    fn matrix(seed: f32) -> TargetMatrix {
        TargetMatrix {
            rows: [
                [1.0, 0.0, 0.0, seed],
                [0.0, 1.0, 0.0, seed + 1.0],
                [0.0, 0.0, 1.0, seed + 2.0],
            ],
        }
    }

    fn observed(primary: f32, transition: f32, mode: RawSkeletonIkMode) -> ObservedSkeletonIkPart {
        ObservedSkeletonIkPart {
            primary_weight: weight(primary),
            transition_weight: weight(transition),
            mode,
        }
    }

    fn compact_pair(seed: f32) -> FootPair<Option<CompactTargetSample>> {
        FootPair::new(
            Some(CompactTargetSample::new(
                Foot::Left,
                matrix(seed),
                observed(1.0, 0.0, RawSkeletonIkMode::State1),
            )),
            Some(CompactTargetSample::new(
                Foot::Right,
                matrix(seed + 10.0),
                observed(1.0, 0.0, RawSkeletonIkMode::State1),
            )),
        )
    }

    fn marker(sequence: u64) -> ClipEventMarker {
        ClipEventMarker {
            sequence: ClipEventSequence(sequence),
            animation_revision: 7,
            sample_index: sequence as u32,
            external_marker_id: 0xA000 + sequence as u32,
        }
    }

    fn surface_sample(seed: f32, surface: SurfaceIdentity) -> SurfaceTargetSample {
        SurfaceTargetSample {
            target: FootTarget::world(matrix(seed)),
            surface,
            primary_weight: weight(0.75),
            transition_weight: weight(0.25),
            raw_mode: RawSkeletonIkMode::State3,
        }
    }

    fn push_frame(
        tick: u64,
        push_foot: Foot,
        phase: PushGraphPhase,
        targets: FootPair<Option<CompactTargetSample>>,
        event: Option<ExternalContactEvent>,
    ) -> FootPlacementFrame {
        FootPlacementFrame {
            tick,
            context: PlacementContext::Push { push_foot, phase },
            compact_targets: targets,
            push_event: event,
            offboard_events: FootPair::new(None, None),
        }
    }

    fn offboard_frame(
        tick: u64,
        motion: OffboardMotion,
        events: FootPair<Option<ExternalContactEvent>>,
    ) -> FootPlacementFrame {
        FootPlacementFrame {
            tick,
            context: PlacementContext::Offboard(motion),
            compact_targets: FootPair::new(None, None),
            push_event: None,
            offboard_events: events,
        }
    }

    #[test]
    fn compact_channels_and_skeleton_parts_keep_retail_order() {
        assert_eq!(CompactToeTarget::LeftReparented.hierarchy_index(), 33);
        assert_eq!(CompactToeTarget::RightReparented.hierarchy_index(), 32);
        assert_eq!(CompactToeTarget::LeftReparented.skeleton_ik_part(), 0);
        assert_eq!(CompactToeTarget::RightReparented.skeleton_ik_part(), 1);
        assert_eq!(CompactToeTarget::for_foot(Foot::Left).foot(), Foot::Left);
        assert_eq!(CompactToeTarget::for_foot(Foot::Right).foot(), Foot::Right);
    }

    #[test]
    fn idle_uses_both_authored_targets_and_observed_weights() {
        let targets = compact_pair(2.0);
        let mut coordinator = FootPlacementCoordinator::new();
        let output = coordinator
            .step(FootPlacementFrame::onboard(1, OnboardMotion::Idle, targets))
            .unwrap();

        assert_eq!(output.unresolved, Vec::new());
        for foot in Foot::ALL {
            let state = output.feet.get(foot);
            assert_eq!(state.contact, ContactOwnership::Board);
            assert_eq!(
                state.target,
                Some(required_compact(targets, foot).unwrap().target)
            );
            assert_eq!(state.primary_weight, IkWeight::ONE);
            assert_eq!(state.transition_weight, IkWeight::ZERO);
            assert_eq!(state.raw_mode, Some(RawSkeletonIkMode::State1));
        }
    }

    #[test]
    fn carving_replaces_targets_without_procedural_offsets() {
        let mut coordinator = FootPlacementCoordinator::new();
        coordinator
            .step(FootPlacementFrame::onboard(
                1,
                OnboardMotion::Idle,
                compact_pair(0.0),
            ))
            .unwrap();

        let carved = compact_pair(50.0);
        let output = coordinator
            .step(FootPlacementFrame::onboard(
                2,
                OnboardMotion::Carving,
                carved,
            ))
            .unwrap();

        for foot in Foot::ALL {
            assert_eq!(
                output.feet.get(foot).target,
                Some(required_compact(carved, foot).unwrap().target)
            );
        }
    }

    #[test]
    fn push_never_invents_release_or_replant_timing() {
        let mut coordinator = FootPlacementCoordinator::new();
        let start = coordinator
            .step(push_frame(
                1,
                Foot::Left,
                PushGraphPhase::Start,
                compact_pair(0.0),
                None,
            ))
            .unwrap();
        assert_eq!(start.feet.right.contact, ContactOwnership::Board);
        assert_eq!(start.feet.left.contact, ContactOwnership::Unresolved);
        assert_eq!(
            start.unresolved,
            vec![UnresolvedFootInput::PushContactMarker { foot: Foot::Left }]
        );

        let end = coordinator
            .step(push_frame(
                500,
                Foot::Left,
                PushGraphPhase::End,
                compact_pair(100.0),
                None,
            ))
            .unwrap();
        assert_eq!(end.feet.left.contact, ContactOwnership::Unresolved);
        assert_eq!(
            end.unresolved,
            vec![
                UnresolvedFootInput::PushContactMarker { foot: Foot::Left },
                UnresolvedFootInput::PushReplantMarker { foot: Foot::Left },
            ]
        );
    }

    #[test]
    fn push_release_surface_and_replant_follow_external_markers() {
        let surface = SurfaceIdentity {
            surface: 12,
            primitive: 34,
        };
        let mut coordinator = FootPlacementCoordinator::new();
        coordinator
            .step(push_frame(
                1,
                Foot::Left,
                PushGraphPhase::Start,
                compact_pair(0.0),
                Some(ExternalContactEvent::Release {
                    marker: marker(1),
                    primary_weight: weight(0.0),
                    transition_weight: weight(0.4),
                    raw_mode: RawSkeletonIkMode::State2,
                }),
            ))
            .unwrap();
        assert_eq!(
            coordinator.states().left.contact,
            ContactOwnership::Released
        );

        coordinator
            .step(push_frame(
                2,
                Foot::Left,
                PushGraphPhase::Contact,
                compact_pair(1.0),
                Some(ExternalContactEvent::AcquireSurface {
                    marker: marker(2),
                    sample: surface_sample(200.0, surface),
                }),
            ))
            .unwrap();
        assert_eq!(
            coordinator.states().left.contact,
            ContactOwnership::Surface(surface)
        );
        assert_eq!(
            coordinator.states().left.target,
            Some(FootTarget::world(matrix(200.0)))
        );

        coordinator
            .step(push_frame(
                3,
                Foot::Left,
                PushGraphPhase::Cycle,
                compact_pair(2.0),
                Some(ExternalContactEvent::Release {
                    marker: marker(3),
                    primary_weight: weight(0.2),
                    transition_weight: weight(0.8),
                    raw_mode: RawSkeletonIkMode::State2,
                }),
            ))
            .unwrap();
        assert_eq!(
            coordinator.states().left.contact,
            ContactOwnership::Released
        );
        assert_eq!(
            coordinator.states().left.target,
            Some(
                required_compact(compact_pair(2.0), Foot::Left)
                    .unwrap()
                    .target
            )
        );

        let replanted = coordinator
            .step(push_frame(
                4,
                Foot::Left,
                PushGraphPhase::End,
                compact_pair(3.0),
                Some(ExternalContactEvent::ReplantBoard {
                    marker: marker(4),
                    observed_ik: observed(1.0, 0.0, RawSkeletonIkMode::State1),
                }),
            ))
            .unwrap();
        assert_eq!(replanted.feet.left.contact, ContactOwnership::Board);
        assert!(
            !replanted
                .unresolved
                .contains(&UnresolvedFootInput::PushReplantMarker { foot: Foot::Left })
        );
    }

    #[test]
    fn push_phase_changes_preserve_contact_until_an_external_event() {
        let surface = SurfaceIdentity {
            surface: 12,
            primitive: 34,
        };
        let mut coordinator = FootPlacementCoordinator::new();
        coordinator
            .step(push_frame(
                1,
                Foot::Left,
                PushGraphPhase::Contact,
                compact_pair(0.0),
                Some(ExternalContactEvent::AcquireSurface {
                    marker: marker(1),
                    sample: surface_sample(200.0, surface),
                }),
            ))
            .unwrap();

        let cycle = coordinator
            .step(push_frame(
                2,
                Foot::Left,
                PushGraphPhase::Cycle,
                compact_pair(1.0),
                None,
            ))
            .unwrap();
        assert_eq!(cycle.feet.left.contact, ContactOwnership::Surface(surface));
        assert_eq!(
            cycle.feet.left.target,
            Some(FootTarget::world(matrix(200.0)))
        );

        let end = coordinator
            .step(push_frame(
                3,
                Foot::Left,
                PushGraphPhase::End,
                compact_pair(2.0),
                None,
            ))
            .unwrap();
        assert_eq!(end.feet.left.contact, ContactOwnership::Surface(surface));
        assert_eq!(
            end.unresolved,
            vec![UnresolvedFootInput::PushReplantMarker { foot: Foot::Left }]
        );
    }

    #[test]
    fn offboard_contacts_require_external_markers_per_foot() {
        let surface = SurfaceIdentity {
            surface: 5,
            primitive: 8,
        };
        let mut coordinator = FootPlacementCoordinator::new();
        let initial = coordinator
            .step(offboard_frame(
                1,
                OffboardMotion::Run,
                FootPair::new(None, None),
            ))
            .unwrap();
        assert_eq!(
            initial.unresolved,
            vec![
                UnresolvedFootInput::OffboardContactMarker { foot: Foot::Left },
                UnresolvedFootInput::OffboardContactMarker { foot: Foot::Right },
            ]
        );

        let acquired = coordinator
            .step(offboard_frame(
                2,
                OffboardMotion::Run,
                FootPair::new(
                    Some(ExternalContactEvent::AcquireSurface {
                        marker: marker(10),
                        sample: surface_sample(10.0, surface),
                    }),
                    None,
                ),
            ))
            .unwrap();
        assert_eq!(
            acquired.feet.left.contact,
            ContactOwnership::Surface(surface)
        );
        assert_eq!(acquired.feet.right.contact, ContactOwnership::Unresolved);

        let maintained = coordinator
            .step(offboard_frame(
                3,
                OffboardMotion::Run,
                FootPair::new(
                    Some(ExternalContactEvent::MaintainSurface {
                        marker: marker(11),
                        sample: surface_sample(11.0, surface),
                    }),
                    Some(ExternalContactEvent::Release {
                        marker: marker(20),
                        primary_weight: IkWeight::ZERO,
                        transition_weight: IkWeight::ZERO,
                        raw_mode: RawSkeletonIkMode::State0,
                    }),
                ),
            ))
            .unwrap();
        assert_eq!(
            maintained.feet.left.target,
            Some(FootTarget::world(matrix(11.0)))
        );
        assert_eq!(maintained.feet.right.contact, ContactOwnership::Released);
    }

    #[test]
    fn offboard_gait_changes_do_not_discard_a_planted_foot() {
        let surface = SurfaceIdentity {
            surface: 5,
            primitive: 8,
        };
        let mut coordinator = FootPlacementCoordinator::new();
        coordinator
            .step(offboard_frame(
                1,
                OffboardMotion::Walk,
                FootPair::new(
                    Some(ExternalContactEvent::AcquireSurface {
                        marker: marker(1),
                        sample: surface_sample(10.0, surface),
                    }),
                    None,
                ),
            ))
            .unwrap();

        let run = coordinator
            .step(offboard_frame(
                2,
                OffboardMotion::Run,
                FootPair::new(None, None),
            ))
            .unwrap();
        assert_eq!(run.feet.left.contact, ContactOwnership::Surface(surface));
        assert_eq!(run.feet.left.target, Some(FootTarget::world(matrix(10.0))));
    }

    #[test]
    fn marker_order_and_surface_identity_are_strict() {
        let surface = SurfaceIdentity {
            surface: 1,
            primitive: 2,
        };
        let mut coordinator = FootPlacementCoordinator::new();
        coordinator
            .step(offboard_frame(
                1,
                OffboardMotion::Walk,
                FootPair::new(
                    Some(ExternalContactEvent::AcquireSurface {
                        marker: marker(3),
                        sample: surface_sample(0.0, surface),
                    }),
                    None,
                ),
            ))
            .unwrap();
        let before = coordinator.clone();

        let duplicate = coordinator.step(offboard_frame(
            2,
            OffboardMotion::Walk,
            FootPair::new(
                Some(ExternalContactEvent::MaintainSurface {
                    marker: marker(3),
                    sample: surface_sample(1.0, surface),
                }),
                None,
            ),
        ));
        assert_eq!(
            duplicate,
            Err(FootPlacementError::NonIncreasingMarkerSequence)
        );
        assert_eq!(coordinator, before);

        let changed = coordinator.step(offboard_frame(
            2,
            OffboardMotion::Walk,
            FootPair::new(
                Some(ExternalContactEvent::MaintainSurface {
                    marker: marker(4),
                    sample: surface_sample(
                        1.0,
                        SurfaceIdentity {
                            surface: 9,
                            primitive: 9,
                        },
                    ),
                }),
                None,
            ),
        ));
        assert_eq!(
            changed,
            Err(FootPlacementError::SurfaceIdentityChangedWithoutAcquire { foot: Foot::Left })
        );
        assert_eq!(coordinator, before);
    }

    #[test]
    fn invalid_target_weight_and_channel_are_rejected_atomically() {
        assert_eq!(
            IkWeight::new(f32::NAN),
            Err(FootPlacementError::NonFiniteWeight)
        );
        assert_eq!(
            IkWeight::new(1.0001),
            Err(FootPlacementError::WeightOutsideUnitInterval)
        );

        let mut targets = compact_pair(0.0);
        targets.left.as_mut().unwrap().target.space =
            TargetSpace::CompactOnboard(CompactToeTarget::RightReparented);
        let mut coordinator = FootPlacementCoordinator::new();
        assert_eq!(
            coordinator.step(FootPlacementFrame::onboard(1, OnboardMotion::Idle, targets)),
            Err(FootPlacementError::CompactTargetChannelMismatch { foot: Foot::Left })
        );
        assert_eq!(coordinator, FootPlacementCoordinator::new());
    }

    #[test]
    fn switching_push_foot_rebuilds_support_and_external_roles() {
        let mut coordinator = FootPlacementCoordinator::new();
        coordinator
            .step(push_frame(
                1,
                Foot::Left,
                PushGraphPhase::Start,
                compact_pair(0.0),
                Some(ExternalContactEvent::Release {
                    marker: marker(1),
                    primary_weight: IkWeight::ZERO,
                    transition_weight: IkWeight::ZERO,
                    raw_mode: RawSkeletonIkMode::State0,
                }),
            ))
            .unwrap();

        let switched = coordinator
            .step(push_frame(
                2,
                Foot::Right,
                PushGraphPhase::Start,
                compact_pair(20.0),
                None,
            ))
            .unwrap();
        assert_eq!(switched.feet.left.contact, ContactOwnership::Board);
        assert_eq!(switched.feet.right.contact, ContactOwnership::Unresolved);
        assert_eq!(
            switched.unresolved,
            vec![UnresolvedFootInput::PushContactMarker { foot: Foot::Right }]
        );
    }

    #[test]
    fn fixed_event_sequence_is_repeatable() {
        let run = || {
            let surface = SurfaceIdentity {
                surface: 2,
                primitive: 4,
            };
            let mut coordinator = FootPlacementCoordinator::new();
            let mut outputs = Vec::new();
            outputs.push(
                coordinator
                    .step(push_frame(
                        1,
                        Foot::Right,
                        PushGraphPhase::Start,
                        compact_pair(0.0),
                        Some(ExternalContactEvent::Release {
                            marker: marker(1),
                            primary_weight: weight(0.0),
                            transition_weight: weight(0.5),
                            raw_mode: RawSkeletonIkMode::State2,
                        }),
                    ))
                    .unwrap(),
            );
            outputs.push(
                coordinator
                    .step(push_frame(
                        2,
                        Foot::Right,
                        PushGraphPhase::Contact,
                        compact_pair(1.0),
                        Some(ExternalContactEvent::AcquireSurface {
                            marker: marker(2),
                            sample: surface_sample(4.0, surface),
                        }),
                    ))
                    .unwrap(),
            );
            outputs.push(
                coordinator
                    .step(push_frame(
                        3,
                        Foot::Right,
                        PushGraphPhase::End,
                        compact_pair(2.0),
                        Some(ExternalContactEvent::ReplantBoard {
                            marker: marker(3),
                            observed_ik: observed(1.0, 0.0, RawSkeletonIkMode::State1),
                        }),
                    ))
                    .unwrap(),
            );
            outputs
        };

        assert_eq!(run(), run());
    }
}
