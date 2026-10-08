//! Standalone TU3 skateboard-body topology and post-physics state.
//!
//! This module deliberately contains no solver and no integration hooks.  It
//! records the topology and aggregation semantics observed in the TU3 Xbox 360
//! executable.  Physical values that have not been recovered are represented
//! by [`Required`] rather than populated with tuned guesses.
#![allow(dead_code)]

#[path = "retail_collision.rs"]
pub mod retail_collision;
#[path = "retail_contact.rs"]
pub mod retail_contact;
#[path = "retail_contact_solver.rs"]
pub mod retail_contact_solver;
#[path = "retail_drive_frames.rs"]
pub mod retail_drive_frames;
#[path = "retail_drive_solver.rs"]
pub mod retail_drive_solver;
#[path = "retail_ground_filter.rs"]
pub mod retail_ground_filter;
#[path = "retail_joint_builder.rs"]
pub mod retail_joint_builder;
#[path = "retail_joint_records.rs"]
pub mod retail_joint_records;
#[path = "retail_joint_solver.rs"]
pub mod retail_joint_solver;
#[path = "retail_pumping.rs"]
pub mod retail_pumping;
#[path = "retail_rigid_body.rs"]
pub mod retail_rigid_body;
#[path = "retail_transition_profiles.rs"]
pub mod retail_transition_profiles;
#[cfg(test)]
#[path = "transition_test_terrain.rs"]
pub mod transition_test_terrain;

pub const BODY_COUNT: usize = 7;
pub const WHEEL_COUNT: usize = 4;
pub const TRUCK_COUNT: usize = 2;
pub const DRIVE_COUNT: usize = 6;

pub const AXLE_AVERAGE_WEIGHT: f32 = 0.5;
pub const FOUR_WHEEL_AVERAGE_WEIGHT: f32 = 0.25;

const fn retail_f32(bits: u32) -> f32 {
    f32::from_bits(bits)
}

/// TU3 virtual addresses and object-layout facts used by this module.
pub mod tu3 {
    pub const UPDATE_POST_PHYSICS: u32 = 0x82C0_7D20;
    pub const CALCULATE_AVERAGE_WHEEL_COMPRESSIONS: u32 = 0x82C0_8968;
    pub const CREATE_TRIANGLE_DECK: u32 = 0x82C0_9290;
    pub const CREATE_TRUCKS: u32 = 0x82C0_A6F8;
    pub const CREATE_WHEELS: u32 = 0x82C0_AA78;
    pub const CREATE_DRIVES: u32 = 0x82C0_B770;
    pub const SET_TRUCK_DRIVE_FRAMES: u32 = 0x82C0_B9C0;
    pub const CALCULATE_TRUCK_TRANSFORMS: u32 = 0x82C0_BC90;
    pub const SET_DRIVE_FRAMES_2: u32 = 0x82C0_C088;
    pub const CREATE_JOINTS: u32 = 0x82C0_C268;
    pub const CREATE_WHEEL_DRIVES: u32 = 0x82C0_CF60;
    pub const ADD_DRIVE: u32 = 0x82AE_64F8;
    pub const DRIVEN_PAIR_INITIALIZE: u32 = 0x82AE_6A98;
    pub const MATRIX_TO_DRIVE_FRAME_A: u32 = 0x82BD_3A10;
    pub const MATRIX_TO_DRIVE_FRAME_B: u32 = 0x82BD_3BD0;
    pub const XM_VECTOR_SIN: u32 = 0x8245_31C8;
    pub const XM_VECTOR_COS: u32 = 0x8247_3930;

    pub const PART_TRANSFORM_STRIDE: usize = 0x60;
    pub const TRUCK_DRIVE_FRAME_STRIDE: usize = 0x40;
    pub const WHEEL_DRIVE_FRAME_STRIDE: usize = 0x40;

    pub const FRONT_COMPRESSION_OFFSET: usize = 0x20B4;
    pub const BACK_COMPRESSION_OFFSET: usize = 0x20B8;
    pub const COMPRESSION_REFERENCE_OFFSET: usize = 0x20BC;

    pub const FRONT_TRUCK_FRAME_OFFSET: usize = 0x1A70;
    pub const BACK_TRUCK_FRAME_OFFSET: usize = 0x1AB0;
    pub const WHEEL_DRIVE_FRAME_OFFSETS: [usize; 4] = [0x1CB0, 0x1CF0, 0x1D30, 0x1D70];
    /// Base transform for the truck grouped with wheel bodies 0 and 1.
    pub const TRUCK_GROUP_A_TRANSFORM_OFFSET: usize = 0x1E60;
    /// Base transform for the truck grouped with wheel bodies 2 and 3.
    pub const TRUCK_GROUP_B_TRANSFORM_OFFSET: usize = 0x1E20;

    pub const HALF_CONSTANT_ADDRESS: u32 = 0x8209_975C;
    pub const HALF_CONSTANT: f32 = 0.5;
    pub const DECK_ROOT_RADIUS_SCALAR_ADDRESS: u32 = 0x8209_97B8;
    pub const DECK_ROOT_RADIUS_SCALAR: f32 = 0.9;
    pub const DECK_FIXED_SPHERE_RADIUS_ADDRESS: u32 = 0x820C_2078;
    pub const DECK_FIXED_SPHERE_VERTICAL_ADDRESS: u32 = 0x8216_59F8;
    pub const DECK_FIXED_SPHERE_FRONT_ADDRESS: u32 = 0x820C_6D9C;
    pub const DECK_FIXED_SPHERE_BACK_ADDRESS: u32 = 0x822F_9468;
    pub const DEGREES_TO_RADIANS_ADDRESS: u32 = 0x8206_D110;
    pub const NEGATIVE_PI_ADDRESS: u32 = 0x822F_8908;
    pub const POSITIVE_PI_ADDRESS: u32 = 0x8206_0C44;
}

/// Exact `physics/default` values decoded from the TU3 attribute database.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailPhysicsDefaults {
    pub world_gravity: Vector3,
    pub triangle_edge_culling_tolerance: f32,
    pub simulation_padding: f32,
    pub maximum_solver_iterations: u32,
    pub physics_update_frequency: u32,
    pub mass_factor: f32,
    pub floor_static_friction: f32,
    pub floor_restitution: f32,
}

pub const RETAIL_PHYSICS_DEFAULTS: RetailPhysicsDefaults = RetailPhysicsDefaults {
    world_gravity: Vector3::new(0.0, retail_f32(0xC11C_CCCD), 0.0),
    triangle_edge_culling_tolerance: retail_f32(0x3F80_0000),
    simulation_padding: retail_f32(0x3DCC_CCCD),
    maximum_solver_iterations: 25,
    physics_update_frequency: 1,
    mass_factor: retail_f32(0x3F80_0000),
    floor_static_friction: retail_f32(0x3F00_0000),
    floor_restitution: 0.0,
};

/// Exact 28-byte `physics_speed_conservation/default` layout.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct SpeedConservationDefaults {
    pub negative_general_amount: f32,
    pub minimum_speed: f32,
    pub maximum_gravity_acceleration: f32,
    pub maximum_friction_acceleration: f32,
    pub gravity: f32,
    pub general_amount: f32,
    pub coffin_acceleration: f32,
}

pub const RETAIL_SPEED_CONSERVATION_DEFAULTS: SpeedConservationDefaults =
    SpeedConservationDefaults {
        negative_general_amount: retail_f32(0x3E80_0000),
        minimum_speed: retail_f32(0x4000_0000),
        maximum_gravity_acceleration: retail_f32(0x40E0_0000),
        maximum_friction_acceleration: retail_f32(0x3F99_999A),
        gravity: retail_f32(0x411C_CCCD),
        general_amount: retail_f32(0x3E80_0000),
        coffin_acceleration: retail_f32(0xBECC_CCCD),
    };

