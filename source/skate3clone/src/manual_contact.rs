//! Geometry-gated deck-end contact and measured manual scrape dissipation.
//!
//! Geometry comes from the decoded `skater_rig.glb` board primitive. The
//! contact angles are derived from its wheel-ground plane, axle locations and
//! first contacting deck vertices; they are not hand-tuned pose limits.

use bevy::prelude::*;

use crate::manual_graph::ManualKind;

/// Decoded board geometry, metres in the exported rig coordinate system.
pub const NOSE_AXLE_LONGITUDINAL: f32 = 0.242_859;
pub const NOSE_CONTACT_LONGITUDINAL: f32 = 0.445_312_5;
pub const NOSE_CONTACT_REST_HEIGHT: f32 = 0.116_955_56;
pub const TAIL_AXLE_LONGITUDINAL: f32 = -0.243_409;
pub const TAIL_CONTACT_LONGITUDINAL: f32 = -0.447_814_94;
pub const TAIL_CONTACT_REST_HEIGHT: f32 = 0.116_284_18;

/// Settled one-push stop rates measured from the authorized retail fixtures.
pub const TAIL_DECK_DRAG_DECELERATION: f32 = 3.10;
pub const NOSE_DECK_DRAG_DECELERATION: f32 = 2.90;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeckEnd {
    Tail,
    Nose,
}

