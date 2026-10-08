use bevy::prelude::*;

/// The retail skateboard force helpers use piecewise-linear point graphs.
///
/// This mirrors the graph evaluator called by
/// `Sk8::Physics::Skateboard::ToolKit_CalcSlideFriction` at 0x82D92970.
/// Keeping the graph explicit is important: the force is not a generic drag
/// multiplier and its tuning can be replaced with dumped retail points without
/// changing the integration model.
#[derive(Clone, Copy, Debug)]
pub struct PointGraph<const N: usize> {
    pub points: [(f32, f32); N],
}

impl<const N: usize> PointGraph<N> {
    pub const fn new(points: [(f32, f32); N]) -> Self {
        Self { points }
    }

    pub fn sample(&self, x: f32) -> f32 {
        let Some(&(first_x, first_y)) = self.points.first() else {
            return 0.0;
        };
        if x <= first_x {
            return first_y;
        }

        for pair in self.points.windows(2) {
            let (x0, y0) = pair[0];
            let (x1, y1) = pair[1];
            if x <= x1 {
                let extent = x1 - x0;
                let coefficient = if extent.abs() > f32::EPSILON {
                    (x - x0) / extent
                } else {
                    0.0
                };
                return y0 + (y1 - y0) * coefficient;
            }
        }

        self.points.last().map_or(0.0, |(_, y)| *y)
    }
}

/// Composite lateral-rate observations from the captured TU3 flat-ground run.
///
/// The executable multiplies three tuning graphs and several physical fields
/// before applying `-board_right * lateral_speed * coefficient`. Until those
/// live tuning arrays are dumped, these points preserve the observed composite
/// output rather than inventing a replacement force law. They were identified
/// by integrating the recovered force equation over the uninterrupted BS slide
/// and minimizing its position/velocity residual against
/// `work/retail-motion-signals.csv`.
const CAPTURED_SLIDE_LATERAL_RATE: PointGraph<8> = PointGraph::new([
    (0.80, 7.647),
    (1.50, 6.206),
    (2.50, 4.779),
    (3.50, 3.457),
    (4.50, 2.469),
    (5.50, 2.272),
    (6.50, 3.218),
    (8.50, 4.605),
]);

/// The captured slide pose fit reaches the HSP (`DECEL=1`) endpoint once the
/// normalized local side velocity is about 0.5. The internal retail graph has
/// eight points; this measured envelope deliberately remains a separate graph
/// so a future runtime dump can replace it without touching the blend system.
const CAPTURED_DECEL_ENVELOPE: PointGraph<8> = PointGraph::new([
    (0.00, 0.00),
    (0.08, 0.16),
    (0.16, 0.32),
    (0.24, 0.48),
    (0.32, 0.64),
    (0.40, 0.80),
    (0.48, 0.96),
    (0.50, 1.00),
]);

/// Established board yaw rates from the same captured BS powerslide.
///
/// The retail board continues rotating independently from its velocity vector;
/// this graph is therefore a board angular-velocity signal, not a shortcut
/// that rotates linear velocity. Values below the retail slide speed gate are
/// zero because the motion graph leaves the active slide state there.
const CAPTURED_SLIDE_YAW_RATE: PointGraph<9> = PointGraph::new([
    (0.00, 0.00),
    (0.88, 0.00),
    (1.00, 2.28),
    (1.80, 2.18),
    (2.80, 1.80),
    (3.00, 1.61),
    (5.10, 2.19),
    (5.80, 2.59),
    (7.80, 3.83),
]);

// Flat-ground values measured by the matched TU3 capture. These are separate
// force paths in retail: rolling resistance and foot-brake deceleration are
// not folded into slide friction.
pub const CAPTURED_ROLLING_DECELERATION: f32 = 0.035;
pub const CAPTURED_FOOT_BRAKE_DECELERATION: f32 = 3.90;
pub const CAPTURED_SLIDE_ROLLING_DECELERATION: f32 = 0.343;