/// `ProcessedPhysIn +2604` is initialized to this exact constant by
/// `0x82BF9EF0`.
pub const RETAIL_PROCESSED_PHYSICS_DELTA_SECONDS: f32 = retail_f32(0x3C88_8889);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicalMaterial {
    pub static_friction: f32,
    pub dynamic_friction: f32,
    pub restitution: f32,
}

/// Raw mass attributes before `physics_world/default.SkateboardMassFactor`.
pub const RETAIL_DECK_ATTRIBUTE_MASS: f32 = retail_f32(0x3F99_999A);
pub const RETAIL_TRUCK_ATTRIBUTE_MASS: f32 = retail_f32(0x3EC7_AE14);
pub const RETAIL_WHEEL_ATTRIBUTE_MASS: f32 = retail_f32(0x3DA9_FBE7);
pub const RETAIL_SKATEBOARD_MASS_FACTOR: f32 = retail_f32(0x40A0_0000);

/// Physical masses passed to RenderWare by the three board-body creators.
pub const RETAIL_DECK_MASS: f32 = RETAIL_DECK_ATTRIBUTE_MASS * RETAIL_SKATEBOARD_MASS_FACTOR;
pub const RETAIL_TRUCK_MASS: f32 = RETAIL_TRUCK_ATTRIBUTE_MASS * RETAIL_SKATEBOARD_MASS_FACTOR;
pub const RETAIL_WHEEL_MASS: f32 = RETAIL_WHEEL_ATTRIBUTE_MASS * RETAIL_SKATEBOARD_MASS_FACTOR;
pub const RETAIL_WHEEL_RADIUS: f32 = retail_f32(0x3CFD_F3B6);
pub const RETAIL_WHEEL_LATERAL_DISTANCE: f32 = retail_f32(0x3DC2_8F5C);
pub const RETAIL_TRUCK_RADIUS_SCALAR: f32 = retail_f32(0x3F09_999A);
pub const RETAIL_TRUCK_HALF_HEIGHT_SCALAR: f32 = retail_f32(0x3FAC_CCCD);
pub const RETAIL_TRUCK_Z_POSITION_FRONT: f32 = retail_f32(0xBD54_FDF4);
pub const RETAIL_TRUCK_Z_POSITION_BACK: f32 = retail_f32(0xBD54_FDF4);
pub const RETAIL_TRUCK_Y_POSITION: f32 = retail_f32(0xBD67_6C8B);
pub const RETAIL_TRUCK_ROTATION_AXIS_ANGLE_DEGREES: f32 = retail_f32(0x41F8_0000);
pub const RETAIL_TRUCK_CAPSULE_RADIUS: f32 =
    RETAIL_WHEEL_RADIUS * RETAIL_TRUCK_RADIUS_SCALAR * tu3::HALF_CONSTANT;
pub const RETAIL_TRUCK_CAPSULE_HALF_HEIGHT: f32 =
    RETAIL_WHEEL_LATERAL_DISTANCE * RETAIL_TRUCK_HALF_HEIGHT_SCALAR * tu3::HALF_CONSTANT;
pub const RETAIL_TRUCK_TWIST_ANGLE_DEGREES: f32 = retail_f32(0x4160_0000);
pub const RETAIL_TRUCK_TWIST_LIMIT_DEGREES: f32 = retail_f32(0x42AC_3333);

/// `physicsdeck/default` fields and executable constants consumed by
/// `SkateboardBody::CreateTriangleDeck`.
///
/// TU3 reads `DeckEndCapsules` as the end tessellation count. The separate
/// `DeckEndTriangles` database field is not read by this function.
pub const RETAIL_DECK_WIDTH: f32 = retail_f32(0x3E75_C28F);
pub const RETAIL_DECK_MID_LENGTH: f32 = retail_f32(0x3F17_0A3D);
pub const RETAIL_DECK_THICKNESS: f32 = retail_f32(0x3C75_C28F);
pub const RETAIL_DECK_BACK_END_SIZE: f32 = retail_f32(0x3E28_F5C3);
pub const RETAIL_DECK_FRONT_END_ANGLE_DEGREES: f32 = retail_f32(0x4150_0000);
pub const RETAIL_DECK_BACK_END_ANGLE_DEGREES: f32 = retail_f32(0x4148_0000);
pub const RETAIL_DECK_FORCE_Y_OFFSET: f32 = retail_f32(0x3D4C_CCCD);
pub const RETAIL_DECK_END_TESSELLATION: usize = 5;
pub const RETAIL_DECK_VOLUME_SLOT_COUNT: usize = 15;
pub const RETAIL_DECK_END_TRIANGLE_COUNT: usize = RETAIL_DECK_END_TESSELLATION * 2;
pub const RETAIL_DECK_HALF_WIDTH: f32 = retail_f32(0x3DF5_C28F);
pub const RETAIL_DECK_HALF_MID_LENGTH: f32 = retail_f32(0x3E97_0A3D);
pub const RETAIL_DECK_HALF_THICKNESS: f32 = retail_f32(0x3BF5_C28F);
pub const RETAIL_DECK_ROOT_RADIUS: f32 = retail_f32(0x3BDD_2F1A);
pub const RETAIL_DECK_ROOT_HALF_EXTENTS: Vector3 = Vector3::new(
    retail_f32(0x3DE7_EF9D),
    retail_f32(0x3A44_9BA8),
    retail_f32(0x3E93_9581),
);
pub const RETAIL_DECK_SIDE_CAPSULE_LATERAL: f32 = retail_f32(0x3DE6_6666);
pub const RETAIL_DECK_FIXED_SPHERE_RADIUS: f32 = retail_f32(0x3D0F_5C29);
pub const RETAIL_DECK_FIXED_SPHERE_VERTICAL: f32 = retail_f32(0xBCA3_D70A);
pub const RETAIL_DECK_FIXED_SPHERE_LONGITUDINAL: f32 = retail_f32(0x3E70_A3D7);

const fn retail_vector3(x: u32, y: u32, z: u32) -> Vector3 {
    Vector3::new(retail_f32(x), retail_f32(y), retail_f32(z))
}

pub const RETAIL_DECK_MATERIAL: PhysicalMaterial = PhysicalMaterial {
    static_friction: retail_f32(0x3DCC_CCCD),
    dynamic_friction: retail_f32(0x3DCC_CCCD),
    restitution: 0.0,
};
pub const RETAIL_TRUCK_MATERIAL: PhysicalMaterial = PhysicalMaterial {
    static_friction: retail_f32(0x3F66_6666),
    dynamic_friction: 0.0,
    restitution: 0.0,
};
pub const RETAIL_WHEEL_MATERIAL: PhysicalMaterial = PhysicalMaterial {
    static_friction: retail_f32(0x3F4C_CCCD),
    dynamic_friction: retail_f32(0x3F33_3333),
    restitution: 0.0,
};

/// Named scalar fields from one `physics_surfaces` collection.
///
/// The point graphs are deliberately not represented as scalar tuning. Their
/// complete 80-byte records and evaluator remain separate evidence work.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailSurfaceScalars {
    pub wheel_static_friction: f32,
    pub wheel_dynamic_friction: f32,
    pub friction_maximum_speed_change: f32,
    pub braking_scalar: f32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RetailSurfaceCollection {
    Default,
    Rough,
    Slippery,
    Slow,
    Smooth,
    VerySlow,
}

