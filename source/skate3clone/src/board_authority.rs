/// Skate 3 explicitly changes which subsystem owns the skateboard transform
/// across the ground/trick/air/landing graph. Keeping this as state prevents
/// animation, trick physics, and wheel contact from all writing the board in
/// the same fixed tick.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[allow(dead_code)] // Non-physics variants become live with the first trick graph slice.
pub enum BoardAuthority {
    /// Retail `FORCE_PHYSICS_SKATEBOARD`: ground riding and landing.
    #[default]
    Physics,
    /// Retail `FOLLOW_ANIMATION_DATA`: takeoff after wheel lift.
    FollowAnimationData,
    /// Retail `FORCE_ANIM_SKATEBOARD`: established airborne state.
    Animation,
}

impl BoardAuthority {
    pub const fn label(self) -> &'static str {
        match self {
            Self::Physics => "physics",
            Self::FollowAnimationData => "follow_animation_data",
            Self::Animation => "animation",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ground_riding_defaults_to_physics_authority() {
        assert_eq!(BoardAuthority::default(), BoardAuthority::Physics);
        assert_eq!(BoardAuthority::default().label(), "physics");
    }
}
