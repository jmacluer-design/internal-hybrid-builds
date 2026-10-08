//! Deterministic Skate 3 TU3 grind MotionGraph/ActionGraph slice.
//!
//! This module reproduces only behavior observed in the recovered retail XML:
//! canonical ActionGraph routing, physics skateboard authority, base-cycle and
//! grind-grab animation requests, transition overrides, `WillExpire` windows,
//! and the `GrindControlFade` binding. Grind contact discovery, trajectory
//! selection, chromosome naming, crouch-threshold evaluation, trick-out
//! physics, and concrete leaves behind virtual resources are explicit inputs
//! or unresolved outputs.
#![allow(dead_code)]

pub const BASE_GRIND_BLEND_SECONDS: f32 = 0.3;
pub const GRAB_INTO_BLEND_SECONDS: f32 = 0.3;
pub const GRAB_CYCLE_BLEND_SECONDS: f32 = 0.1;
pub const GRAB_OUT_BLEND_SECONDS: f32 = 0.1;
pub const GRAB_INTO_WILL_EXPIRE_SECONDS: f32 = 0.01;
pub const STANDARD_INTO_TO_CYCLE_OVERRIDE_SECONDS: f32 = 0.05;
pub const DIRECT_TO_CYCLE_OVERRIDE_SECONDS: f32 = 0.3;
pub const BOARD_DOUBLE_OUT_WILL_EXPIRE_SECONDS: f32 = 0.01;
pub const GRIND_CONTROL_FADE_SECONDS: f32 = 2.5;
pub const PHYS_GRIND_GRAB_MIN_HEIGHT: f32 = 0.2;
pub const GRABBING_ATTRIBUTE_VALUE: f32 = 1.0;