// Identified from both directional carve sections of the matched TU3 run.
// Once settled, board yaw rate is speed * reshaped steer * curvature. The
// median established curvature is 0.1895 rad/m; fitting the complete
// 60 Hz input ramps together with their response state gives 0.24504537 rad/m
// before the recovered vertical-stick reshape is applied.
pub const CAPTURED_CARVE_CURVATURE: f32 = 0.245_045_36;

// The slide state is entered from a physical candidate route rather than an
// animation-side raw-stick test. `CanEnterSlide` (TU3 0x82BA6FE0) and
// `ShouldLeaveSlide` (TU3 0x82BA7130) reinterpret selected derived-input timer
// words, while `InCandidateSlidingState` writes a separate owner marker. The
// native sign-bit entry producer remains unresolved; these effective
// thresholds and response constants were identified against the matched
// side-to-down capture; see
// `work/identified-turning-controller-with-out.json`.
pub const CAPTURED_CANDIDATE_DOWN_START: f32 = 0.57;
pub const CAPTURED_SLIDE_ENTER_DOWN: f32 = 0.88;
pub const CAPTURED_SLIDE_MINIMUM_SPEED: f32 = 0.84;
pub const CAPTURED_CANDIDATE_SIDE_MINIMUM: f32 = 0.20;
pub const CAPTURED_SLIDE_YAW_RESPONSE_SECONDS: f32 = 0.035;
pub const CAPTURED_SLIDE_OUT_YAW_RESPONSE_SECONDS: f32 = 0.13;