impl RetailSurfaceCollection {
    pub const fn scalars(self) -> RetailSurfaceScalars {
        match self {
            Self::Default => RetailSurfaceScalars {
                wheel_static_friction: 0.0,
                wheel_dynamic_friction: 0.0,
                friction_maximum_speed_change: 0.0,
                braking_scalar: 0.0,
            },
            Self::Rough => RetailSurfaceScalars {
                wheel_static_friction: retail_f32(0x3F59_999A),
                wheel_dynamic_friction: retail_f32(0x3F40_0000),
                friction_maximum_speed_change: retail_f32(0x3E4C_CCCD),
                braking_scalar: retail_f32(0x3F99_999A),
            },
            Self::Slippery => RetailSurfaceScalars {
                wheel_static_friction: retail_f32(0x3F33_3333),
                wheel_dynamic_friction: retail_f32(0x3F00_0000),
                friction_maximum_speed_change: retail_f32(0x3F33_3333),
                braking_scalar: retail_f32(0x3F00_0000),
            },
            Self::Slow => RetailSurfaceScalars {
                wheel_static_friction: retail_f32(0x3F66_6666),
                wheel_dynamic_friction: retail_f32(0x3F4C_CCCD),
                friction_maximum_speed_change: retail_f32(0x3DCC_CCCD),
                braking_scalar: retail_f32(0x4000_0000),
            },
            Self::Smooth => RetailSurfaceScalars {
                wheel_static_friction: retail_f32(0x3F4C_CCCD),
                wheel_dynamic_friction: retail_f32(0x3F33_3333),
                friction_maximum_speed_change: retail_f32(0x3E99_999A),
                braking_scalar: retail_f32(0x3F80_0000),
            },
            Self::VerySlow => RetailSurfaceScalars {
                wheel_static_friction: retail_f32(0x3F80_0000),
                wheel_dynamic_friction: retail_f32(0x3F7D_70A4),
                friction_maximum_speed_change: retail_f32(0x3ECC_CCCD),
                braking_scalar: retail_f32(0x4000_0000),
            },
        }
    }
}

/// RenderWare `rw::physics::DriveType` recovered from EA's SDK DWARF and
/// confirmed by the Skate 3 TU3 `DriveJacobian::Build` branches.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u32)]
pub enum RetailDriveType {
    NoDrive = 0,
    SoftDrive = 1,
    HardDrive = 2,
}

/// Exact 16-byte `rw::physics::DriveDynamics::Params` layout.
///
/// RenderWare exposes the first scalar through both `GetSpring` and
/// `GetMaxVelocity`: it is spring for `SoftDrive` and maximum correction
/// velocity for `HardDrive`. The TU3 Jacobian builder consumes `damping` and
/// `max_strength` for both modes. Units remain retail-solver units.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct RetailDriveParams {
    pub spring_or_max_velocity: f32,
    pub damping: f32,
    pub max_strength: f32,
    pub drive_type: RetailDriveType,
}

/// Exact 32-byte `rw::physics::DriveDynamics` layout: linear parameters,
/// followed by angular parameters.
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct RetailDriveDynamics {
    pub linear: RetailDriveParams,
    pub angular: RetailDriveParams,
}

pub fn retail_truck_drive_dynamics(
    use_soft_drives: bool,
    truck_twist_angle: f32,
    truck_static_friction: f32,
    truck_twist_limit: f32,
) -> RetailDriveDynamics {
    let linear = if use_soft_drives {
        RetailDriveParams {
            spring_or_max_velocity: retail_f32(0x45BB_7FFF),
            damping: 0.0,
            max_strength: retail_f32(0x48AF_C7FF),
            drive_type: RetailDriveType::HardDrive,
        }
    } else {
        RetailDriveParams {
            spring_or_max_velocity: retail_f32(0x47C3_5000),
            damping: retail_f32(0x3ACC_CCCD),
            max_strength: retail_f32(0x48AF_C7FF),
            drive_type: RetailDriveType::SoftDrive,
        }
    };
    RetailDriveDynamics {
        linear,
        angular: RetailDriveParams {
            spring_or_max_velocity: truck_twist_angle * retail_f32(0x426F_FFFF),
            damping: truck_static_friction,
            max_strength: truck_twist_limit * retail_f32(0x4560_FFFE),
            drive_type: RetailDriveType::HardDrive,
        },
    }
}

/// Exact wheel-drive dynamics consumed by `DrivenPair::Initialize`.
///
/// `SkateboardBody` construction (`0x82C06298`) clears all eight words.
/// `CreateWheelDrives` (`0x82C0CF60`) then overwrites only the first four;
/// `DrivenPair::Initialize` (`0x82AE6A98`) copies the complete 32-byte record.
/// The branch key is `physicsdeck.UseHardDrives`, not the similarly named
/// `physicswheels.UseWheelDrives`.
pub const fn retail_wheel_drive_dynamics(use_hard_drives: bool) -> RetailDriveDynamics {
    if use_hard_drives {
        RetailDriveDynamics {
            linear: RetailDriveParams {
                spring_or_max_velocity: retail_f32(0x45BB_7FFF),
                damping: 0.0,
                max_strength: retail_f32(0x48AF_C7FF),
                drive_type: RetailDriveType::HardDrive,
            },
            angular: RetailDriveParams {
                spring_or_max_velocity: 0.0,
                damping: 0.0,
                max_strength: 0.0,
                drive_type: RetailDriveType::NoDrive,
            },
        }
    } else {
        RetailDriveDynamics {
            linear: RetailDriveParams {
                spring_or_max_velocity: retail_f32(0x4561_0000),
                damping: retail_f32(0x4270_0000),
                max_strength: retail_f32(0x470C_9FFF),
                drive_type: RetailDriveType::SoftDrive,
            },
            angular: RetailDriveParams {
                spring_or_max_velocity: 0.0,
                damping: 0.0,
                max_strength: 0.0,
                drive_type: RetailDriveType::NoDrive,
            },
        }
    }
}

/// Body indices passed to the six observed `Simulation::AddDrive` calls and
/// used by the body-transform array.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum BodyId {
    RightFrontWheel = 0,
    LeftFrontWheel = 1,
    RightBackWheel = 2,
    LeftBackWheel = 3,
    FrontTruck = 4,
    BackTruck = 5,
    Deck = 6,
}

impl BodyId {
    pub const ORDER: [Self; BODY_COUNT] = [
        Self::RightFrontWheel,
        Self::LeftFrontWheel,
        Self::RightBackWheel,
        Self::LeftBackWheel,
        Self::FrontTruck,
        Self::BackTruck,
        Self::Deck,
    ];

