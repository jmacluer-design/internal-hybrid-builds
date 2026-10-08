//! Evidence-backed Skate 3 TU3 airborne grab graph.
//!
//! This module models the recovered ActionGraph routing and the core
//! `InAir.GrabsTweaks` MotionGraph states. It deliberately does not resolve
//! virtual blend resources to physical ABIN leaves, run hand/board IK, or
//! arbitrate transitions whose retail ordering has not yet been proven.
#![allow(dead_code)]

use crate::board_authority::BoardAuthority;

pub const GRAB_BLEND_SECONDS: f32 = 0.1;
pub const GRAB_WILL_EXPIRE_SECONDS: f32 = 0.01;
pub const FS_BS_INTO_SPEED: f32 = 2.0;
pub const DOUBLE_INTO_SPEED: f32 = 3.0;
pub const MUTE_STALE_INTO_SPEED: f32 = 1.25;
pub const FS_BS_DOUBLE_OUT_SPEED: f32 = 2.0;
pub const TWEAK_FILTER_BLEND_SECONDS: f32 = 0.116;
pub const TWEAK_FILTER_BLEND_OUT_SECONDS: f32 = 0.133;
pub const TWEAK_FILTER_CLAMP_VELOCITY: f32 = 0.1;
pub const GRAB_RELEASE_TWEAK: f32 = 0.2;
pub const FS_BS_CONTACT_WIPEOUT_TWEAK: f32 = 0.4;
pub const DOUBLE_CONTACT_WIPEOUT_TWEAK: f32 = 0.8;
pub const MUTE_STALE_CONTACT_WIPEOUT_TWEAK: f32 = 0.2;
/// XInput's documented digital-trigger boundary. The recovered TU3 graph
/// consumes held trigger actions, while the upstream cInputMap bytecode that
/// publishes those actions has not yet been recovered.
pub const BASIC_GRAB_TRIGGER_THRESHOLD_RAW: u8 = 30;
pub const BOARD_ADJUST_DOWN_LIMIT_RADIANS: f32 = 0.785;
pub const BOARD_ADJUST_UP_LIMIT_RADIANS: f32 = 2.355;
pub const XINPUT_GAMEPAD_A: u16 = 0x1000;
pub const XINPUT_GAMEPAD_B: u16 = 0x2000;
pub const XINPUT_GAMEPAD_X: u16 = 0x4000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabDomain {
    Ground,
    Air,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BasicGrabInput {
    pub left_trigger: bool,
    pub right_trigger: bool,
    pub mirrored: bool,
}

impl BasicGrabInput {
    pub const fn from_raw(left_trigger: u8, right_trigger: u8, mirrored: bool) -> Self {
        Self {
            left_trigger: left_trigger > BASIC_GRAB_TRIGGER_THRESHOLD_RAW,
            right_trigger: right_trigger > BASIC_GRAB_TRIGGER_THRESHOLD_RAW,
            mirrored,
        }
    }

    pub const fn identity(self) -> Option<GrabIdentity> {
        match (self.left_trigger, self.right_trigger) {
            (true, true) => Some(GrabIdentity::Double),
            (true, false) => Some(if self.mirrored {
                GrabIdentity::Bs
            } else {
                GrabIdentity::Fs
            }),
            (false, true) => Some(if self.mirrored {
                GrabIdentity::Fs
            } else {
                GrabIdentity::Bs
            }),
            (false, false) => None,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum GrabTweakDirection {
    #[default]
    Neutral,
    Up,
    Down,
    Left,
    Right,
}

impl GrabTweakDirection {
    pub const fn mirrored(self, mirrored: bool) -> Self {
        if !mirrored {
            return self;
        }
        match self {
            Self::Left => Self::Right,
            Self::Right => Self::Left,
            other => other,
        }
    }
}

/// Classify the four ActionGraph BoardAdjust sectors using the exact XML
/// boundaries. The retail angle has down at zero, right at +pi/2, left at
/// -pi/2, and up at +/-pi.
pub fn board_adjust_direction(right_x: f32, right_y: f32, mirrored: bool) -> GrabTweakDirection {
    if right_x == 0.0 && right_y == 0.0 {
        return GrabTweakDirection::Neutral;
    }
    let right_x = if mirrored { -right_x } else { right_x };
    let angle = right_x.atan2(-right_y);
    if angle.abs() >= BOARD_ADJUST_UP_LIMIT_RADIANS {
        GrabTweakDirection::Up
    } else if angle.abs() <= BOARD_ADJUST_DOWN_LIMIT_RADIANS {
        GrabTweakDirection::Down
    } else if angle < 0.0 {
        GrabTweakDirection::Left
    } else {
        GrabTweakDirection::Right
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReleasedFoot {
    Left,
    Right,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabFootRelease {
    None,
    One(ReleasedFoot),
    Both,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabTrick {
    Fs,
    Bs,
    Double,
    Mute,
    Stale,
    Nose,
    Tail,
    Crail,
    Seatbelt,
    Rocket,
    NoFoot,
    Christ,
    OneFootFs(ReleasedFoot),
    OneFootBs(ReleasedFoot),
    OneFootNose(ReleasedFoot),
    OneFootTail(ReleasedFoot),
    Airwalk,
    Tailwalk,
    Coffin,
    Superman,
}

impl GrabTrick {
    pub const fn base_identity(self) -> GrabIdentity {
        match self {
            Self::Fs
            | Self::Tail
            | Self::Crail
            | Self::NoFoot
            | Self::OneFootFs(_)
            | Self::OneFootTail(_)
            | Self::Tailwalk => GrabIdentity::Fs,
            Self::Bs
            | Self::Nose
            | Self::Seatbelt
            | Self::Christ
            | Self::OneFootBs(_)
            | Self::OneFootNose(_)
            | Self::Airwalk => GrabIdentity::Bs,
            Self::Double | Self::Rocket => GrabIdentity::Double,
            Self::Mute => GrabIdentity::Mute,
            Self::Stale => GrabIdentity::Stale,
            Self::Coffin => GrabIdentity::Coffin,
            Self::Superman => GrabIdentity::Superman,
        }
    }

    pub const fn physical_hands(self, mirrored: bool) -> PhysicalGrabHands {
        physical_hands(self.base_identity(), mirrored)
    }

    pub const fn foot_release(self) -> GrabFootRelease {
        match self {
            Self::OneFootFs(foot)
            | Self::OneFootBs(foot)
            | Self::OneFootNose(foot)
            | Self::OneFootTail(foot) => GrabFootRelease::One(foot),
            Self::NoFoot | Self::Christ | Self::Airwalk | Self::Tailwalk | Self::Superman => {
                GrabFootRelease::Both
            }
            _ => GrabFootRelease::None,
        }
    }

    pub const fn board_authority(self) -> BoardAuthority {
        match self {
            Self::Coffin | Self::Superman => BoardAuthority::Physics,
            _ => BoardAuthority::Animation,
        }
    }

    pub const fn label(self) -> &'static str {
        match self {
            Self::Fs => "FS grab",
            Self::Bs => "BS grab",
            Self::Double => "double grab",
            Self::Mute => "mute grab",
            Self::Stale => "stalefish",
            Self::Nose => "nose grab",
            Self::Tail => "tail grab",
            Self::Crail => "crail grab",
            Self::Seatbelt => "seatbelt",
            Self::Rocket => "rocket air",
            Self::NoFoot => "no-foot air",
            Self::Christ => "Christ air",
            Self::OneFootFs(ReleasedFoot::Right) => "frigid air",
            Self::OneFootFs(ReleasedFoot::Left) => "FS one-foot air",
            Self::OneFootBs(ReleasedFoot::Left) => "judo",
            Self::OneFootBs(ReleasedFoot::Right) => "one-foot air",
            Self::OneFootNose(ReleasedFoot::Left) => "dog piss",
            Self::OneFootNose(ReleasedFoot::Right) => "judo nose grab",
            Self::OneFootTail(ReleasedFoot::Right) => "one-foot tail grab",
            Self::OneFootTail(ReleasedFoot::Left) => "benihana",
            Self::Airwalk => "airwalk",
            Self::Tailwalk => "tailwalk",
            Self::Coffin => "coffin",
            Self::Superman => "superdude",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct GrabInputSelection {
    pub trick: GrabTrick,
    pub identity: GrabIdentity,
}

fn exactly_one_push(buttons: u16) -> Option<ReleasedFoot> {
    match (
        buttons & XINPUT_GAMEPAD_X != 0,
        buttons & XINPUT_GAMEPAD_A != 0,
    ) {
        (true, false) => Some(ReleasedFoot::Left),
        (false, true) => Some(ReleasedFoot::Right),
        _ => None,
    }
}

/// Resolve the ActionGraph grab winner after BoardAdjust has already selected
/// its pre-grab sector. `pre_adjust` is intentionally separate from the live
/// tweak direction: Skate 3 distinguishes RS->trigger from trigger->RS.
pub fn select_full_grab(
    input: BasicGrabInput,
    domain: GrabDomain,
    pre_adjust: GrabTweakDirection,
    buttons: u16,
) -> Option<GrabInputSelection> {
    let identity = input.identity()?;
    let left_push = buttons & XINPUT_GAMEPAD_X != 0;
    let right_push = buttons & XINPUT_GAMEPAD_A != 0;
    let dismount = buttons & XINPUT_GAMEPAD_B != 0;

    let trick = match (domain, identity) {
        (_, GrabIdentity::Double) if left_push && right_push => GrabTrick::Coffin,
        (GrabDomain::Air, GrabIdentity::Double) if dismount => GrabTrick::Superman,
        (GrabDomain::Air, GrabIdentity::Double) if pre_adjust == GrabTweakDirection::Down => {
            GrabTrick::Rocket
        }
        (_, GrabIdentity::Double) => GrabTrick::Double,
        (GrabDomain::Ground, GrabIdentity::Fs) => GrabTrick::Fs,
        (GrabDomain::Ground, GrabIdentity::Bs) => GrabTrick::Bs,
        (GrabDomain::Air, identity @ GrabIdentity::Fs)
        | (GrabDomain::Air, identity @ GrabIdentity::Bs) => {
            let base = match (pre_adjust, identity) {
                (GrabTweakDirection::Up, GrabIdentity::Fs) => GrabTrick::Tail,
                (GrabTweakDirection::Up, GrabIdentity::Bs) => GrabTrick::Seatbelt,
                (GrabTweakDirection::Down, GrabIdentity::Fs) => GrabTrick::Crail,
                (GrabTweakDirection::Down, GrabIdentity::Bs) => GrabTrick::Nose,
                (GrabTweakDirection::Right, GrabIdentity::Fs) => GrabTrick::Stale,
                (GrabTweakDirection::Right, GrabIdentity::Bs) => GrabTrick::Mute,
                (_, GrabIdentity::Fs) => GrabTrick::Fs,
                (_, GrabIdentity::Bs) => GrabTrick::Bs,
                _ => unreachable!(),
            };

            match (
                base,
                dismount,
                left_push && right_push,
                exactly_one_push(buttons),
            ) {
                (GrabTrick::Tail, true, _, _) | (GrabTrick::Tail, _, true, _) => {
                    GrabTrick::Tailwalk
                }
                (GrabTrick::Nose, true, _, _) | (GrabTrick::Nose, _, true, _) => GrabTrick::Airwalk,
                (GrabTrick::Tail, _, _, Some(foot)) => GrabTrick::OneFootTail(foot),
                (GrabTrick::Nose, _, _, Some(foot)) => GrabTrick::OneFootNose(foot),
                (GrabTrick::Fs, true, _, _) => GrabTrick::NoFoot,
                (GrabTrick::Bs, true, _, _) => GrabTrick::Christ,
                (GrabTrick::Fs, _, _, Some(foot)) => GrabTrick::OneFootFs(foot),
                (GrabTrick::Bs, _, _, Some(foot)) => GrabTrick::OneFootBs(foot),
                _ => base,
            }
        }
        _ => return None,
    };
    Some(GrabInputSelection {
        trick,
        identity: trick.base_identity(),
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhysicalGrabHands {
    Left,
    Right,
    Both,
}

pub const fn physical_hands(identity: GrabIdentity, mirrored: bool) -> PhysicalGrabHands {
    match identity {
        GrabIdentity::Double | GrabIdentity::Coffin | GrabIdentity::Superman => {
            PhysicalGrabHands::Both
        }
        GrabIdentity::Fs | GrabIdentity::Stale => {
            if mirrored {
                PhysicalGrabHands::Right
            } else {
                PhysicalGrabHands::Left
            }
        }
        GrabIdentity::Bs | GrabIdentity::Mute => {
            if mirrored {
                PhysicalGrabHands::Left
            } else {
                PhysicalGrabHands::Right
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabHand {
    Fs,
    Bs,
    Both,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabIdentity {
    Fs,
    Bs,
    Double,
    Mute,
    Stale,
    Coffin,
    Superman,
}

impl GrabIdentity {
    pub const fn hand(self) -> GrabHand {
        match self {
            Self::Fs | Self::Stale => GrabHand::Fs,
            Self::Bs | Self::Mute => GrabHand::Bs,
            Self::Double | Self::Coffin | Self::Superman => GrabHand::Both,
        }
    }

    pub const fn board_authority(self) -> BoardAuthority {
        match self {
            // `InAir` owns the ordinary grab branches and executes
            // `FORCE_ANIM_SKATEBOARD`.
            Self::Fs | Self::Bs | Self::Double | Self::Mute | Self::Stale => {
                BoardAuthority::Animation
            }
            // Both included special states explicitly execute
            // `FORCE_PHYSICS_SKATEBOARD`.
            Self::Coffin | Self::Superman => BoardAuthority::Physics,
        }
    }

    pub const fn contact_wipeout_tweak(self) -> Option<f32> {
        match self {
            Self::Fs | Self::Bs => Some(FS_BS_CONTACT_WIPEOUT_TWEAK),
            Self::Double => Some(DOUBLE_CONTACT_WIPEOUT_TWEAK),
            Self::Mute | Self::Stale => Some(MUTE_STALE_CONTACT_WIPEOUT_TWEAK),
            Self::Coffin | Self::Superman => None,
        }
    }
}

/// Raw ActionGraph inputs used by the observed primary-grab selector.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AirGrabActionInput {
    pub left_air_grab: bool,
    pub right_air_grab: bool,
    pub left_push: bool,
    pub right_push: bool,
    pub mirrored: bool,
    pub dismount_just_pressed: bool,
    pub dismount_held: bool,
}

/// Recovered ActionGraph precedence: the two-hand state checks Coffin and
/// Superman before publishing the ordinary `DBLGrab` intent.
pub fn select_air_grab(input: AirGrabActionInput) -> Option<GrabIdentity> {
    match (input.left_air_grab, input.right_air_grab) {
        (true, true) if input.left_push && input.right_push => Some(GrabIdentity::Coffin),
        (true, true) if input.dismount_just_pressed && input.dismount_held => {
            Some(GrabIdentity::Superman)
        }
        (true, true) => Some(GrabIdentity::Double),
        (true, false) => Some(if input.mirrored {
            GrabIdentity::Bs
        } else {
            GrabIdentity::Fs
        }),
        (false, true) => Some(if input.mirrored {
            GrabIdentity::Fs
        } else {
            GrabIdentity::Bs
        }),
        (false, false) => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GrabPhase {
    Into,
    Cycle,
    Out,
    ToDouble,
    FromDouble,
    Complete,
    WipeOut,
    Land,
    ToOffBoard,
    /// Finger flips, one-foot air, Christ transitions, and tip-grab board
    /// adjusts are recovered in separate retail branches. Their winner must be
    /// selected externally before this graph can enter them.
    ExternalBranch(ExternalGrabBranch),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ExternalGrabBranch {
    FingerFlip,
    FingerFlipVarial,
    FingerFlipShuv,
    OneFootAir,
    FsChrist,
    BsChrist,
    TailGrabBoardAdjust,
    NoseGrabBoardAdjust,
    CoffinExitToDouble,
    CoffinExitToFs,
    CoffinExitToBs,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AnimationResourceStatus {
    /// The name is a MotionGraph animation resource. Runtime leaf telemetry or
    /// a verified resolver is required before Bevy may play an ABIN clip.
    VirtualUnresolved,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GrabAnimationRequest {
    pub resource: &'static str,
    pub status: AnimationResourceStatus,
    pub blend_seconds: f32,
    pub playback_speed: f32,
    pub repeats: bool,
    pub apply_posture: bool,
}

const fn animation(
    resource: &'static str,
    playback_speed: f32,
    repeats: bool,
) -> GrabAnimationRequest {
    GrabAnimationRequest {
        resource,
        status: AnimationResourceStatus::VirtualUnresolved,
        blend_seconds: GRAB_BLEND_SECONDS,
        playback_speed,
        repeats,
        apply_posture: false,
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GrabSignals {
    pub identity_intent_held: bool,
    pub fs_grab_held: bool,
    pub bs_grab_held: bool,
    pub double_grab_held: bool,
    pub coffin_held: bool,
    pub superman_held: bool,
    pub tweak_magnitude: f32,
    pub filtered_tweak_y_abs: f32,
    pub physics_state_is_air: bool,
    pub trucks_or_deck_in_contact: bool,
    pub physics_wants_wipeout: bool,
    pub physics_wants_runout: bool,
    pub landing: bool,
    pub on_ground_grab: bool,
    pub offboard_dismount: bool,
    pub is_landing_into_grind: bool,
    pub animation_remaining_seconds: Option<f32>,
    /// StateGraph transition arbitration for these siblings is not represented
    /// by a proven scalar priority. The selected branch is therefore supplied.
    pub selected_external_branch: Option<ExternalGrabBranch>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct GrabRuntime {
    pub identity: GrabIdentity,
    pub phase: GrabPhase,
}

impl GrabRuntime {
    pub const fn begin(identity: GrabIdentity) -> Self {
        Self {
            identity,
            phase: GrabPhase::Into,
        }
    }

    pub const fn board_authority(&self) -> BoardAuthority {
        self.identity.board_authority()
    }

    pub fn animation_request(&self) -> Option<GrabAnimationRequest> {
        let request = match (self.identity, self.phase) {
            (GrabIdentity::Fs, GrabPhase::Into) => {
                animation("GR_GRAB_N_FS_0_INTO", FS_BS_INTO_SPEED, false)
            }
            (GrabIdentity::Fs, GrabPhase::Cycle) => animation("BLEND_FS_TWEAK2", 1.0, true),
            (GrabIdentity::Fs, GrabPhase::Out) => {
                animation("GR_GRAB_N_FS_0_OUT", FS_BS_DOUBLE_OUT_SPEED, false)
            }
            (GrabIdentity::Fs, GrabPhase::ToDouble) => animation("GR_FS2DBL_0_TR", 1.0, false),
            (GrabIdentity::Fs, GrabPhase::FromDouble) => animation("GR_DBL2FS_0_TR", 1.0, false),

            (GrabIdentity::Bs, GrabPhase::Into) => {
                animation("GR_GRAB_N_BS_0_INTO", FS_BS_INTO_SPEED, false)
            }
            (GrabIdentity::Bs, GrabPhase::Cycle) => animation("BLEND_BS_TWEAK", 1.0, true),
            (GrabIdentity::Bs, GrabPhase::Out) => {
                animation("GR_GRAB_N_BS_0_OUT", FS_BS_DOUBLE_OUT_SPEED, false)
            }
            (GrabIdentity::Bs, GrabPhase::ToDouble) => animation("GR_BS2DBL_0_TR", 1.0, false),
            (GrabIdentity::Bs, GrabPhase::FromDouble) => animation("GR_DBL2BS_0_TR", 1.0, false),

            (GrabIdentity::Double, GrabPhase::Into) => {
                animation("GR_GRAB_N_DBL_0_INTO", DOUBLE_INTO_SPEED, false)
            }
            (GrabIdentity::Double, GrabPhase::Cycle) => animation("BLEND_DBL_TWEAK", 1.0, true),
            (GrabIdentity::Double, GrabPhase::Out) => {
                animation("GR_GRAB_N_DBL_0_OUT", FS_BS_DOUBLE_OUT_SPEED, false)
            }

            (GrabIdentity::Mute, GrabPhase::Into) => {
                animation("GR_MUTEGRAB_N_0_INTO", MUTE_STALE_INTO_SPEED, false)
            }
            (GrabIdentity::Mute, GrabPhase::Cycle) => animation("BLEND_MUTE_TWEAK", 1.0, true),
            (GrabIdentity::Mute, GrabPhase::Out) => animation("B_MUTE_OUT", 1.0, false),

            (GrabIdentity::Stale, GrabPhase::Into) => {
                animation("GR_STALEGRAB_N_0_INTO", MUTE_STALE_INTO_SPEED, false)
            }
            (GrabIdentity::Stale, GrabPhase::Cycle) => animation("BLEND_STALE_TWEAK", 1.0, true),
            (GrabIdentity::Stale, GrabPhase::Out) => animation("B_STALE_OUT", 1.0, false),

            (GrabIdentity::Coffin, GrabPhase::Into) => {
                animation("GR_GROUND_N_COFFIN_0_INTO", 1.0, false)
            }
            (GrabIdentity::Coffin, GrabPhase::Cycle) => animation("B_COFFIN", 1.0, true),
            // Coffin has three separately selected exit leaves. That choice is
            // represented as an external transition, not a guessed default.
            (GrabIdentity::Superman, GrabPhase::Into) => {
                animation("GR_DSMNT_SUPER_DBL_0_INTO", 1.0, false)
            }
            (GrabIdentity::Superman, GrabPhase::Cycle) => {
                let mut request = animation("GR_DSMNT_SUPER_DBL_0_CYC", 1.0, true);
                request.blend_seconds = 0.2;
                request
            }
            (GrabIdentity::Superman, GrabPhase::Out) => {
                let mut request = animation("GR_DSMNT_SUPER_DBL_0_OUT", 1.0, false);
                request.blend_seconds = 0.2;
                request
            }

            _ => return None,
        };
        Some(request)
    }

    fn animation_is_expiring(&self, signals: GrabSignals) -> bool {
        signals
            .animation_remaining_seconds
            .is_some_and(|remaining| remaining <= GRAB_WILL_EXPIRE_SECONDS)
    }

    pub fn step(&mut self, signals: GrabSignals) {
        if matches!(
            self.phase,
            GrabPhase::Complete
                | GrabPhase::WipeOut
                | GrabPhase::Land
                | GrabPhase::ToOffBoard
                | GrabPhase::ExternalBranch(_)
        ) {
            return;
        }

        match self.phase {
            GrabPhase::Into => self.step_into(signals),
            GrabPhase::Cycle => self.step_cycle(signals),
            GrabPhase::Out => {
                if self.animation_is_expiring(signals) {
                    self.phase = GrabPhase::Complete;
                }
            }
            GrabPhase::ToDouble => {
                if self.animation_is_expiring(signals) {
                    if signals.coffin_held {
                        self.identity = GrabIdentity::Coffin;
                        self.phase = GrabPhase::Into;
                    } else {
                        self.identity = GrabIdentity::Double;
                        self.phase = GrabPhase::Cycle;
                    };
                }
            }
            GrabPhase::FromDouble => {
                if self.animation_is_expiring(signals) {
                    self.phase = if signals.identity_intent_held {
                        GrabPhase::Cycle
                    } else {
                        GrabPhase::Out
                    };
                }
            }
            GrabPhase::Complete
            | GrabPhase::WipeOut
            | GrabPhase::Land
            | GrabPhase::ToOffBoard
            | GrabPhase::ExternalBranch(_) => {}
        }
    }

    fn step_into(&mut self, signals: GrabSignals) {
        if !self.animation_is_expiring(signals) {
            return;
        }
        if signals.offboard_dismount
            && matches!(
                self.identity,
                GrabIdentity::Fs
                    | GrabIdentity::Bs
                    | GrabIdentity::Double
                    | GrabIdentity::Mute
                    | GrabIdentity::Stale
            )
        {
            self.phase = GrabPhase::ToOffBoard;
            return;
        }
        if let Some(branch) = signals.selected_external_branch {
            self.phase = GrabPhase::ExternalBranch(branch);
            return;
        }
        if self.identity == GrabIdentity::Coffin && !signals.identity_intent_held {
            // `CoffinOut` selects one of three hand-dependent resources. Keep
            // the entry state active until the caller supplies that result.
            return;
        }
        self.phase = if signals.identity_intent_held {
            GrabPhase::Cycle
        } else {
            GrabPhase::Out
        };
    }

    fn step_cycle(&mut self, signals: GrabSignals) {
        let contact_wipeout = self
            .identity
            .contact_wipeout_tweak()
            .is_some_and(|threshold| {
                (!signals.physics_state_is_air || signals.trucks_or_deck_in_contact)
                    && signals.tweak_magnitude >= threshold
            });
        let runout_wipeout = matches!(
            self.identity,
            GrabIdentity::Fs | GrabIdentity::Bs | GrabIdentity::Mute | GrabIdentity::Stale
        ) && signals.physics_wants_runout;
        if signals.physics_wants_wipeout || contact_wipeout || runout_wipeout {
            self.phase = GrabPhase::WipeOut;
            return;
        }
        if signals.on_ground_grab || signals.landing {
            self.phase = GrabPhase::Land;
            return;
        }
        if signals.offboard_dismount
            && !matches!(self.identity, GrabIdentity::Coffin | GrabIdentity::Superman)
        {
            self.phase = GrabPhase::ToOffBoard;
            return;
        }
        if let Some(branch) = signals.selected_external_branch {
            self.phase = GrabPhase::ExternalBranch(branch);
            return;
        }
        match self.identity {
            GrabIdentity::Fs | GrabIdentity::Bs if signals.double_grab_held => {
                self.phase = GrabPhase::ToDouble;
            }
            GrabIdentity::Double if signals.fs_grab_held && !signals.bs_grab_held => {
                self.identity = GrabIdentity::Fs;
                self.phase = GrabPhase::FromDouble;
            }
            GrabIdentity::Double if signals.bs_grab_held && !signals.fs_grab_held => {
                self.identity = GrabIdentity::Bs;
                self.phase = GrabPhase::FromDouble;
            }
            GrabIdentity::Superman if !signals.superman_held => self.phase = GrabPhase::Out,
            GrabIdentity::Coffin if !signals.coffin_held => {
                // Retail chooses CoffinToDBL/BS/FS from held ground-grab
                // intents. Without the ActionGraph result this state remains
                // active rather than selecting the commented FS default.
            }
            GrabIdentity::Mute | GrabIdentity::Stale
                if signals.filtered_tweak_y_abs < GRAB_RELEASE_TWEAK =>
            {
                self.phase = GrabPhase::Out;
            }
            GrabIdentity::Fs | GrabIdentity::Bs | GrabIdentity::Double
                if signals.tweak_magnitude < GRAB_RELEASE_TWEAK =>
            {
                self.phase = GrabPhase::Out;
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn held_trigger_threshold_is_strict_and_both_inputs_survive_arbitration() {
        assert_eq!(
            BasicGrabInput::from_raw(BASIC_GRAB_TRIGGER_THRESHOLD_RAW, 0, false).identity(),
            None
        );
        assert_eq!(
            BasicGrabInput::from_raw(BASIC_GRAB_TRIGGER_THRESHOLD_RAW + 1, 0, false).identity(),
            Some(GrabIdentity::Fs)
        );
        assert_eq!(
            BasicGrabInput::from_raw(u8::MAX, u8::MAX, false).identity(),
            Some(GrabIdentity::Double)
        );
    }

    #[test]
    fn stance_mirroring_swaps_board_side_without_swapping_physical_trigger_hand() {
        for mirrored in [false, true] {
            let left = BasicGrabInput {
                left_trigger: true,
                mirrored,
                ..BasicGrabInput::default()
            }
            .identity()
            .unwrap();
            let right = BasicGrabInput {
                right_trigger: true,
                mirrored,
                ..BasicGrabInput::default()
            }
            .identity()
            .unwrap();
            assert_eq!(physical_hands(left, mirrored), PhysicalGrabHands::Left);
            assert_eq!(physical_hands(right, mirrored), PhysicalGrabHands::Right);
        }
    }

    #[test]
    fn board_adjust_sectors_use_the_exact_recovered_angle_boundaries() {
        assert_eq!(
            board_adjust_direction(0.0, 1.0, false),
            GrabTweakDirection::Up
        );
        assert_eq!(
            board_adjust_direction(0.0, -1.0, false),
            GrabTweakDirection::Down
        );
        assert_eq!(
            board_adjust_direction(-1.0, 0.0, false),
            GrabTweakDirection::Left
        );
        assert_eq!(
            board_adjust_direction(1.0, 0.0, false),
            GrabTweakDirection::Right
        );
        assert_eq!(
            board_adjust_direction(1.0, 0.0, true),
            GrabTweakDirection::Left
        );
        assert_eq!(
            board_adjust_direction(0.0, 0.0, false),
            GrabTweakDirection::Neutral
        );
    }

    #[test]
    fn stick_first_routes_tip_crossbody_and_rocket_grabs() {
        let left = BasicGrabInput {
            left_trigger: true,
            ..BasicGrabInput::default()
        };
        let right = BasicGrabInput {
            right_trigger: true,
            ..BasicGrabInput::default()
        };
        let both = BasicGrabInput {
            left_trigger: true,
            right_trigger: true,
            ..BasicGrabInput::default()
        };
        for (input, adjust, expected) in [
            (left, GrabTweakDirection::Up, GrabTrick::Tail),
            (right, GrabTweakDirection::Up, GrabTrick::Seatbelt),
            (left, GrabTweakDirection::Down, GrabTrick::Crail),
            (right, GrabTweakDirection::Down, GrabTrick::Nose),
            (left, GrabTweakDirection::Right, GrabTrick::Stale),
            (right, GrabTweakDirection::Right, GrabTrick::Mute),
            (both, GrabTweakDirection::Down, GrabTrick::Rocket),
        ] {
            assert_eq!(
                select_full_grab(input, GrabDomain::Air, adjust, 0)
                    .map(|selection| selection.trick),
                Some(expected)
            );
        }
    }

    #[test]
    fn face_button_chords_route_one_foot_no_foot_superman_and_coffin() {
        let left = BasicGrabInput {
            left_trigger: true,
            ..BasicGrabInput::default()
        };
        let right = BasicGrabInput {
            right_trigger: true,
            ..BasicGrabInput::default()
        };
        let both = BasicGrabInput {
            left_trigger: true,
            right_trigger: true,
            ..BasicGrabInput::default()
        };
        for (input, adjust, buttons, domain, expected) in [
            (
                left,
                GrabTweakDirection::Neutral,
                XINPUT_GAMEPAD_B,
                GrabDomain::Air,
                GrabTrick::NoFoot,
            ),
            (
                right,
                GrabTweakDirection::Neutral,
                XINPUT_GAMEPAD_B,
                GrabDomain::Air,
                GrabTrick::Christ,
            ),
            (
                left,
                GrabTweakDirection::Neutral,
                XINPUT_GAMEPAD_A,
                GrabDomain::Air,
                GrabTrick::OneFootFs(ReleasedFoot::Right),
            ),
            (
                right,
                GrabTweakDirection::Down,
                XINPUT_GAMEPAD_X,
                GrabDomain::Air,
                GrabTrick::OneFootNose(ReleasedFoot::Left),
            ),
            (
                both,
                GrabTweakDirection::Neutral,
                XINPUT_GAMEPAD_B,
                GrabDomain::Air,
                GrabTrick::Superman,
            ),
            (
                both,
                GrabTweakDirection::Neutral,
                XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_X,
                GrabDomain::Ground,
                GrabTrick::Coffin,
            ),
        ] {
            assert_eq!(
                select_full_grab(input, domain, adjust, buttons).map(|selection| selection.trick),
                Some(expected)
            );
        }
    }

    fn expiring() -> GrabSignals {
        GrabSignals {
            physics_state_is_air: true,
            identity_intent_held: true,
            animation_remaining_seconds: Some(GRAB_WILL_EXPIRE_SECONDS),
            ..Default::default()
        }
    }

    #[test]
    fn action_graph_mirrors_single_hand_grabs_and_prioritizes_special_doubles() {
        assert_eq!(
            select_air_grab(AirGrabActionInput {
                left_air_grab: true,
                ..Default::default()
            }),
            Some(GrabIdentity::Fs)
        );
        assert_eq!(
            select_air_grab(AirGrabActionInput {
                left_air_grab: true,
                mirrored: true,
                ..Default::default()
            }),
            Some(GrabIdentity::Bs)
        );
        assert_eq!(
            select_air_grab(AirGrabActionInput {
                left_air_grab: true,
                right_air_grab: true,
                dismount_just_pressed: true,
                dismount_held: true,
                ..Default::default()
            }),
            Some(GrabIdentity::Superman)
        );
        assert_eq!(
            select_air_grab(AirGrabActionInput {
                left_air_grab: true,
                right_air_grab: true,
                left_push: true,
                right_push: true,
                dismount_just_pressed: true,
                dismount_held: true,
                ..Default::default()
            }),
            Some(GrabIdentity::Coffin)
        );
    }

    #[test]
    fn normal_grab_enters_cycle_only_at_recovered_will_expire_window() {
        let mut runtime = GrabRuntime::begin(GrabIdentity::Fs);
        runtime.step(GrabSignals {
            animation_remaining_seconds: Some(0.011),
            identity_intent_held: true,
            physics_state_is_air: true,
            ..Default::default()
        });
        assert_eq!(runtime.phase, GrabPhase::Into);
        runtime.step(expiring());
        assert_eq!(runtime.phase, GrabPhase::Cycle);
    }

    #[test]
    fn resources_and_playback_speeds_match_each_template() {
        let fs = GrabRuntime::begin(GrabIdentity::Fs)
            .animation_request()
            .unwrap();
        let dbl = GrabRuntime::begin(GrabIdentity::Double)
            .animation_request()
            .unwrap();
        let mute = GrabRuntime::begin(GrabIdentity::Mute)
            .animation_request()
            .unwrap();
        assert_eq!(
            (fs.resource, fs.playback_speed),
            ("GR_GRAB_N_FS_0_INTO", 2.0)
        );
        assert_eq!(
            (dbl.resource, dbl.playback_speed),
            ("GR_GRAB_N_DBL_0_INTO", 3.0)
        );
        assert_eq!(
            (mute.resource, mute.playback_speed),
            ("GR_MUTEGRAB_N_0_INTO", 1.25)
        );
        assert_eq!(fs.status, AnimationResourceStatus::VirtualUnresolved);
    }

    #[test]
    fn each_grab_uses_its_observed_contact_wipeout_threshold() {
        for (identity, below, at) in [
            (GrabIdentity::Fs, 0.399, 0.4),
            (GrabIdentity::Double, 0.799, 0.8),
            (GrabIdentity::Mute, 0.199, 0.2),
        ] {
            let mut safe = GrabRuntime {
                identity,
                phase: GrabPhase::Cycle,
            };
            safe.step(GrabSignals {
                physics_state_is_air: true,
                trucks_or_deck_in_contact: true,
                tweak_magnitude: below,
                identity_intent_held: true,
                filtered_tweak_y_abs: 1.0,
                ..Default::default()
            });
            assert_ne!(safe.phase, GrabPhase::WipeOut);

            let mut wipe = GrabRuntime {
                identity,
                phase: GrabPhase::Cycle,
            };
            wipe.step(GrabSignals {
                physics_state_is_air: true,
                trucks_or_deck_in_contact: true,
                tweak_magnitude: at,
                identity_intent_held: true,
                filtered_tweak_y_abs: 1.0,
                ..Default::default()
            });
            assert_eq!(wipe.phase, GrabPhase::WipeOut);
        }
    }

    #[test]
    fn ordinary_and_mute_templates_use_their_distinct_release_gates() {
        let mut fs = GrabRuntime {
            identity: GrabIdentity::Fs,
            phase: GrabPhase::Cycle,
        };
        fs.step(GrabSignals {
            physics_state_is_air: true,
            tweak_magnitude: 0.19,
            filtered_tweak_y_abs: 0.9,
            ..Default::default()
        });
        assert_eq!(fs.phase, GrabPhase::Out);

        let mut mute = GrabRuntime {
            identity: GrabIdentity::Mute,
            phase: GrabPhase::Cycle,
        };
        mute.step(GrabSignals {
            physics_state_is_air: true,
            tweak_magnitude: 0.9,
            filtered_tweak_y_abs: 0.19,
            ..Default::default()
        });
        assert_eq!(mute.phase, GrabPhase::Out);
    }

    #[test]
    fn fs_and_bs_transition_through_observed_double_grab_resources() {
        let mut runtime = GrabRuntime {
            identity: GrabIdentity::Fs,
            phase: GrabPhase::Cycle,
        };
        runtime.step(GrabSignals {
            physics_state_is_air: true,
            double_grab_held: true,
            tweak_magnitude: 1.0,
            filtered_tweak_y_abs: 1.0,
            ..Default::default()
        });
        assert_eq!(runtime.phase, GrabPhase::ToDouble);
        assert_eq!(
            runtime.animation_request().unwrap().resource,
            "GR_FS2DBL_0_TR"
        );
        runtime.step(expiring());
        assert_eq!(runtime.identity, GrabIdentity::Double);
        assert_eq!(runtime.phase, GrabPhase::Cycle);
    }

    #[test]
    fn double_grab_can_return_to_the_single_held_hand() {
        let mut runtime = GrabRuntime {
            identity: GrabIdentity::Double,
            phase: GrabPhase::Cycle,
        };
        runtime.step(GrabSignals {
            physics_state_is_air: true,
            fs_grab_held: true,
            tweak_magnitude: 1.0,
            filtered_tweak_y_abs: 1.0,
            ..Default::default()
        });
        assert_eq!(runtime.identity, GrabIdentity::Fs);
        assert_eq!(runtime.phase, GrabPhase::FromDouble);
        assert_eq!(
            runtime.animation_request().unwrap().resource,
            "GR_DBL2FS_0_TR"
        );
    }

    #[test]
    fn ordinary_air_grabs_animate_board_but_special_body_states_use_physics() {
        assert_eq!(
            GrabRuntime::begin(GrabIdentity::Stale).board_authority(),
            BoardAuthority::Animation
        );
        assert_eq!(
            GrabRuntime::begin(GrabIdentity::Coffin).board_authority(),
            BoardAuthority::Physics
        );
        assert_eq!(
            GrabRuntime::begin(GrabIdentity::Superman).board_authority(),
            BoardAuthority::Physics
        );
    }

    #[test]
    fn unresolved_sibling_arbitration_is_never_guessed() {
        let mut runtime = GrabRuntime {
            identity: GrabIdentity::Bs,
            phase: GrabPhase::Cycle,
        };
        runtime.step(GrabSignals {
            physics_state_is_air: true,
            selected_external_branch: Some(ExternalGrabBranch::FingerFlipVarial),
            tweak_magnitude: 1.0,
            filtered_tweak_y_abs: 1.0,
            ..Default::default()
        });
        assert_eq!(
            runtime.phase,
            GrabPhase::ExternalBranch(ExternalGrabBranch::FingerFlipVarial)
        );
        assert!(runtime.animation_request().is_none());
    }
}