impl DeckEnd {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Tail => "tail",
            Self::Nose => "nose",
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ManualDeckContact {
    pub end: Option<DeckEnd>,
    pub pitch_radians: f32,
    pub endpoint_height: f32,
    pub touching: bool,
    pub drag_deceleration: f32,
    pub speed_loss: f32,
}

pub fn contact_pitch_limit(kind: ManualKind) -> f32 {
    match kind {
        ManualKind::Tail => -(TAIL_CONTACT_REST_HEIGHT
            / (TAIL_AXLE_LONGITUDINAL - TAIL_CONTACT_LONGITUDINAL))
            .atan(),
        ManualKind::Nose => {
            (NOSE_CONTACT_REST_HEIGHT / (NOSE_CONTACT_LONGITUDINAL - NOSE_AXLE_LONGITUDINAL)).atan()
        }
    }
}

pub fn project_manual_deck(kind: ManualKind, manual: f32) -> ManualDeckContact {
    let end = match kind {
        ManualKind::Tail => DeckEnd::Tail,
        ManualKind::Nose => DeckEnd::Nose,
    };
    let signed_amount = match kind {
        ManualKind::Tail => manual.min(0.0).abs(),
        ManualKind::Nose => manual.max(0.0),
    }
    .clamp(0.0, 1.0);
    let pitch_radians = contact_pitch_limit(kind) * signed_amount;
    let (axle, endpoint, rest_height, drag_deceleration) = match kind {
        ManualKind::Tail => (
            TAIL_AXLE_LONGITUDINAL,
            TAIL_CONTACT_LONGITUDINAL,
            TAIL_CONTACT_REST_HEIGHT,
            TAIL_DECK_DRAG_DECELERATION,
        ),
        ManualKind::Nose => (
            NOSE_AXLE_LONGITUDINAL,
            NOSE_CONTACT_LONGITUDINAL,
            NOSE_CONTACT_REST_HEIGHT,
            NOSE_DECK_DRAG_DECELERATION,
        ),
    };
    let longitudinal_from_pivot = endpoint - axle;
    let endpoint_height =
        rest_height * pitch_radians.cos() - longitudinal_from_pivot * pitch_radians.sin();
    // At full analog deflection the analytically-derived contact height is
    // zero; the epsilon only absorbs f32 transcendental rounding.
    let touching = signed_amount >= 1.0 && endpoint_height <= 1.0e-6;
    ManualDeckContact {
        end: Some(end),
        pitch_radians,
        endpoint_height: endpoint_height.max(0.0),
        touching,
        drag_deceleration: touching.then_some(drag_deceleration).unwrap_or(0.0),
        speed_loss: 0.0,
    }
}

/// Apply continuous deck drag without changing travel direction or velocity
/// sign. Wheel rolling, touchdown, and powerslide response remain separate.
pub fn apply_manual_deck_drag(
    velocity: Vec3,
    delta_seconds: f32,
    contact: &mut ManualDeckContact,
) -> Vec3 {
    if !contact.touching
        || !delta_seconds.is_finite()
        || delta_seconds <= 0.0
        || contact.drag_deceleration <= 0.0
    {
        contact.speed_loss = 0.0;
        return velocity;
    }
    let planar = Vec2::new(velocity.x, velocity.z);
    let speed = planar.length();
    if speed <= f32::EPSILON {
        contact.speed_loss = 0.0;
        return velocity;
    }
    let next_speed = (speed - contact.drag_deceleration * delta_seconds).max(0.0);
    contact.speed_loss = speed - next_speed;
    let scale = next_speed / speed;
    Vec3::new(velocity.x * scale, velocity.y, velocity.z * scale)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoded_geometry_mirrors_tail_and_nose_contact_limits() {
        let tail = contact_pitch_limit(ManualKind::Tail);
        let nose = contact_pitch_limit(ManualKind::Nose);
        assert!((tail.to_degrees() + 29.635_047).abs() < 0.000_01);
        assert!((nose.to_degrees() - 30.014_639).abs() < 0.000_01);
    }

    #[test]
    fn analog_amount_controls_pitch_and_does_not_fake_contact() {
        let shallow = project_manual_deck(ManualKind::Tail, -0.55);
        let steep = project_manual_deck(ManualKind::Tail, -0.9);
        assert!(shallow.pitch_radians.abs() < steep.pitch_radians.abs());
        assert!(steep.endpoint_height < shallow.endpoint_height);
        assert!(!shallow.touching);
        assert!(!steep.touching);
    }

    #[test]
    fn full_deflection_reaches_only_the_matching_deck_end() {
        let tail = project_manual_deck(ManualKind::Tail, -1.0);
        let nose = project_manual_deck(ManualKind::Nose, 1.0);
        assert_eq!(tail.end, Some(DeckEnd::Tail));
        assert_eq!(nose.end, Some(DeckEnd::Nose));
        assert!(tail.touching);
        assert!(nose.touching);
        assert!(tail.endpoint_height <= 1.0e-6);
        assert!(nose.endpoint_height <= 1.0e-6);
    }

    #[test]
    fn drag_is_contact_gated_continuous_and_sign_preserving() {
        let original = Vec3::new(-1.5, 0.0, -2.0);
        let mut no_contact = project_manual_deck(ManualKind::Tail, -0.99);
        assert_eq!(
            apply_manual_deck_drag(original, 1.0 / 120.0, &mut no_contact),
            original
        );

        let mut contact = project_manual_deck(ManualKind::Tail, -1.0);
        let next = apply_manual_deck_drag(original, 1.0 / 120.0, &mut contact);
        assert!(next.length() < original.length());
        assert_eq!(next.x.signum(), original.x.signum());
        assert_eq!(next.z.signum(), original.z.signum());
        assert_eq!(next.y, original.y);
        assert!((contact.speed_loss - TAIL_DECK_DRAG_DECELERATION / 120.0).abs() < 1.0e-6);
    }

    #[test]
    fn drag_is_frame_partition_invariant_until_stop() {
        let initial = Vec3::new(1.2, 0.0, -4.8);
        let mut one = project_manual_deck(ManualKind::Nose, 1.0);
        let one_step = apply_manual_deck_drag(initial, 0.2, &mut one);

        let mut partitioned = initial;
        for _ in 0..24 {
            let mut contact = project_manual_deck(ManualKind::Nose, 1.0);
            partitioned = apply_manual_deck_drag(partitioned, 1.0 / 120.0, &mut contact);
        }
        assert!((one_step - partitioned).length() < 1.0e-5);
    }
}