    pub const fn index(self) -> usize {
        self as usize
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
#[repr(u8)]
pub enum WheelId {
    RightFront = 0,
    LeftFront = 1,
    RightBack = 2,
    LeftBack = 3,
}

impl WheelId {
    pub const ORDER: [Self; WHEEL_COUNT] = [
        Self::RightFront,
        Self::LeftFront,
        Self::RightBack,
        Self::LeftBack,
    ];

    pub const fn index(self) -> usize {
        self as usize
    }

    pub const fn body(self) -> BodyId {
        match self {
            Self::RightFront => BodyId::RightFrontWheel,
            Self::LeftFront => BodyId::LeftFrontWheel,
            Self::RightBack => BodyId::RightBackWheel,
            Self::LeftBack => BodyId::LeftBackWheel,
        }
    }

    pub const fn truck(self) -> BodyId {
        match self {
            Self::RightFront | Self::LeftFront => BodyId::FrontTruck,
            Self::RightBack | Self::LeftBack => BodyId::BackTruck,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShapeFamily {
    TriangleDeck,
    Truck,
    Wheel,
}

/// A physical value which must be supplied by an owning physics integration.
#[derive(Clone, Debug, PartialEq)]
pub enum Required<T> {
    Supplied(T),
    Unresolved(UnresolvedParameter),
}

impl<T> Required<T> {
    pub const fn supplied(value: T) -> Self {
        Self::Supplied(value)
    }

    pub const fn unresolved(parameter: UnresolvedParameter) -> Self {
        Self::Unresolved(parameter)
    }

    pub const fn is_unresolved(&self) -> bool {
        matches!(self, Self::Unresolved(_))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum UnresolvedParameter {
    CollisionGeometry(BodyId),
    Mass(BodyId),
    Inertia(BodyId),
    TruckBasis(BodyId),
}

#[derive(Clone, Debug, PartialEq)]
pub struct TriangleMesh {
    pub vertices: Vec<[f32; 3]>,
    pub triangles: Vec<[u32; 3]>,
}

impl TriangleMesh {
    pub fn indices_are_in_bounds(&self) -> bool {
        let vertex_count = self.vertices.len() as u32;
        self.triangles
            .iter()
            .all(|triangle| triangle.iter().all(|&index| index < vertex_count))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum CollisionGeometry {
    TriangleMesh(TriangleMesh),
    RetailDeckAggregate(RetailDeckCollisionEvidence),
    Capsule { radius: f32, half_height: f32 },
    Sphere { radius: f32 },
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailRoundedBoxVolume {
    pub slot: usize,
    pub half_extents: Vector3,
    pub radius: f32,
    pub collisions_enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailCapsuleSegmentVolume {
    pub slot: usize,
    pub endpoint_a: Vector3,
    pub endpoint_b: Vector3,
    pub radius: f32,
    pub collisions_enabled: bool,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailSphereVolume {
    pub slot: usize,
    pub center: Vector3,
    pub radius: f32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailTriangleVolume {
    pub a: Vector3,
    pub b: Vector3,
    pub c: Vector3,
}

/// Recovered default retail deck collision aggregate.
#[derive(Clone, Debug, PartialEq)]
pub struct RetailDeckCollisionEvidence {
    pub volume_slot_count: usize,
    pub rounded_box: RetailRoundedBoxVolume,
    pub side_capsules: [RetailCapsuleSegmentVolume; 2],
    pub fixed_spheres: [RetailSphereVolume; 2],
    pub end_triangle_first_slot: usize,
    pub end_triangles_per_end: usize,
    pub end_triangle_radius: f32,
    pub end_triangle_collisions_enabled: bool,
    pub end_triangles: [RetailTriangleVolume; RETAIL_DECK_END_TRIANGLE_COUNT],
}

/// Exact default end fans emitted by `CreateTriangleDeck`.
///
/// Slots alternate back/front from 5 through 14. The values preserve the
/// retail `XMVectorSin`/`XMVectorCos` polynomial and binary32 operation order,
/// including the tiny non-zero endpoint residuals at +/-pi.
pub const RETAIL_DECK_END_TRIANGLES: [RetailTriangleVolume; RETAIL_DECK_END_TRIANGLE_COUNT] = [
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0xBE97_0A3D),
        b: retail_vector3(0x3DE6_6666, 0x0000_0000, 0xBE97_0A3D),
        c: retail_vector3(0x3DBA_65C2, 0x3CA4_24F5, 0xBEC5_50C2),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0x3E97_0A3D),
        b: retail_vector3(0x3DE6_6666, 0x0000_0000, 0x3E97_0A3D),
        c: retail_vector3(0x3DBA_65C2, 0x3CAA_996C, 0x3EC5_3963),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0xBE97_0A3D),
        b: retail_vector3(0x3DBA_65C2, 0x3CA4_24F5, 0xBEC5_50C2),
        c: retail_vector3(0x3D0E_651F, 0x3D04_CBAC, 0xBEE1_EA4F),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0x3E97_0A3D),
        b: retail_vector3(0x3DBA_65C2, 0x3CAA_996C, 0x3EC5_3963),
        c: retail_vector3(0x3D0E_651F, 0x3D0A_048B, 0x3EE1_C47F),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0xBE97_0A3D),
        b: retail_vector3(0x3D0E_651F, 0x3D04_CBAC, 0xBEE1_EA4F),
        c: retail_vector3(0xBD0E_6521, 0x3D04_CBAB, 0xBEE1_EA4E),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0x3E97_0A3D),
        b: retail_vector3(0x3D0E_651F, 0x3D0A_048B, 0x3EE1_C47F),
        c: retail_vector3(0xBD0E_6521, 0x3D0A_048A, 0x3EE1_C47E),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0xBE97_0A3D),
        b: retail_vector3(0xBD0E_6521, 0x3D04_CBAB, 0xBEE1_EA4E),
        c: retail_vector3(0xBDBA_65C4, 0x3CA4_24F4, 0xBEC5_50C1),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0x3E97_0A3D),
        b: retail_vector3(0xBD0E_6521, 0x3D0A_048A, 0x3EE1_C47E),
        c: retail_vector3(0xBDBA_65C4, 0x3CAA_996B, 0x3EC5_3963),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0xBE97_0A3D),
        b: retail_vector3(0xBDBA_65C4, 0x3CA4_24F4, 0xBEC5_50C1),
        c: retail_vector3(0xBDE6_6662, 0x30C5_CCD0, 0xBE97_0A3D),
    },
    RetailTriangleVolume {
        a: retail_vector3(0x0000_0000, 0x0000_0000, 0x3E97_0A3D),
        b: retail_vector3(0xBDBA_65C4, 0x3CAA_996B, 0x3EC5_3963),
        c: retail_vector3(0xBDE6_6662, 0xB0CD_9418, 0x3E97_0A3D),
    },
];

pub fn retail_deck_collision_evidence() -> RetailDeckCollisionEvidence {
    RetailDeckCollisionEvidence {
        volume_slot_count: RETAIL_DECK_VOLUME_SLOT_COUNT,
        rounded_box: RetailRoundedBoxVolume {
            slot: 0,
            half_extents: RETAIL_DECK_ROOT_HALF_EXTENTS,
            radius: RETAIL_DECK_ROOT_RADIUS,
            collisions_enabled: true,
        },
        side_capsules: [
            RetailCapsuleSegmentVolume {
                slot: 1,
                endpoint_a: Vector3::new(
                    RETAIL_DECK_SIDE_CAPSULE_LATERAL,
                    0.0,
                    RETAIL_DECK_HALF_MID_LENGTH,
                ),
                endpoint_b: Vector3::new(
                    RETAIL_DECK_SIDE_CAPSULE_LATERAL,
                    0.0,
                    -RETAIL_DECK_HALF_MID_LENGTH,
                ),
                radius: RETAIL_DECK_HALF_THICKNESS,
                collisions_enabled: true,
            },
            RetailCapsuleSegmentVolume {
                slot: 2,
                endpoint_a: Vector3::new(
                    -RETAIL_DECK_SIDE_CAPSULE_LATERAL,
                    0.0,
                    RETAIL_DECK_HALF_MID_LENGTH,
                ),
                endpoint_b: Vector3::new(
                    -RETAIL_DECK_SIDE_CAPSULE_LATERAL,
                    0.0,
                    -RETAIL_DECK_HALF_MID_LENGTH,
                ),
                radius: RETAIL_DECK_HALF_THICKNESS,
                collisions_enabled: true,
            },
        ],
        fixed_spheres: [
            RetailSphereVolume {
                slot: 3,
                center: Vector3::new(
                    0.0,
                    RETAIL_DECK_FIXED_SPHERE_VERTICAL,
                    RETAIL_DECK_FIXED_SPHERE_LONGITUDINAL,
                ),
                radius: RETAIL_DECK_FIXED_SPHERE_RADIUS,
            },
            RetailSphereVolume {
                slot: 4,
                center: Vector3::new(
                    0.0,
                    RETAIL_DECK_FIXED_SPHERE_VERTICAL,
                    -RETAIL_DECK_FIXED_SPHERE_LONGITUDINAL,
                ),
                radius: RETAIL_DECK_FIXED_SPHERE_RADIUS,
            },
        ],
        end_triangle_first_slot: 5,
        end_triangles_per_end: RETAIL_DECK_END_TESSELLATION,
        end_triangle_radius: RETAIL_DECK_HALF_THICKNESS,
        end_triangle_collisions_enabled: true,
        end_triangles: RETAIL_DECK_END_TRIANGLES,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct InertiaTensor {
    pub xx: f32,
    pub yy: f32,
    pub zz: f32,
    pub xy: f32,
    pub xz: f32,
    pub yz: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BodyDescriptor {
    pub id: BodyId,
    pub shape_family: ShapeFamily,
    pub collision_geometry: Required<CollisionGeometry>,
    pub mass: Required<f32>,
    pub inertia: Required<InertiaTensor>,
    pub material: PhysicalMaterial,
}

impl BodyDescriptor {
    fn evidence_gated(
        id: BodyId,
        shape_family: ShapeFamily,
        collision_geometry: Required<CollisionGeometry>,
        mass: f32,
        material: PhysicalMaterial,
    ) -> Self {
        Self {
            id,
            shape_family,
            collision_geometry,
            mass: Required::supplied(mass),
            inertia: Required::unresolved(UnresolvedParameter::Inertia(id)),
            material,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Vector3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vector3 {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0);

    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }
}

impl Default for Vector3 {
    fn default() -> Self {
        Self::ZERO
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Basis3 {
    pub columns: [[f32; 3]; 3],
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BoardLocalPosition {
    pub lateral: f32,
    pub vertical: f32,
    pub longitudinal: f32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct BoardLocalTransform {
    pub translation: BoardLocalPosition,
    pub basis: Required<Basis3>,
}

/// Reproduces only the observed front/back translation reflection.
///
/// `CalcTruckTransforms` builds complete matrices, but their external
/// configuration and basis convention are not yet resolved.  The bases
/// therefore remain typed requirements.
pub fn symmetric_truck_transforms(
    lateral: f32,
    vertical: f32,
    front_longitudinal: f32,
) -> [BoardLocalTransform; TRUCK_COUNT] {
    [
        BoardLocalTransform {
            translation: BoardLocalPosition {
                lateral,
                vertical,
                longitudinal: front_longitudinal,
            },
            basis: Required::unresolved(UnresolvedParameter::TruckBasis(BodyId::FrontTruck)),
        },
        BoardLocalTransform {
            translation: BoardLocalPosition {
                lateral,
                vertical,
                longitudinal: -front_longitudinal,
            },
            basis: Required::unresolved(UnresolvedParameter::TruckBasis(BodyId::BackTruck)),
        },
    ]
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct RetailDriveFrameRaw {
    /// Retail quaternion in observed `(x, y, z, w)` lane order.
    pub quaternion_lanes: [u32; 4],
    /// Affine translation vector copied from matrix offset `0x30`.
    pub translation_lanes: [u32; 4],
}

#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct RetailDriveFramesRaw {
    /// Frame emitted by helper `0x82BD3A10`.
    pub body_a: RetailDriveFrameRaw,
    /// Frame emitted by helper `0x82BD3BD0`.
    pub body_b: RetailDriveFrameRaw,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DriveFamily {
    TruckToDeck,
    WheelToTruck,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DriveDescriptor {
    pub slot: usize,
    pub family: DriveFamily,
    /// Whether the decoded default attribute collections create this drive.
    pub enabled_by_default: bool,
    /// Internal `rw::physics::Drive::m_bodyA` (`Drive+0x10`).
    ///
    /// `Simulation::AddDrive` stores its second body argument here.
    pub body_a: BodyId,
    /// Internal `rw::physics::Drive::m_bodyB` (`Drive+0x14`).
    ///
    /// `Simulation::AddDrive` stores its first body argument here.
    pub body_b: BodyId,
    pub frames: Required<RetailDriveFramesRaw>,
    pub dynamics: RetailDriveDynamics,
}

impl DriveDescriptor {
    fn observed(
        slot: usize,
        family: DriveFamily,
        enabled_by_default: bool,
        body_a: BodyId,
        body_b: BodyId,
        frames: RetailDriveFramesRaw,
        dynamics: RetailDriveDynamics,
    ) -> Self {
        Self {
            slot,
            family,
            enabled_by_default,
            body_a,
            body_b,
            frames: Required::supplied(frames),
            dynamics,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SkateboardTopology {
    pub bodies: [BodyDescriptor; BODY_COUNT],
    pub drives: [DriveDescriptor; DRIVE_COUNT],
}

impl SkateboardTopology {
    /// Builds the recovered identity graph without inventing physical tuning.
    pub fn observed() -> Self {
        let bodies = [
            BodyDescriptor::evidence_gated(
                BodyId::RightFrontWheel,
                ShapeFamily::Wheel,
                Required::supplied(CollisionGeometry::Sphere {
                    radius: RETAIL_WHEEL_RADIUS,
                }),
                RETAIL_WHEEL_MASS,
                RETAIL_WHEEL_MATERIAL,
            ),
            BodyDescriptor::evidence_gated(
                BodyId::LeftFrontWheel,
                ShapeFamily::Wheel,
                Required::supplied(CollisionGeometry::Sphere {
                    radius: RETAIL_WHEEL_RADIUS,
                }),
                RETAIL_WHEEL_MASS,
                RETAIL_WHEEL_MATERIAL,
            ),
            BodyDescriptor::evidence_gated(
                BodyId::RightBackWheel,
                ShapeFamily::Wheel,
                Required::supplied(CollisionGeometry::Sphere {
                    radius: RETAIL_WHEEL_RADIUS,
                }),
                RETAIL_WHEEL_MASS,
                RETAIL_WHEEL_MATERIAL,
            ),
            BodyDescriptor::evidence_gated(
                BodyId::LeftBackWheel,
                ShapeFamily::Wheel,
                Required::supplied(CollisionGeometry::Sphere {
                    radius: RETAIL_WHEEL_RADIUS,
                }),
                RETAIL_WHEEL_MASS,
                RETAIL_WHEEL_MATERIAL,
            ),
            BodyDescriptor::evidence_gated(
                BodyId::FrontTruck,
                ShapeFamily::Truck,
                Required::supplied(CollisionGeometry::Capsule {
                    radius: RETAIL_TRUCK_CAPSULE_RADIUS,
                    half_height: RETAIL_TRUCK_CAPSULE_HALF_HEIGHT,
                }),
                RETAIL_TRUCK_MASS,
                RETAIL_TRUCK_MATERIAL,
            ),
            BodyDescriptor::evidence_gated(
                BodyId::BackTruck,
                ShapeFamily::Truck,
                Required::supplied(CollisionGeometry::Capsule {
                    radius: RETAIL_TRUCK_CAPSULE_RADIUS,
                    half_height: RETAIL_TRUCK_CAPSULE_HALF_HEIGHT,
                }),
                RETAIL_TRUCK_MASS,
                RETAIL_TRUCK_MATERIAL,
            ),
            BodyDescriptor::evidence_gated(
                BodyId::Deck,
                ShapeFamily::TriangleDeck,
                Required::supplied(CollisionGeometry::RetailDeckAggregate(
                    retail_deck_collision_evidence(),
                )),
                RETAIL_DECK_MASS,
                RETAIL_DECK_MATERIAL,
            ),
        ];

        // These are internal Drive m_bodyA/m_bodyB pairs, not AddDrive's
        // first/second API argument order. AddDrive stores r5 at Drive+0x10
        // (m_bodyA) and r4 at Drive+0x14 (m_bodyB).
        let truck_dynamics = retail_truck_drive_dynamics(
            false,
            RETAIL_TRUCK_TWIST_ANGLE_DEGREES,
            RETAIL_TRUCK_MATERIAL.static_friction,
            RETAIL_TRUCK_TWIST_LIMIT_DEGREES,
        );
        let wheel_dynamics = retail_wheel_drive_dynamics(false);
        let truck_frames =
            retail_drive_frames::default_truck_drive_frames().map(RetailDriveFramesRaw::from);
        let wheel_frames =
            retail_drive_frames::default_wheel_drive_frames().map(RetailDriveFramesRaw::from);
        let drives = [
            DriveDescriptor::observed(
                0,
                DriveFamily::TruckToDeck,
                true,
                BodyId::FrontTruck,
                BodyId::Deck,
                truck_frames[0],
                truck_dynamics,
            ),
            DriveDescriptor::observed(
                1,
                DriveFamily::TruckToDeck,
                true,
                BodyId::BackTruck,
                BodyId::Deck,
                truck_frames[1],
                truck_dynamics,
            ),
            DriveDescriptor::observed(
                2,
                DriveFamily::WheelToTruck,
                false,
                BodyId::RightFrontWheel,
                BodyId::FrontTruck,
                wheel_frames[0],
                wheel_dynamics,
            ),
            DriveDescriptor::observed(
                3,
                DriveFamily::WheelToTruck,
                false,
                BodyId::LeftFrontWheel,
                BodyId::FrontTruck,
                wheel_frames[1],
                wheel_dynamics,
            ),
            DriveDescriptor::observed(
                4,
                DriveFamily::WheelToTruck,
                false,
                BodyId::RightBackWheel,
                BodyId::BackTruck,
                wheel_frames[2],
                wheel_dynamics,
            ),
            DriveDescriptor::observed(
                5,
                DriveFamily::WheelToTruck,
                false,
                BodyId::LeftBackWheel,
                BodyId::BackTruck,
                wheel_frames[3],
                wheel_dynamics,
            ),
        ];

        Self { bodies, drives }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BodyPose {
    pub translation: Vector3,
    /// Quaternion components in caller-owned x/y/z/w convention.
    pub rotation_xyzw: [f32; 4],
}

impl Default for BodyPose {
    fn default() -> Self {
        Self {
            translation: Vector3::ZERO,
            rotation_xyzw: [0.0, 0.0, 0.0, 1.0],
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BodyPoseSet {
    pub bodies: [BodyPose; BODY_COUNT],
}

impl BodyPoseSet {
    pub fn get(&self, body: BodyId) -> BodyPose {
        self.bodies[body.index()]
    }

    pub fn get_mut(&mut self, body: BodyId) -> &mut BodyPose {
        &mut self.bodies[body.index()]
    }
}

impl Default for BodyPoseSet {
    fn default() -> Self {
        Self {
            bodies: [BodyPose::default(); BODY_COUNT],
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct WheelContact {
    pub touching: bool,
    /// Caller-measured wheel compression.  No clamp or force law is applied.
    pub compression: f32,
    pub point: Option<Vector3>,
    pub normal: Option<Vector3>,
    pub surface_key: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WheelState {
    pub wheel: WheelId,
    pub contact: WheelContact,
}

impl WheelState {
    const fn empty(wheel: WheelId) -> Self {
        Self {
            wheel,
            contact: WheelContact {
                touching: false,
                compression: 0.0,
                point: None,
                normal: None,
                surface_key: None,
            },
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct CompressionAggregate {
    pub front: f32,
    pub back: f32,
    pub all_wheels: f32,
}

impl CompressionAggregate {
    /// Aggregates four already-relative wheel compressions.
    pub fn from_wheel_compressions(compressions: [f32; WHEEL_COUNT]) -> Self {
        let front = (compressions[0] + compressions[1]) * AXLE_AVERAGE_WEIGHT;
        let back = (compressions[2] + compressions[3]) * AXLE_AVERAGE_WEIGHT;
        let all_wheels = (compressions[0] + compressions[1] + compressions[2] + compressions[3])
            * FOUR_WHEEL_AVERAGE_WEIGHT;

        Self {
            front,
            back,
            all_wheels,
        }
    }

    /// TU3's raw deck-local form: pair-average each axle, then subtract the
    /// shared reference stored at object offset 0x20BC.
    pub fn from_deck_local_axis(wheel_axis: [f32; WHEEL_COUNT], reference: f32) -> Self {
        let front = (wheel_axis[0] + wheel_axis[1]) * AXLE_AVERAGE_WEIGHT - reference;
        let back = (wheel_axis[2] + wheel_axis[3]) * AXLE_AVERAGE_WEIGHT - reference;
        let all_wheels = (front + back) * AXLE_AVERAGE_WEIGHT;

        Self {
            front,
            back,
            all_wheels,
        }
    }
}

/// Only physics authority may publish the physics-owned body pose set.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PoseAuthority {
    Physics,
    FollowAnimationData,
    Animation,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PhysicsPoseOutput {
    pub step: u64,
    pub poses: BodyPoseSet,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PostPhysicsInput {
    pub step: u64,
    pub contacts: [WheelContact; WHEEL_COUNT],
    pub body_poses: BodyPoseSet,
    pub pose_authority: PoseAuthority,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PostPhysicsOutput {
    pub step: u64,
    pub compression: CompressionAggregate,
    pub physics_pose: Option<PhysicsPoseOutput>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SkateboardBodyState {
    pub last_step: Option<u64>,
    pub wheels: [WheelState; WHEEL_COUNT],
    pub compression: CompressionAggregate,
}

impl Default for SkateboardBodyState {
    fn default() -> Self {
        Self {
            last_step: None,
            wheels: [
                WheelState::empty(WheelId::RightFront),
                WheelState::empty(WheelId::LeftFront),
                WheelState::empty(WheelId::RightBack),
                WheelState::empty(WheelId::LeftBack),
            ],
            compression: CompressionAggregate::default(),
        }
    }
}

impl SkateboardBodyState {
    /// Applies only the recovered post-physics state copy and aggregation.
    ///
    /// Collision events, force application, solver stepping, and presentation
    /// authority transitions remain outside this standalone module.
    pub fn update_post_physics(&mut self, input: PostPhysicsInput) -> PostPhysicsOutput {
        for (index, contact) in input.contacts.into_iter().enumerate() {
            self.wheels[index].contact = contact;
        }

        self.last_step = Some(input.step);
        self.compression = CompressionAggregate::from_wheel_compressions([
            self.wheels[0].contact.compression,
            self.wheels[1].contact.compression,
            self.wheels[2].contact.compression,
            self.wheels[3].contact.compression,
        ]);

        let physics_pose = if input.pose_authority == PoseAuthority::Physics {
            Some(PhysicsPoseOutput {
                step: input.step,
                poses: input.body_poses,
            })
        } else {
            None
        };

        PostPhysicsOutput {
            step: input.step,
            compression: self.compression,
            physics_pose,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn contact(compression: f32, surface_key: u64) -> WheelContact {
        WheelContact {
            touching: true,
            compression,
            point: Some(Vector3::new(compression, 1.0, 2.0)),
            normal: Some(Vector3::new(0.0, 1.0, 0.0)),
            surface_key: Some(surface_key),
        }
    }

    fn distinct_poses() -> BodyPoseSet {
        BodyPoseSet {
            bodies: std::array::from_fn(|index| BodyPose {
                translation: Vector3::new(index as f32, 10.0 + index as f32, -1.0),
                rotation_xyzw: [0.0, 0.0, 0.0, 1.0],
            }),
        }
    }

    #[test]
    fn topology_identity_matches_observed_six_drive_graph() {
        let topology = SkateboardTopology::observed();

        assert_eq!(
            topology.bodies.each_ref().map(|body| body.id),
            BodyId::ORDER
        );
        assert_eq!(topology.drives.len(), DRIVE_COUNT);
        assert_eq!(
            topology
                .drives
                .iter()
                .filter(|drive| drive.enabled_by_default)
                .count(),
            2
        );

        assert_eq!(
            topology
                .drives
                .each_ref()
                .map(|drive| (drive.body_a, drive.body_b)),
            [
                (BodyId::FrontTruck, BodyId::Deck),
                (BodyId::BackTruck, BodyId::Deck),
                (BodyId::RightFrontWheel, BodyId::FrontTruck),
                (BodyId::LeftFrontWheel, BodyId::FrontTruck),
                (BodyId::RightBackWheel, BodyId::BackTruck),
                (BodyId::LeftBackWheel, BodyId::BackTruck),
            ]
        );
        assert!(topology.bodies.iter().all(|body| {
            matches!(body.mass, Required::Supplied(_)) && body.inertia.is_unresolved()
        }));
        assert!(topology.bodies[..WHEEL_COUNT].iter().all(|body| {
            body.collision_geometry
                == Required::supplied(CollisionGeometry::Sphere {
                    radius: RETAIL_WHEEL_RADIUS,
                })
        }));
        let truck_shape = Required::supplied(CollisionGeometry::Capsule {
            radius: RETAIL_TRUCK_CAPSULE_RADIUS,
            half_height: RETAIL_TRUCK_CAPSULE_HALF_HEIGHT,
        });
        assert_eq!(
            topology.bodies[BodyId::FrontTruck.index()].collision_geometry,
            truck_shape
        );
        assert_eq!(
            topology.bodies[BodyId::BackTruck.index()].collision_geometry,
            truck_shape
        );
        assert_eq!(
            topology.bodies[BodyId::Deck.index()].collision_geometry,
            Required::supplied(CollisionGeometry::RetailDeckAggregate(
                retail_deck_collision_evidence()
            ))
        );
        assert!(
            topology
                .drives
                .iter()
                .all(|drive| matches!(drive.frames, Required::Supplied(_)))
        );
        assert!(
            topology.drives[..TRUCK_COUNT]
                .iter()
                .all(|drive| drive.family == DriveFamily::TruckToDeck)
        );
        assert!(
            topology.drives[TRUCK_COUNT..]
                .iter()
                .all(|drive| drive.family == DriveFamily::WheelToTruck)
        );
    }

    #[test]
    fn wheel_order_and_axle_ownership_are_stable() {
        assert_eq!(
            WheelId::ORDER.map(WheelId::body),
            [
                BodyId::RightFrontWheel,
                BodyId::LeftFrontWheel,
                BodyId::RightBackWheel,
                BodyId::LeftBackWheel,
            ]
        );
        assert_eq!(
            WheelId::ORDER.map(WheelId::truck),
            [
                BodyId::FrontTruck,
                BodyId::FrontTruck,
                BodyId::BackTruck,
                BodyId::BackTruck,
            ]
        );
    }

    #[test]
    fn recovered_physics_defaults_preserve_database_bits() {
        assert_eq!(
            RETAIL_PHYSICS_DEFAULTS.world_gravity.y.to_bits(),
            0xC11C_CCCD
        );
        assert_eq!(RETAIL_PHYSICS_DEFAULTS.maximum_solver_iterations, 25);
        assert_eq!(
            RETAIL_PHYSICS_DEFAULTS.simulation_padding.to_bits(),
            0x3DCC_CCCD
        );
        assert_eq!(
            RETAIL_PROCESSED_PHYSICS_DELTA_SECONDS.to_bits(),
            0x3C88_8889
        );
        assert_eq!(
            size_of::<SpeedConservationDefaults>(),
            28,
            "attribute layout must retain all seven floats"
        );
        assert_eq!(
            RETAIL_SPEED_CONSERVATION_DEFAULTS
                .coffin_acceleration
                .to_bits(),
            0xBECC_CCCD
        );
    }

    #[test]
    fn recovered_body_mass_material_and_wheel_radius_are_exact() {
        let topology = SkateboardTopology::observed();
        assert_eq!(RETAIL_SKATEBOARD_MASS_FACTOR.to_bits(), 0x40A0_0000);
        assert_eq!(RETAIL_DECK_MASS.to_bits(), 0x40C0_0000);
        assert_eq!(RETAIL_TRUCK_MASS.to_bits(), 0x3FF9_9999);
        assert_eq!(RETAIL_WHEEL_MASS.to_bits(), 0x3ED4_7AE1);
        for wheel in &topology.bodies[..WHEEL_COUNT] {
            assert_eq!(wheel.mass, Required::supplied(RETAIL_WHEEL_MASS));
            assert_eq!(wheel.material, RETAIL_WHEEL_MATERIAL);
        }
        for truck in &topology.bodies[WHEEL_COUNT..WHEEL_COUNT + TRUCK_COUNT] {
            assert_eq!(truck.mass, Required::supplied(RETAIL_TRUCK_MASS));
            assert_eq!(truck.material, RETAIL_TRUCK_MATERIAL);
        }
        assert_eq!(
            topology.bodies[BodyId::Deck.index()].mass,
            Required::supplied(RETAIL_DECK_MASS)
        );
        assert_eq!(
            topology.bodies[BodyId::Deck.index()].material,
            RETAIL_DECK_MATERIAL
        );
        assert_eq!(RETAIL_WHEEL_RADIUS.to_bits(), 0x3CFD_F3B6);
        assert_eq!(RETAIL_TRUCK_CAPSULE_RADIUS.to_bits(), 0x3C08_7FCC);
        assert_eq!(RETAIL_TRUCK_CAPSULE_HALF_HEIGHT.to_bits(), 0x3D83_53F8);
    }

    #[test]
    fn recovered_deck_collision_preserves_exact_aggregate_slots() {
        let deck = retail_deck_collision_evidence();

        assert_eq!(deck.volume_slot_count, 15);
        assert_eq!(deck.rounded_box.slot, 0);
        assert_eq!(
            [
                deck.rounded_box.half_extents.x.to_bits(),
                deck.rounded_box.half_extents.y.to_bits(),
                deck.rounded_box.half_extents.z.to_bits(),
                deck.rounded_box.radius.to_bits(),
            ],
            [0x3DE7_EF9D, 0x3A44_9BA8, 0x3E93_9581, 0x3BDD_2F1A]
        );
        assert_eq!(deck.side_capsules.map(|volume| volume.slot), [1, 2]);
        assert_eq!(
            deck.side_capsules
                .map(|volume| volume.endpoint_a.x.to_bits()),
            [0x3DE6_6666, 0xBDE6_6666]
        );
        assert_eq!(
            deck.side_capsules.map(|volume| volume.radius.to_bits()),
            [0x3BF5_C28F; 2]
        );
        assert_eq!(deck.fixed_spheres.map(|volume| volume.slot), [3, 4]);
        assert_eq!(
            deck.fixed_spheres.map(|volume| volume.center.z.to_bits()),
            [0x3E70_A3D7, 0xBE70_A3D7]
        );
        assert_eq!(
            deck.fixed_spheres.map(|volume| volume.radius.to_bits()),
            [0x3D0F_5C29; 2]
        );
        assert_eq!(deck.end_triangle_first_slot, 5);
        assert_eq!(deck.end_triangles_per_end, 5);
        assert_eq!(RETAIL_DECK_END_TRIANGLE_COUNT, 10);
        assert_eq!(deck.end_triangle_radius.to_bits(), 0x3BF5_C28F);
        assert_eq!(
            [
                deck.end_triangles[0].c.x.to_bits(),
                deck.end_triangles[0].c.y.to_bits(),
                deck.end_triangles[0].c.z.to_bits(),
            ],
            [0x3DBA_65C2, 0x3CA4_24F5, 0xBEC5_50C2]
        );
        assert_eq!(
            [
                deck.end_triangles[9].c.x.to_bits(),
                deck.end_triangles[9].c.y.to_bits(),
                deck.end_triangles[9].c.z.to_bits(),
            ],
            [0xBDE6_6662, 0xB0CD_9418, 0x3E97_0A3D]
        );
    }

    #[test]
    fn named_surface_scalars_match_all_recovered_collections() {
        let expected = [
            (
                RetailSurfaceCollection::Default,
                [0x0000_0000, 0x0000_0000, 0x0000_0000, 0x0000_0000],
            ),
            (
                RetailSurfaceCollection::Rough,
                [0x3F59_999A, 0x3F40_0000, 0x3E4C_CCCD, 0x3F99_999A],
            ),
            (
                RetailSurfaceCollection::Slippery,
                [0x3F33_3333, 0x3F00_0000, 0x3F33_3333, 0x3F00_0000],
            ),
            (
                RetailSurfaceCollection::Slow,
                [0x3F66_6666, 0x3F4C_CCCD, 0x3DCC_CCCD, 0x4000_0000],
            ),
            (
                RetailSurfaceCollection::Smooth,
                [0x3F4C_CCCD, 0x3F33_3333, 0x3E99_999A, 0x3F80_0000],
            ),
            (
                RetailSurfaceCollection::VerySlow,
                [0x3F80_0000, 0x3F7D_70A4, 0x3ECC_CCCD, 0x4000_0000],
            ),
        ];
        for (collection, bits) in expected {
            let values = collection.scalars();
            assert_eq!(
                [
                    values.wheel_static_friction.to_bits(),
                    values.wheel_dynamic_friction.to_bits(),
                    values.friction_maximum_speed_change.to_bits(),
                    values.braking_scalar.to_bits(),
                ],
                bits
            );
        }
    }

    #[test]
    fn drive_dynamics_reproduce_only_observed_raw_words() {
        assert_eq!(size_of::<RetailDriveType>(), 4);
        assert_eq!(size_of::<RetailDriveParams>(), 16);
        assert_eq!(size_of::<RetailDriveDynamics>(), 32);
        assert_eq!(size_of::<RetailDriveFrameRaw>(), 32);
        assert_eq!(size_of::<RetailDriveFramesRaw>(), 64);

        let hard = retail_truck_drive_dynamics(false, 14.0, 0.9, 86.1);
        assert_eq!(hard.linear.spring_or_max_velocity.to_bits(), 0x47C3_5000);
        assert_eq!(hard.linear.damping.to_bits(), 0x3ACC_CCCD);
        assert_eq!(hard.linear.max_strength.to_bits(), 0x48AF_C7FF);
        assert_eq!(hard.linear.drive_type, RetailDriveType::SoftDrive);
        assert_eq!(
            hard.angular.spring_or_max_velocity.to_bits(),
            (14.0 * retail_f32(0x426F_FFFF)).to_bits()
        );
        assert_eq!(hard.angular.damping, 0.9);
        assert_eq!(
            hard.angular.max_strength.to_bits(),
            (86.1 * retail_f32(0x4560_FFFE)).to_bits()
        );
        assert_eq!(hard.angular.drive_type, RetailDriveType::HardDrive);

        let soft = retail_truck_drive_dynamics(true, 14.0, 0.9, 86.1);
        assert_eq!(soft.linear.spring_or_max_velocity.to_bits(), 0x45BB_7FFF);
        assert_eq!(soft.linear.damping, 0.0);
        assert_eq!(soft.linear.drive_type, RetailDriveType::HardDrive);

        let wheel_default = retail_wheel_drive_dynamics(false);
        assert_eq!(
            [
                wheel_default.linear.spring_or_max_velocity.to_bits(),
                wheel_default.linear.damping.to_bits(),
                wheel_default.linear.max_strength.to_bits(),
                wheel_default.linear.drive_type as u32,
                wheel_default.angular.spring_or_max_velocity.to_bits(),
                wheel_default.angular.damping.to_bits(),
                wheel_default.angular.max_strength.to_bits(),
                wheel_default.angular.drive_type as u32,
            ],
            [0x4561_0000, 0x4270_0000, 0x470C_9FFF, 1, 0, 0, 0, 0,]
        );

        let wheel_alternate = retail_wheel_drive_dynamics(true);
        assert_eq!(
            [
                wheel_alternate.linear.spring_or_max_velocity.to_bits(),
                wheel_alternate.linear.damping.to_bits(),
                wheel_alternate.linear.max_strength.to_bits(),
                wheel_alternate.linear.drive_type as u32,
                wheel_alternate.angular.spring_or_max_velocity.to_bits(),
                wheel_alternate.angular.damping.to_bits(),
                wheel_alternate.angular.max_strength.to_bits(),
                wheel_alternate.angular.drive_type as u32,
            ],
            [0x45BB_7FFF, 0, 0x48AF_C7FF, 2, 0, 0, 0, 0,]
        );
    }

    #[test]
    fn average_compression_uses_confirmed_four_way_quarter_weight() {
        let aggregate = CompressionAggregate::from_wheel_compressions([0.0, 2.0, 4.0, 10.0]);

        assert_eq!(aggregate.front, 1.0);
        assert_eq!(aggregate.back, 7.0);
        assert_eq!(aggregate.all_wheels, 4.0);

        let raw = CompressionAggregate::from_deck_local_axis([10.0, 14.0, 18.0, 22.0], 3.0);
        assert_eq!(raw.front, 9.0);
        assert_eq!(raw.back, 17.0);
        assert_eq!(raw.all_wheels, 13.0);
    }

    #[test]
    fn truck_translations_reflect_front_to_back_without_guessed_bases() {
        let [front, back] = symmetric_truck_transforms(0.0, -0.03, 0.24);

        assert_eq!(front.translation.lateral, back.translation.lateral);
        assert_eq!(front.translation.vertical, back.translation.vertical);
        assert_eq!(
            front.translation.longitudinal,
            -back.translation.longitudinal
        );
        assert_eq!(
            front.basis,
            Required::unresolved(UnresolvedParameter::TruckBasis(BodyId::FrontTruck))
        );
        assert_eq!(
            back.basis,
            Required::unresolved(UnresolvedParameter::TruckBasis(BodyId::BackTruck))
        );
    }

    #[test]
    fn wheel_contacts_and_compressions_remain_independent() {
        let mut state = SkateboardBodyState::default();
        let contacts = [
            contact(1.0, 10),
            contact(2.0, 20),
            WheelContact::default(),
            contact(8.0, 40),
        ];

        state.update_post_physics(PostPhysicsInput {
            step: 7,
            contacts,
            body_poses: BodyPoseSet::default(),
            pose_authority: PoseAuthority::Physics,
        });

        assert_eq!(state.wheels[0].contact, contacts[0]);
        assert_eq!(state.wheels[1].contact, contacts[1]);
        assert_eq!(state.wheels[2].contact, contacts[2]);
        assert_eq!(state.wheels[3].contact, contacts[3]);
        assert_ne!(state.wheels[0].contact, state.wheels[1].contact);
        assert!(!state.wheels[2].contact.touching);
        assert_eq!(state.compression.all_wheels, 2.75);
    }

    #[test]
    fn pose_output_is_authority_safe() {
        let poses = distinct_poses();
        let mut state = SkateboardBodyState::default();

        for authority in [PoseAuthority::FollowAnimationData, PoseAuthority::Animation] {
            let output = state.update_post_physics(PostPhysicsInput {
                step: 11,
                contacts: [WheelContact::default(); WHEEL_COUNT],
                body_poses: poses,
                pose_authority: authority,
            });
            assert_eq!(output.physics_pose, None);
        }

        let output = state.update_post_physics(PostPhysicsInput {
            step: 12,
            contacts: [WheelContact::default(); WHEEL_COUNT],
            body_poses: poses,
            pose_authority: PoseAuthority::Physics,
        });
        assert_eq!(
            output.physics_pose,
            Some(PhysicsPoseOutput { step: 12, poses })
        );
    }

    #[test]
    fn post_physics_update_is_repeatable() {
        let input = PostPhysicsInput {
            step: 123,
            contacts: [
                contact(0.125, 1),
                contact(0.25, 2),
                contact(0.5, 3),
                contact(1.0, 4),
            ],
            body_poses: distinct_poses(),
            pose_authority: PoseAuthority::Physics,
        };
        let mut first_state = SkateboardBodyState::default();
        let mut second_state = SkateboardBodyState::default();

        let first = first_state.update_post_physics(input);
        let second = second_state.update_post_physics(input);

        assert_eq!(first, second);
        assert_eq!(first_state, second_state);
    }
}
