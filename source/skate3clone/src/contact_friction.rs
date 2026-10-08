//! Contact-gated planar velocity response for the retail skateboard.
//!
//! The TU3 evidence separates three mechanisms:
//!
//! - `SkateboardBody::UpdatePostPhysics` publishes wheel/deck contact state;
//! - normal wheel contact removes board-local side slip while
//!   `PostPhysics_AdjustHeading` adjusts the board transform separately; and
//! - `ToolKit_CalcSlideFriction` is a distinct powerslide force path.
//!
//! No independent touchdown impulse or deck-only scrape coefficient has been
//! recovered. This module therefore exposes those states in telemetry without
//! inventing either force.

use bevy::prelude::*;

use crate::retail_skateboard::{
    LocalVelocity, PlanarForceResult, integrate_flat_ground, local_velocity,
};

pub const RETAIL_WHEEL_COUNT: u8 = 4;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BoardContactState {
    pub touching_wheels: u8,
    pub deck_touching: bool,
    pub surface_id: Option<u32>,
}

impl BoardContactState {
    pub const fn airborne() -> Self {
        Self {
            touching_wheels: 0,
            deck_touching: false,
            surface_id: None,
        }
    }

    pub const fn four_wheels(surface_id: Option<u32>) -> Self {
        Self {
            touching_wheels: RETAIL_WHEEL_COUNT,
            deck_touching: false,
            surface_id,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ContactFrictionPath {
    #[default]
    Airborne,
    DeckOnlyUnresolved,
    RollingWheelSideSlip,
    Powerslide,
}

impl ContactFrictionPath {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Airborne => "airborne",
            Self::DeckOnlyUnresolved => "deck_only_unresolved",
            Self::RollingWheelSideSlip => "rolling_wheel_side_slip",
            Self::Powerslide => "powerslide",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ContactFrictionInput {
    pub velocity: Vec3,
    pub board_yaw: f32,
    pub fixed_delta_seconds: f32,
    pub contact: BoardContactState,
    pub touchdown_this_step: bool,
    pub powersliding: bool,
    pub braking: bool,
    pub maximum_speed: f32,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct ContactFrictionOutput {
    pub velocity: Vec3,
    pub acceleration: Vec3,
    pub path: ContactFrictionPath,
    pub contact: BoardContactState,
    pub touchdown_this_step: bool,
    /// Kept explicit because no separate TU3 touchdown impulse is recovered.
    pub one_shot_velocity_delta: Vec3,
    pub continuous_velocity_delta: Vec3,
    pub local_before: LocalVelocity,
    pub local_after: LocalVelocity,
    pub speed_loss: f32,
    pub lateral_rate: f32,
    pub rolling_deceleration: f32,
    pub brake_deceleration: f32,
}

pub fn integrate_contact_friction(input: ContactFrictionInput) -> ContactFrictionOutput {
    debug_assert!(input.contact.touching_wheels <= RETAIL_WHEEL_COUNT);
    let horizontal = Vec3::new(input.velocity.x, 0.0, input.velocity.z);
    let local_before = local_velocity(horizontal, input.board_yaw);

    let path = if input.contact.touching_wheels == 0 {
        if input.contact.deck_touching {
            ContactFrictionPath::DeckOnlyUnresolved
        } else {
            ContactFrictionPath::Airborne
        }
    } else if input.powersliding {
        ContactFrictionPath::Powerslide
    } else {
        ContactFrictionPath::RollingWheelSideSlip
    };

    let planar = match path {
        ContactFrictionPath::RollingWheelSideSlip | ContactFrictionPath::Powerslide => {
            integrate_flat_ground(
                horizontal,
                input.board_yaw,
                input.fixed_delta_seconds,
                input.powersliding,
                input.braking,
                input.maximum_speed,
            )
        }
        ContactFrictionPath::Airborne | ContactFrictionPath::DeckOnlyUnresolved => {
            PlanarForceResult {
                velocity: horizontal,
                local_before,
                ..default()
            }
        }
    };
    let local_after = local_velocity(planar.velocity, input.board_yaw);

    ContactFrictionOutput {
        velocity: Vec3::new(planar.velocity.x, input.velocity.y, planar.velocity.z),
        acceleration: planar.acceleration,
        path,
        contact: input.contact,
        touchdown_this_step: input.touchdown_this_step,
        one_shot_velocity_delta: Vec3::ZERO,
        continuous_velocity_delta: planar.velocity - horizontal,
        local_before,
        local_after,
        speed_loss: (local_before.speed - local_after.speed).max(0.0),
        lateral_rate: planar.lateral_rate,
        rolling_deceleration: planar.rolling_deceleration,
        brake_deceleration: planar.brake_deceleration,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 120.0;

    fn input(velocity: Vec3, yaw: f32, contact: BoardContactState) -> ContactFrictionInput {
        ContactFrictionInput {
            velocity,
            board_yaw: yaw,
            fixed_delta_seconds: DT,
            contact,
            touchdown_this_step: false,
            powersliding: false,
            braking: false,
            maximum_speed: 12.5,
        }
    }

    #[test]
    fn airborne_and_deck_only_states_do_not_invent_wheel_friction() {
        let velocity = Vec3::new(3.0, -2.0, 5.0);
        let airborne =
            integrate_contact_friction(input(velocity, 0.0, BoardContactState::airborne()));
        let deck = integrate_contact_friction(input(
            velocity,
            0.0,
            BoardContactState {
                touching_wheels: 0,
                deck_touching: true,
                surface_id: Some(7),
            },
        ));

        assert_eq!(airborne.path, ContactFrictionPath::Airborne);
        assert_eq!(deck.path, ContactFrictionPath::DeckOnlyUnresolved);
        assert_eq!(airborne.velocity, velocity);
        assert_eq!(deck.velocity, velocity);
    }

    #[test]
    fn touchdown_has_no_unrecovered_one_shot_impulse() {
        let velocity = Vec3::new(3.0, -2.0, 5.196_152);
        let mut touchdown_input = input(velocity, 0.0, BoardContactState::four_wheels(Some(1)));
        touchdown_input.touchdown_this_step = true;
        let touchdown = integrate_contact_friction(touchdown_input);
        touchdown_input.touchdown_this_step = false;
        let continuing = integrate_contact_friction(touchdown_input);

        assert_eq!(touchdown.one_shot_velocity_delta, Vec3::ZERO);
        assert_eq!(touchdown.velocity, continuing.velocity);
        assert_eq!(
            touchdown.continuous_velocity_delta,
            continuing.continuous_velocity_delta
        );
    }

    #[test]
    fn rolling_contact_removes_lateral_energy_without_changing_its_sign() {
        let result = integrate_contact_friction(input(
            Vec3::new(3.0, 0.0, 5.196_152),
            0.0,
            BoardContactState::four_wheels(Some(1)),
        ));

        assert_eq!(result.path, ContactFrictionPath::RollingWheelSideSlip);
        assert!(result.local_after.lateral > 0.0);
        assert!(result.local_after.lateral < result.local_before.lateral);
        assert!((result.local_after.longitudinal - result.local_before.longitudinal).abs() < 0.001);
        assert!(result.speed_loss > 0.0);
        assert!(result.continuous_velocity_delta.dot(Vec3::X) < 0.0);
    }

    #[test]
    fn settled_speed_follows_the_preserved_longitudinal_component() {
        let angle = 45.0_f32.to_radians();
        let initial_speed = 6.0;
        let mut velocity = Vec3::new(
            angle.sin() * initial_speed,
            0.0,
            angle.cos() * initial_speed,
        );
        for _ in 0..120 {
            velocity = integrate_contact_friction(input(
                velocity,
                0.0,
                BoardContactState::four_wheels(Some(1)),
            ))
            .velocity;
        }

        let expected_longitudinal =
            initial_speed * angle.cos() - crate::retail_skateboard::CAPTURED_ROLLING_DECELERATION;
        assert!((velocity.length() - expected_longitudinal).abs() < 0.002);
        assert!(velocity.x.abs() < 1.0e-6);
    }

    #[test]
    fn powerslide_stays_on_the_dedicated_slide_path() {
        let mut powerslide_input = input(
            Vec3::new(3.0, 0.0, 5.0),
            0.0,
            BoardContactState::four_wheels(Some(1)),
        );
        powerslide_input.powersliding = true;
        let result = integrate_contact_friction(powerslide_input);

        assert_eq!(result.path, ContactFrictionPath::Powerslide);
        assert!(result.lateral_rate != crate::retail_skateboard::NORMAL_CONTACT_LATERAL_RATE);
    }
}