// The flat-ground carve fixture identifies an effective normal-contact rate of
// 18 s^-1 when the recovered side-axis force form is integrated directly.
// This remains a named composite until the normal-contact tuning arrays are
// dumped from the retail skateboard object.
pub const NORMAL_CONTACT_LATERAL_RATE: f32 = 18.0;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LocalVelocity {
    pub longitudinal: f32,
    pub lateral: f32,
    pub speed: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct PlanarForceResult {
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub local_before: LocalVelocity,
    pub lateral_rate: f32,
    pub rolling_deceleration: f32,
    pub brake_deceleration: f32,
}

pub fn board_basis(yaw: f32) -> (Vec3, Vec3) {
    (
        Vec3::new(yaw.sin(), 0.0, yaw.cos()),
        Vec3::new(yaw.cos(), 0.0, -yaw.sin()),
    )
}

/// Established rolling-mode horizontal output of `SetTurning::Reshape`.
///
/// `SetTurning::Reshape` (TU3 0x82BB4248) converts the complete stick to polar
/// coordinates, evaluates direction-dependent point graphs, and converts it
/// back to a bounded vector. The matched non-slide carve ramps establish this
/// effective coordinate. The synchronized forward-turn fixture
/// `work/dual-camera-turn-response-ollie-fitted.csv` proves the vertical
/// attenuation is one-sided: positive/forward Y keeps the full horizontal
/// axis, while negative/down Y leads toward the slide sector. Candidate
/// sliding has its own physical controller below and must not be hidden inside
/// this rolling response.
pub fn rolling_turn_axis(stick: Vec2) -> f32 {
    (stick.x * (1.0 - (-stick.y).max(0.0))).clamp(-1.0, 1.0)
}

/// Continuous controller weight leading into physical candidate sliding.
///
/// The weight begins before `CanEnterSlide` becomes true, matching the retail
/// board-yaw ramp during the side-to-down sweep. Reaching one represents the
/// fixture-identified effective entry point; it is not mislabeled as the
/// separately written candidate-owner marker.
pub fn candidate_slide_weight(stick: Vec2, speed: f32) -> f32 {
    if stick.x.abs() <= CAPTURED_CANDIDATE_SIDE_MINIMUM || speed <= CAPTURED_SLIDE_MINIMUM_SPEED {
        return 0.0;
    }

    let amount = ((-stick.y - CAPTURED_CANDIDATE_DOWN_START)
        / (CAPTURED_SLIDE_ENTER_DOWN - CAPTURED_CANDIDATE_DOWN_START))
        .clamp(0.0, 1.0);
    amount * amount * (3.0 - 2.0 * amount)
}

/// Stance-local processed stick used by retail's powerslide behaviour.
///
/// `PowerSliding::Update` (TU3 0x82BC01C0) reads the two processed left-stick
/// channels at provider offsets 496/500 and mirrors the lateral channel before
/// passing the conditioned pair to the skateboard controller. Keeping that
/// transform here also keeps regular/goofy routing out of the generic contact
/// friction path.
pub fn stance_local_slide_stick(stick: Vec2, mirrored: bool) -> Vec2 {
    if mirrored {
        Vec2::new(-stick.x, stick.y)
    } else {
        stick
    }
}

/// Continuous control retained after the candidate state has latched.
///
/// Retail does not call `CanEnterSlide` again to maintain the graph state.
/// The already recovered down-sector curve remains useful as the continuous
/// turn/pose intent, but its side and speed entry gates are deliberately not
/// reused as cancellation predicates.
pub fn active_slide_intent(stick: Vec2, mirrored: bool) -> f32 {
    let stick = stance_local_slide_stick(stick, mirrored);
    let amount = ((-stick.y - CAPTURED_CANDIDATE_DOWN_START)
        / (CAPTURED_SLIDE_ENTER_DOWN - CAPTURED_CANDIDATE_DOWN_START))
        .clamp(0.0, 1.0);
    amount * amount * (3.0 - 2.0 * amount)
}

/// Evidence-backed physical/processed-input leave predicate for the Bevy
/// integration.
///
/// The matched TU3 fixture proves the strict low-speed exit while the retail
/// graph reads contact-produced `ShouldLeaveSlide` independently of entry.
/// The established capture's down-sector start is also the last proven
/// continuous-control boundary. Crossing out of that sector is a deliberate
/// release; this avoids both an exact-zero trap and an invented second angular
/// tolerance. The native timer-word producer is documented as unresolved.
pub fn should_leave_active_slide(stick: Vec2, speed: f32, contact_valid: bool) -> bool {
    !contact_valid
        || speed <= CAPTURED_SLIDE_MINIMUM_SPEED
        || active_slide_intent(stick, false) <= f32::EPSILON
}

pub fn local_velocity(velocity: Vec3, yaw: f32) -> LocalVelocity {
    let horizontal = Vec3::new(velocity.x, 0.0, velocity.z);
    let (forward, right) = board_basis(yaw);
    LocalVelocity {
        longitudinal: horizontal.dot(forward),
        lateral: horizontal.dot(right),
        speed: horizontal.length(),
    }
}

pub fn slide_decel_target(velocity: Vec3, yaw: f32) -> f32 {
    let local = local_velocity(velocity, yaw);
    if local.speed <= f32::EPSILON {
        0.0
    } else {
        CAPTURED_DECEL_ENVELOPE.sample((local.lateral / local.speed).abs())
    }
}

pub fn captured_slide_yaw_rate(speed: f32) -> f32 {
    CAPTURED_SLIDE_YAW_RATE.sample(speed)
}

pub fn integrate_flat_ground(
    velocity: Vec3,
    yaw: f32,
    dt: f32,
    sliding: bool,
    braking: bool,
    maximum_speed: f32,
) -> PlanarForceResult {
    let horizontal = Vec3::new(velocity.x, 0.0, velocity.z);
    let local = local_velocity(horizontal, yaw);
    if local.speed <= f32::EPSILON {
        return PlanarForceResult {
            velocity: Vec3::ZERO,
            local_before: local,
            ..default()
        };
    }

    let (_, right) = board_basis(yaw);
    let lateral_rate = if sliding {
        CAPTURED_SLIDE_LATERAL_RATE.sample(local.speed)
    } else {
        NORMAL_CONTACT_LATERAL_RATE
    };

    // This is the recovered retail force structure: side-axis force opposes
    // the board-local lateral velocity. Clamp the impulse so one integration
    // step cannot reverse that component.
    let requested_lateral_delta = -local.lateral * lateral_rate * dt;
    let lateral_delta = requested_lateral_delta.clamp(-local.lateral.abs(), local.lateral.abs());
    let lateral_acceleration = right * (lateral_delta / dt);
    let velocity_after_lateral = horizontal + lateral_acceleration * dt;

    let rolling_deceleration = if sliding {
        // Identified together with the composite side-rate graph by integrating
        // the recovered force form against the complete retail slide path.
        CAPTURED_SLIDE_ROLLING_DECELERATION
    } else {
        CAPTURED_ROLLING_DECELERATION
    };
    let brake_deceleration = if braking {
        CAPTURED_FOOT_BRAKE_DECELERATION
    } else {
        0.0
    };
    let longitudinal_acceleration =
        -velocity_after_lateral.normalize_or_zero() * (rolling_deceleration + brake_deceleration);
    let mut next = velocity_after_lateral + longitudinal_acceleration * dt;

    // Do not allow longitudinal resistance to reverse a nearly stopped board.
    if next.dot(horizontal) <= 0.0 {
        next = Vec3::ZERO;
    } else if next.length() > maximum_speed {
        next = next.normalize() * maximum_speed;
    } else if next.length() < 0.018 {
        next = Vec3::ZERO;
    }

    PlanarForceResult {
        velocity: next,
        acceleration: (next - horizontal) / dt,
        local_before: local,
        lateral_rate,
        rolling_deceleration,
        brake_deceleration,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn point_graph_interpolates_and_clamps_to_endpoints() {
        let graph = PointGraph::new([(0.0, 2.0), (1.0, 4.0), (3.0, 8.0)]);
        assert_eq!(graph.sample(-1.0), 2.0);
        assert_eq!(graph.sample(4.0), 8.0);
        assert!((graph.sample(2.0) - 6.0).abs() < 0.0001);
    }

    #[test]
    fn slide_force_opposes_only_the_board_local_side_velocity() {
        let result = integrate_flat_ground(
            Vec3::new(2.0, 0.0, 6.0),
            0.0,
            1.0 / 120.0,
            true,
            false,
            12.5,
        );
        assert!(result.acceleration.x < 0.0);
        assert!(result.local_before.lateral > 0.0);
        assert!(result.velocity.x < 2.0);
    }

    #[test]
    fn slide_slowdown_emerges_from_side_slip() {
        let dt = 1.0 / 120.0;
        let aligned = integrate_flat_ground(Vec3::Z * 6.0, 0.0, dt, true, false, 12.5);
        let sideways = integrate_flat_ground(Vec3::X * 6.0, 0.0, dt, true, false, 12.5);
        assert!(sideways.velocity.length() < aligned.velocity.length());
        assert!(sideways.acceleration.x.abs() > aligned.acceleration.z.abs());
    }

    #[test]
    fn normal_wheel_contact_dissipates_only_board_local_side_slip() {
        let dt = 1.0 / 120.0;
        let aligned = integrate_flat_ground(Vec3::Z * 6.0, 0.0, dt, false, false, 12.5);
        let diagonal =
            integrate_flat_ground(Vec3::new(3.0, 0.0, 5.196_152), 0.0, dt, false, false, 12.5);

        assert!(diagonal.velocity.length() < aligned.velocity.length());
        assert!(diagonal.velocity.x.abs() < 3.0);
        assert!((diagonal.velocity.z - 5.196_152).abs() < 0.001);
    }

    #[test]
    fn decel_parameter_uses_normalized_local_side_velocity() {
        assert_eq!(slide_decel_target(Vec3::Z * 5.0, 0.0), 0.0);
        assert_eq!(slide_decel_target(Vec3::X * 5.0, 0.0), 1.0);
        assert!((slide_decel_target(Vec3::new(0.5, 0.0, 5.0), 0.0) - 0.2).abs() < 0.01);
    }

    #[test]
    fn rolling_turn_reshape_and_candidate_slide_are_separate() {
        let stick = Vec2::new(-0.8, -0.6);
        assert!((rolling_turn_axis(stick) + 0.32).abs() < 0.0001);
        assert!((rolling_turn_axis(Vec2::new(-0.8, 0.6)) + 0.8).abs() < 0.0001);
        assert!(candidate_slide_weight(stick, 5.0) > 0.0);
        assert!(candidate_slide_weight(stick, 5.0) < 1.0);
        assert_eq!(rolling_turn_axis(Vec2::ZERO), 0.0);
    }

    #[test]
    fn candidate_slide_obeys_the_recovered_entry_state_gates() {
        assert_eq!(candidate_slide_weight(Vec2::new(-0.8, -0.5), 5.0), 0.0);
        assert_eq!(candidate_slide_weight(Vec2::new(-0.1, -1.0), 5.0), 0.0);
        assert_eq!(candidate_slide_weight(Vec2::new(-0.8, -1.0), 0.84), 0.0);
        assert_eq!(candidate_slide_weight(Vec2::new(-0.8, -0.88), 5.0), 1.0);
    }

    #[test]
    fn candidate_slide_preserves_the_measured_broad_downward_sector() {
        for stick in [
            Vec2::new(0.447, -0.894),
            Vec2::new(-0.447, -0.894),
            Vec2::new(0.70, -0.90),
            Vec2::new(-0.95, -0.90),
        ] {
            assert_eq!(candidate_slide_weight(stick, 2.0), 1.0, "{stick:?}");
        }
        for stick in [
            Vec2::new(1.0, 0.0),
            Vec2::new(0.707, -0.707),
            Vec2::new(0.19, -1.0),
            Vec2::new(-0.447, -0.86),
        ] {
            assert!(candidate_slide_weight(stick, 2.0) < 1.0, "{stick:?}");
        }
    }

    #[test]
    fn active_slide_uses_continuous_intent_without_reapplying_entry_gates() {
        let modest_adjustment = Vec2::new(0.12, -0.82);
        assert_eq!(candidate_slide_weight(modest_adjustment, 2.0), 0.0);
        assert!(active_slide_intent(modest_adjustment, false) > 0.0);
        assert!(!should_leave_active_slide(modest_adjustment, 2.0, true));
    }

    #[test]
    fn active_slide_leave_gates_are_strict_and_physical() {
        let held = Vec2::new(0.30, -0.90);
        assert!(!should_leave_active_slide(held, 0.840_001, true));
        assert!(should_leave_active_slide(held, 0.84, true));
        assert!(should_leave_active_slide(held, 2.0, false));
        assert!(should_leave_active_slide(Vec2::ZERO, 2.0, true));
        assert!(should_leave_active_slide(Vec2::new(0.01, -0.01), 2.0, true));
        assert!(should_leave_active_slide(Vec2::new(0.0, 1.0), 2.0, true));
        assert!(!should_leave_active_slide(
            Vec2::new(-1.0, -0.58),
            2.0,
            true
        ));
    }

    #[test]
    fn stance_mirroring_changes_lateral_routing_not_downward_strength() {
        let regular = stance_local_slide_stick(Vec2::new(0.45, -0.90), false);
        let goofy = stance_local_slide_stick(Vec2::new(0.45, -0.90), true);
        assert_eq!(regular, Vec2::new(0.45, -0.90));
        assert_eq!(goofy, Vec2::new(-0.45, -0.90));
        assert_eq!(
            active_slide_intent(regular, false).to_bits(),
            active_slide_intent(regular, true).to_bits()
        );
    }
}