/// The grind parent executes retail `FORCE_PHYSICS_SKATEBOARD`.
///
/// Dark-grind trick-out changes authority in a separate trick branch, which
/// is deliberately outside this grind runtime.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum GrindBoardAuthority {
    #[default]
    Physics,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrindActionRoute {
    TailStraight,
    TailSideways,
    NoseStraight,
    NoseSideways,
    Square,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnknownCanonicalGrind {
    pub canonical_name: String,
}

/// All 54 unique names instantiated by the recovered TU3 `Grinds.xml`.
pub const RETAIL_CANONICAL_GRINDS: [&str; 54] = [
    "BF_BS_5_O",
    "BF_BS_50_50",
    "BF_BS_CROOK",
    "BF_BS_FEEBLE",
    "BF_BS_NOSEGRIND",
    "BF_BS_OVERCROOK",
    "BF_BS_OVERWILLY",
    "BF_BS_SALAD",
    "BF_BS_SMITH",
    "BF_BS_WILLY",
    "BF_FS_5_O",
    "BF_FS_50_50",
    "BF_FS_CROOK",
    "BF_FS_FEEBLE",
    "BF_FS_NOSEGRIND",
    "BF_FS_OVERCROOK",
    "BF_FS_OVERWILLY",
    "BF_FS_SALAD",
    "BF_FS_SMITH",
    "BF_FS_WILLY",
    "BS_5_O",
    "BS_50_50",
    "BS_BLUNT",
    "BS_BOARD",
    "BS_CROOK",
    "BS_DARKSLIDE",
    "BS_FEEBLE",
    "BS_LIP",
    "BS_NOSEBLUNT",
    "BS_NOSEGRIND",
    "BS_NOSESLIDE",
    "BS_OVERCROOK",
    "BS_OVERWILLY",
    "BS_SALAD",
    "BS_SMITH",
    "BS_TAILSLIDE",
    "BS_WILLY",
    "FS_5_O",
    "FS_50_50",
    "FS_BLUNT",
    "FS_BOARD",
    "FS_CROOK",
    "FS_DARKSLIDE",
    "FS_FEEBLE",
    "FS_LIP",
    "FS_NOSEBLUNT",
    "FS_NOSEGRIND",
    "FS_NOSESLIDE",
    "FS_OVERCROOK",
    "FS_OVERWILLY",
    "FS_SALAD",
    "FS_SMITH",
    "FS_TAILSLIDE",
    "FS_WILLY",
];

/// Maps the selected canonical name through the recovered ActionGraph groups.
///
/// The caller may pass the eventual output of `grind_chromosome`; this module
/// intentionally does not duplicate or guess the six-field classifier.
pub fn action_route_for_canonical_name(
    canonical_name: impl AsRef<str>,
) -> Result<GrindActionRoute, UnknownCanonicalGrind> {
    let name = canonical_name.as_ref();
    let route = match name {
        "FS_5_O" | "BS_5_O" | "FS_SALAD" | "BS_SALAD" | "FS_SMITH" | "BS_SMITH" | "FS_FEEBLE"
        | "BS_FEEBLE" | "BF_FS_5_O" | "BF_BS_5_O" | "BF_FS_SALAD" | "BF_BS_SALAD"
        | "BF_FS_SMITH" | "BF_BS_SMITH" | "BF_FS_FEEBLE" | "BF_BS_FEEBLE" => {
            GrindActionRoute::TailStraight
        }

        "BS_TAILSLIDE" | "BS_BLUNT" | "FS_TAILSLIDE" | "FS_BLUNT" => GrindActionRoute::TailSideways,

        "FS_NOSEGRIND" | "BS_NOSEGRIND" | "FS_OVERCROOK" | "BS_OVERCROOK" | "FS_CROOK"
        | "BS_CROOK" | "FS_OVERWILLY" | "BS_OVERWILLY" | "FS_WILLY" | "BS_WILLY"
        | "BF_FS_NOSEGRIND" | "BF_BS_NOSEGRIND" | "BF_FS_OVERCROOK" | "BF_BS_OVERCROOK"
        | "BF_FS_CROOK" | "BF_BS_CROOK" | "BF_FS_OVERWILLY" | "BF_BS_OVERWILLY" | "BF_FS_WILLY"
        | "BF_BS_WILLY" => GrindActionRoute::NoseStraight,

        "BS_NOSESLIDE" | "BS_NOSEBLUNT" | "FS_NOSESLIDE" | "FS_NOSEBLUNT" => {
            GrindActionRoute::NoseSideways
        }

        "FS_50_50" | "BS_50_50" | "BF_FS_50_50" | "BF_BS_50_50" | "FS_BOARD" | "BS_BOARD"
        | "FS_LIP" | "BS_LIP" | "FS_DARKSLIDE" | "BS_DARKSLIDE" => GrindActionRoute::Square,

        _ => {
            return Err(UnknownCanonicalGrind {
                canonical_name: name.to_owned(),
            });
        }
    };
    Ok(route)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrindTemplate {
    Plain,
    StandardGrab,
    Board,
    Dark,
    SingleGrab,
    Blunt,
}

impl GrindTemplate {
    pub const fn air_exit_channel_blend_seconds(self) -> f32 {
        match self {
            Self::SingleGrab => 1.0,
            Self::Dark => 1.5,
            Self::Plain | Self::StandardGrab | Self::Board | Self::Blunt => 0.3,
        }
    }

    pub const fn base_applies_posture(self) -> bool {
        matches!(
            self,
            Self::StandardGrab | Self::Board | Self::Dark | Self::SingleGrab
        )
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VirtualResourceKind {
    MotionGraphResource,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VirtualAnimationResource {
    pub name: String,
    pub kind: VirtualResourceKind,
}

impl VirtualAnimationResource {
    pub fn motion_graph(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            kind: VirtualResourceKind::MotionGraphResource,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConcreteLeafStatus {
    /// Selected leaf must be supplied by retail leaf telemetry or a verified
    /// deterministic resolver before Bevy animation playback.
    Unresolved,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BlendWithCurrentFrame {
    False,
    True,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TransitionOverride {
    /// The XML contains no explicit override at this edge. This does not mean
    /// zero seconds; the inherited engine behavior remains unresolved.
    Inherited,
    Blend {
        seconds: f32,
    },
}

#[derive(Clone, Debug, PartialEq)]
pub struct GrindAnimationRequest {
    pub resource: VirtualAnimationResource,
    pub concrete_leaf_status: ConcreteLeafStatus,
    pub play_animation_blend_seconds: f32,
    pub blend_with_current_frame: BlendWithCurrentFrame,
    pub apply_posture: bool,
    pub repeats: bool,
    /// Override attached to the edge that entered this phase.
    pub entry_transition_override: TransitionOverride,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrindControlFadeRequest {
    pub dist_board_to_cog_animation_attribute: &'static str,
    pub twist_animation_attribute: &'static str,
    pub twist_motion_graph_intent: &'static str,
    pub fade_seconds: f32,
}

pub const GRIND_CONTROL_FADE: GrindControlFadeRequest = GrindControlFadeRequest {
    dist_board_to_cog_animation_attribute: "DistToCog",
    twist_animation_attribute: "twist",
    twist_motion_graph_intent: "GrindBalanceX",
    fade_seconds: GRIND_CONTROL_FADE_SECONDS,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrindSelection {
    /// Output of the external six-field chromosome classifier.
    pub canonical_name: String,
    /// Selected base MotionGraph resource, including any externally resolved
    /// blunt/backslash or dark-approach branch.
    pub base_animation_resource: VirtualAnimationResource,
    pub template: GrindTemplate,
}

impl GrindSelection {
    pub fn new(
        canonical_name: impl Into<String>,
        base_animation_resource: impl Into<String>,
        template: GrindTemplate,
    ) -> Result<Self, UnknownCanonicalGrind> {
        let canonical_name = canonical_name.into();
        action_route_for_canonical_name(&canonical_name)?;
        Ok(Self {
            canonical_name,
            base_animation_resource: VirtualAnimationResource::motion_graph(
                base_animation_resource,
            ),
            template,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrindGrabProfile {
    /// `T_GrindGrabs.xml`: Into expiry carries an explicit 0.05-second blend.
    Standard,
    /// `T_BoardGrabs.xml`: no explicit Into-to-cycle override.
    BoardSingle,
    /// `T_BoardDoubleGrabs.xml`: no Into override; Out uses WillExpire 0.01.
    BoardDouble,
    /// `T_BluntGrindGrab.xml`: no explicit Into-to-cycle override.
    Blunt,
}

impl GrindGrabProfile {
    pub const fn into_to_cycle_override(self) -> TransitionOverride {
        match self {
            Self::Standard => TransitionOverride::Blend {
                seconds: STANDARD_INTO_TO_CYCLE_OVERRIDE_SECONDS,
            },
            Self::BoardSingle | Self::BoardDouble | Self::Blunt => TransitionOverride::Inherited,
        }
    }

    pub const fn out_completion(self) -> GrabOutCompletion {
        match self {
            Self::BoardDouble => GrabOutCompletion::WillExpire {
                seconds: BOARD_DOUBLE_OUT_WILL_EXPIRE_SECONDS,
            },
            Self::Standard | Self::BoardSingle | Self::Blunt => {
                GrabOutCompletion::ExternallyResolved
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GrabOutCompletion {
    WillExpire {
        seconds: f32,
    },
    /// These templates have an unconditional graph edge and no explicit
    /// `WillExpire` value. The engine's inactive-state sequencing is not yet
    /// recovered, so the caller supplies the observed completion.
    ExternallyResolved,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrindGrabEntry {
    /// Intent is present and retail reports that the skater is not crouched
    /// enough to blend directly to the grab cycle.
    Into,
    /// Current-grab/crouch predicates selected `GrabCycleDirect`.
    DirectCycle,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BusyHands {
    Frontside,
    Backside,
    Both,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrindGrabSelection {
    pub profile: GrindGrabProfile,
    pub entry: GrindGrabEntry,
    pub busy_hands: BusyHands,
    pub into_resource: VirtualAnimationResource,
    pub cycle_resource: VirtualAnimationResource,
    pub out_resource: VirtualAnimationResource,
}

impl GrindGrabSelection {
    pub fn new(
        profile: GrindGrabProfile,
        entry: GrindGrabEntry,
        busy_hands: BusyHands,
        into_resource: impl Into<String>,
        cycle_resource: impl Into<String>,
        out_resource: impl Into<String>,
    ) -> Self {
        Self {
            profile,
            entry,
            busy_hands,
            into_resource: VirtualAnimationResource::motion_graph(into_resource),
            cycle_resource: VirtualAnimationResource::motion_graph(cycle_resource),
            out_resource: VirtualAnimationResource::motion_graph(out_resource),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrindPhase {
    /// The selected base state is active. Its PlayAnimation behavior blends
    /// from the current frame over 0.3 seconds; there is no separate base
    /// "into" clip in the recovered templates.
    Cycle,
    GrabInto,
    GrabCycle,
    GrabOut,
    ExitingToAir,
    TrickOut,
    Complete,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrindExitRequest {
    None,
    Air,
    Trick,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GrindSignals {
    pub active_grab_intent_held: bool,
    pub animation_remaining_seconds: Option<f32>,
    /// Required only for templates whose Out edge has no explicit expiry
    /// predicate in XML.
    pub externally_resolved_out_complete: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrindAirExitHook {
    pub channel_blend_seconds: f32,
    pub blend_with_current_frame: bool,
    pub use_channel_from_weights: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrindGrabAttributes {
    pub grabbing: f32,
    pub phys_grind_grab_min_height: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GrindRuntime {
    pub selection: GrindSelection,
    pub phase: GrindPhase,
    pub board_authority: GrindBoardAuthority,
    active_grab: Option<GrindGrabSelection>,
    entry_transition_override: TransitionOverride,
}

impl GrindRuntime {
    pub fn begin(selection: GrindSelection) -> Self {
        Self {
            selection,
            phase: GrindPhase::Cycle,
            board_authority: GrindBoardAuthority::Physics,
            active_grab: None,
            entry_transition_override: TransitionOverride::Inherited,
        }
    }

    pub fn action_route(&self) -> GrindActionRoute {
        action_route_for_canonical_name(&self.selection.canonical_name)
            .expect("GrindSelection validates canonical names")
    }

    pub fn control_fade_request(&self) -> Option<GrindControlFadeRequest> {
        (self.phase == GrindPhase::Cycle).then_some(GRIND_CONTROL_FADE)
    }

    pub fn grab_attributes(&self) -> Option<GrindGrabAttributes> {
        matches!(
            self.phase,
            GrindPhase::GrabInto | GrindPhase::GrabCycle | GrindPhase::GrabOut
        )
        .then_some(GrindGrabAttributes {
            grabbing: GRABBING_ATTRIBUTE_VALUE,
            phys_grind_grab_min_height: PHYS_GRIND_GRAB_MIN_HEIGHT,
        })
    }

    pub fn busy_hands(&self) -> Option<BusyHands> {
        matches!(self.phase, GrindPhase::GrabInto | GrindPhase::GrabCycle)
            .then(|| self.active_grab.as_ref().map(|grab| grab.busy_hands))
            .flatten()
    }

    pub fn animation_request(&self) -> Option<GrindAnimationRequest> {
        let (
            resource,
            play_animation_blend_seconds,
            blend_with_current_frame,
            apply_posture,
            entry_transition_override,
        ) = match self.phase {
            GrindPhase::Cycle => (
                self.selection.base_animation_resource.clone(),
                BASE_GRIND_BLEND_SECONDS,
                BlendWithCurrentFrame::True,
                self.selection.template.base_applies_posture(),
                self.entry_transition_override,
            ),
            GrindPhase::GrabInto => (
                self.active_grab.as_ref()?.into_resource.clone(),
                GRAB_INTO_BLEND_SECONDS,
                BlendWithCurrentFrame::False,
                false,
                self.entry_transition_override,
            ),
            GrindPhase::GrabCycle => (
                self.active_grab.as_ref()?.cycle_resource.clone(),
                GRAB_CYCLE_BLEND_SECONDS,
                BlendWithCurrentFrame::False,
                false,
                self.entry_transition_override,
            ),
            GrindPhase::GrabOut => (
                self.active_grab.as_ref()?.out_resource.clone(),
                GRAB_OUT_BLEND_SECONDS,
                BlendWithCurrentFrame::False,
                false,
                self.entry_transition_override,
            ),
            GrindPhase::ExitingToAir | GrindPhase::TrickOut | GrindPhase::Complete => return None,
        };
        Some(GrindAnimationRequest {
            resource,
            concrete_leaf_status: ConcreteLeafStatus::Unresolved,
            play_animation_blend_seconds,
            blend_with_current_frame,
            apply_posture,
            repeats: matches!(self.phase, GrindPhase::Cycle | GrindPhase::GrabCycle),
            entry_transition_override,
        })
    }

    pub fn air_exit_hook(&self) -> GrindAirExitHook {
        GrindAirExitHook {
            channel_blend_seconds: self.selection.template.air_exit_channel_blend_seconds(),
            blend_with_current_frame: true,
            use_channel_from_weights: true,
        }
    }

    /// Starts a grab using an externally resolved retail entry branch.
    ///
    /// The unknown `IsCrouchedEnoughForBlendToGrabCycle` threshold and current
    /// grab arbitration are deliberately not reconstructed here.
    pub fn enter_grab(&mut self, grab: GrindGrabSelection) {
        self.entry_transition_override = match grab.entry {
            GrindGrabEntry::Into => TransitionOverride::Inherited,
            GrindGrabEntry::DirectCycle => TransitionOverride::Blend {
                seconds: DIRECT_TO_CYCLE_OVERRIDE_SECONDS,
            },
        };
        self.phase = match grab.entry {
            GrindGrabEntry::Into => GrindPhase::GrabInto,
            GrindGrabEntry::DirectCycle => GrindPhase::GrabCycle,
        };
        self.active_grab = Some(grab);
    }

    pub fn request_exit(&mut self, request: GrindExitRequest) {
        self.phase = match request {
            GrindExitRequest::None => return,
            GrindExitRequest::Air => GrindPhase::ExitingToAir,
            GrindExitRequest::Trick => GrindPhase::TrickOut,
        };
        self.active_grab = None;
        self.entry_transition_override = TransitionOverride::Inherited;
        // The grind parent remains physics-authoritative. A later trick graph
        // owns any authority change.
        self.board_authority = GrindBoardAuthority::Physics;
    }

    pub fn step(&mut self, signals: GrindSignals) {
        match self.phase {
            GrindPhase::GrabInto => {
                if !signals.active_grab_intent_held {
                    self.phase = GrindPhase::GrabOut;
                    self.entry_transition_override = TransitionOverride::Inherited;
                } else if will_expire_within(
                    signals.animation_remaining_seconds,
                    GRAB_INTO_WILL_EXPIRE_SECONDS,
                ) {
                    self.phase = GrindPhase::GrabCycle;
                    self.entry_transition_override = self
                        .active_grab
                        .as_ref()
                        .expect("grab phases retain active selection")
                        .profile
                        .into_to_cycle_override();
                }
            }
            GrindPhase::GrabCycle => {
                if !signals.active_grab_intent_held {
                    self.phase = GrindPhase::GrabOut;
                    self.entry_transition_override = TransitionOverride::Inherited;
                }
            }
            GrindPhase::GrabOut => {
                let completion = self
                    .active_grab
                    .as_ref()
                    .expect("grab phases retain active selection")
                    .profile
                    .out_completion();
                let complete = match completion {
                    GrabOutCompletion::WillExpire { seconds } => {
                        will_expire_within(signals.animation_remaining_seconds, seconds)
                    }
                    GrabOutCompletion::ExternallyResolved => {
                        signals.externally_resolved_out_complete
                    }
                };
                if complete {
                    self.phase = GrindPhase::Cycle;
                    self.active_grab = None;
                    self.entry_transition_override = TransitionOverride::Inherited;
                }
            }
            GrindPhase::Cycle
            | GrindPhase::ExitingToAir
            | GrindPhase::TrickOut
            | GrindPhase::Complete => {}
        }
    }

    pub fn complete(&mut self) {
        self.phase = GrindPhase::Complete;
        self.active_grab = None;
        self.entry_transition_override = TransitionOverride::Inherited;
    }
}

fn will_expire_within(remaining_seconds: Option<f32>, window_seconds: f32) -> bool {
    remaining_seconds.is_some_and(|remaining| remaining <= window_seconds)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn selection(template: GrindTemplate) -> GrindSelection {
        GrindSelection::new("FS_50_50", "B_GRIND5050", template).unwrap()
    }

    fn standard_grab(entry: GrindGrabEntry) -> GrindGrabSelection {
        GrindGrabSelection::new(
            GrindGrabProfile::Standard,
            entry,
            BusyHands::Frontside,
            "G_5050_FS_GRAB_INTO",
            "G_5050_FS_GRAB_CYC",
            "G_5050_FS_GRAB_OUT",
        )
    }

    #[test]
    fn all_54_instantiated_names_have_an_action_route() {
        assert_eq!(RETAIL_CANONICAL_GRINDS.len(), 54);
        for name in RETAIL_CANONICAL_GRINDS {
            assert!(
                action_route_for_canonical_name(name).is_ok(),
                "missing route for {name}"
            );
        }
        assert_eq!(
            action_route_for_canonical_name("FS_5_O").unwrap(),
            GrindActionRoute::TailStraight
        );
        assert_eq!(
            action_route_for_canonical_name("BS_NOSESLIDE").unwrap(),
            GrindActionRoute::NoseSideways
        );
        assert_eq!(
            action_route_for_canonical_name("FS_DARKSLIDE").unwrap(),
            GrindActionRoute::Square
        );
        assert!(action_route_for_canonical_name("GUESSED_GRIND").is_err());
    }

    #[test]
    fn base_cycle_uses_retail_blend_control_fade_and_physics_authority() {
        let runtime = GrindRuntime::begin(selection(GrindTemplate::Board));
        assert_eq!(runtime.phase, GrindPhase::Cycle);
        assert_eq!(runtime.board_authority, GrindBoardAuthority::Physics);
        let animation = runtime.animation_request().unwrap();
        assert_eq!(animation.resource.name, "B_GRIND5050");
        assert_eq!(
            animation.play_animation_blend_seconds,
            BASE_GRIND_BLEND_SECONDS
        );
        assert_eq!(
            animation.blend_with_current_frame,
            BlendWithCurrentFrame::True
        );
        assert!(animation.apply_posture);
        assert_eq!(runtime.control_fade_request(), Some(GRIND_CONTROL_FADE));
        assert_eq!(GRIND_CONTROL_FADE.fade_seconds, 2.5);
    }

    #[test]
    fn standard_grab_follows_into_expiry_cycle_release_and_out() {
        let mut runtime = GrindRuntime::begin(selection(GrindTemplate::StandardGrab));
        runtime.enter_grab(standard_grab(GrindGrabEntry::Into));
        assert_eq!(runtime.phase, GrindPhase::GrabInto);
        assert_eq!(
            runtime
                .animation_request()
                .unwrap()
                .play_animation_blend_seconds,
            0.3
        );
        assert_eq!(
            runtime.grab_attributes(),
            Some(GrindGrabAttributes {
                grabbing: 1.0,
                phys_grind_grab_min_height: 0.2,
            })
        );

        runtime.step(GrindSignals {
            active_grab_intent_held: true,
            animation_remaining_seconds: Some(0.0101),
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::GrabInto);
        runtime.step(GrindSignals {
            active_grab_intent_held: true,
            animation_remaining_seconds: Some(0.01),
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::GrabCycle);
        assert_eq!(
            runtime
                .animation_request()
                .unwrap()
                .entry_transition_override,
            TransitionOverride::Blend { seconds: 0.05 }
        );

        runtime.step(GrindSignals {
            active_grab_intent_held: false,
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::GrabOut);
        assert_eq!(
            runtime
                .animation_request()
                .unwrap()
                .play_animation_blend_seconds,
            0.1
        );
        runtime.step(GrindSignals {
            externally_resolved_out_complete: true,
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::Cycle);
    }

    #[test]
    fn direct_cycle_uses_exact_point_three_override() {
        let mut runtime = GrindRuntime::begin(selection(GrindTemplate::StandardGrab));
        runtime.enter_grab(standard_grab(GrindGrabEntry::DirectCycle));
        assert_eq!(runtime.phase, GrindPhase::GrabCycle);
        assert_eq!(
            runtime
                .animation_request()
                .unwrap()
                .entry_transition_override,
            TransitionOverride::Blend { seconds: 0.3 }
        );
    }

    #[test]
    fn board_grab_does_not_invent_missing_point_zero_five_override() {
        let mut runtime = GrindRuntime::begin(selection(GrindTemplate::Board));
        runtime.enter_grab(GrindGrabSelection::new(
            GrindGrabProfile::BoardSingle,
            GrindGrabEntry::Into,
            BusyHands::Backside,
            "G_BSLIDE_BS_GRAB_NOSE_INTO",
            "G_BSLIDE_BS_GRAB_NOSE_CYC",
            "G_BSLIDE_BS_GRAB_NOSE_OUT",
        ));
        runtime.step(GrindSignals {
            active_grab_intent_held: true,
            animation_remaining_seconds: Some(0.01),
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::GrabCycle);
        assert_eq!(
            runtime
                .animation_request()
                .unwrap()
                .entry_transition_override,
            TransitionOverride::Inherited
        );
    }

    #[test]
    fn board_double_out_uses_its_only_explicit_out_expiry_window() {
        let mut runtime = GrindRuntime::begin(selection(GrindTemplate::Board));
        runtime.enter_grab(GrindGrabSelection::new(
            GrindGrabProfile::BoardDouble,
            GrindGrabEntry::DirectCycle,
            BusyHands::Both,
            "G_BSLIDE_BS_GRAB_DOUBLE_INTO",
            "G_BSLIDE_BS_GRAB_DOUBLE_CYC",
            "G_BSLIDE_BS_GRAB_DOUBLE_OUT",
        ));
        runtime.step(GrindSignals {
            active_grab_intent_held: false,
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::GrabOut);
        runtime.step(GrindSignals {
            animation_remaining_seconds: Some(0.0101),
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::GrabOut);
        runtime.step(GrindSignals {
            animation_remaining_seconds: Some(0.01),
            ..GrindSignals::default()
        });
        assert_eq!(runtime.phase, GrindPhase::Cycle);
    }

    #[test]
    fn air_exit_profiles_preserve_template_specific_channel_blends() {
        for (template, expected) in [
            (GrindTemplate::Plain, 0.3),
            (GrindTemplate::StandardGrab, 0.3),
            (GrindTemplate::Board, 0.3),
            (GrindTemplate::Blunt, 0.3),
            (GrindTemplate::SingleGrab, 1.0),
            (GrindTemplate::Dark, 1.5),
        ] {
            let runtime = GrindRuntime::begin(selection(template));
            assert_eq!(runtime.air_exit_hook().channel_blend_seconds, expected);
        }
    }

    #[test]
    fn exits_never_change_authority_inside_the_grind_graph() {
        let mut runtime = GrindRuntime::begin(selection(GrindTemplate::Dark));
        runtime.request_exit(GrindExitRequest::Air);
        assert_eq!(runtime.phase, GrindPhase::ExitingToAir);
        assert_eq!(runtime.board_authority, GrindBoardAuthority::Physics);
        assert!(runtime.animation_request().is_none());

        let mut trick_exit = GrindRuntime::begin(selection(GrindTemplate::Plain));
        trick_exit.request_exit(GrindExitRequest::Trick);
        assert_eq!(trick_exit.phase, GrindPhase::TrickOut);
        assert_eq!(trick_exit.board_authority, GrindBoardAuthority::Physics);
    }

    #[test]
    fn virtual_resources_remain_explicitly_unresolved() {
        let runtime = GrindRuntime::begin(selection(GrindTemplate::Board));
        let request = runtime.animation_request().unwrap();
        assert_eq!(request.concrete_leaf_status, ConcreteLeafStatus::Unresolved);
        assert_eq!(
            request.resource.kind,
            VirtualResourceKind::MotionGraphResource
        );
    }
}
