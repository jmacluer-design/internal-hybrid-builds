//! Skate 3 TU3's legacy RenderWare Collision primitive records.
//!
//! This module ports only operations whose complete instruction bodies have
//! been recovered. It deliberately does not substitute RenderWare Collision
//! 6.14's newer `EA::Collision::ComputeContacts` implementation for TU3's
//! feature-prism primitive-pair path.

#![allow(dead_code)]

use crate::skateboard_body::Vector3;

pub mod tu3 {
    pub const FEATURE_EDGE_CONSTRAIN_POINT: u32 = 0x82AC_6EE8;
    pub const FEATURE_BUILD_EDGE_PLANES: u32 = 0x82AC_6F88;
    pub const POINT_FACE_INTERSECTION: u32 = 0x82AC_C160;
    pub const FIND_FEATURE_INTERSECTION_PRISM: u32 = 0x82AC_E190;
    pub const BUILD_SEPARATION_DIRECTIONS: u32 = 0x82AC_EA30;
    pub const FIND_BEST_SEPARATING_DIRECTION: u32 = 0x82AC_F070;
    pub const COMPUTE_TRIANGLE_FEATURE_TYPE_FROM_NORMAL: u32 = 0x82AD_2A50;
    pub const FIX_UP_TRIANGLE_RESULT: u32 = 0x82AD_3130;
    pub const PRIMITIVE_PAIR_INTERSECT: u32 = 0x82AD_3CD8;
    pub const SEPARATING_DIRECTION_DISPATCH: u32 = 0x82FD_56F0;
    pub const GP_VOLUME_METHODS: u32 = 0x82FD_5870;

    pub const SPHERE_GET_MAXIMUM_FEATURE: u32 = 0x82AD_D7E0;
    pub const SPHERE_GET_INTERVAL: u32 = 0x82AD_D800;
    pub const SPHERE_GET_INTERVALS: u32 = 0x82AD_D820;
    pub const TRIANGLE_GET_MAXIMUM_FEATURE: u32 = 0x82AD_DD68;
    pub const TRIANGLE_GET_INTERVAL: u32 = 0x82AD_E3B8;
    pub const TRIANGLE_GET_INTERVALS: u32 = 0x82AD_E400;
}

pub const FEATURE_EDGE_CAPACITY: usize = 8;
pub const CONTACT_PAIR_CAPACITY: usize = 16;
pub const TRIANGLE_FACE_NORMAL_TOLERANCE: f32 = f32::from_bits(0x3F7F_F62B);
pub const TRIANGLE_FEATURE_SIMPLIFICATION_THRESHOLD: f32 = f32::from_bits(0x3D4C_CCCD);
pub const TRIANGLE_MAXIMUM_FACE_THRESHOLD: f32 = f32::from_bits(0x3F73_3333);

pub mod triangle_flags {
    pub const ONE_SIDED: u32 = 0x0010;
    pub const EDGE_0_CONVEX: u32 = 0x0020;
    pub const EDGE_1_CONVEX: u32 = 0x0040;
    pub const EDGE_2_CONVEX: u32 = 0x0080;
    pub const USE_EDGE_COSINES: u32 = 0x0100;
    pub const VERTEX_0_DISABLED: u32 = 0x0200;
    pub const VERTEX_1_DISABLED: u32 = 0x0400;
    pub const VERTEX_2_DISABLED: u32 = 0x0800;
    pub const DEFAULT: u32 = USE_EDGE_COSINES | EDGE_0_CONVEX | EDGE_1_CONVEX | EDGE_2_CONVEX;
}

/// The old `rw::collision::GPInstance::VolumeType` values recovered from the
/// Skate-era SDK DWARF and confirmed by TU3's method and pair-dispatch tables.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RetailGpVolumeType {
    Unused = 0,
    Sphere = 1,
    Capsule = 2,
    Triangle = 3,
    Box = 4,
    Cylinder = 5,
}

/// One 32-byte `rw::collision::Interval`.
///
/// TU3's VMX code writes a scalar projection splatted through each 16-byte
/// vector. The Rust representation keeps only the meaningful scalar lane.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RetailInterval {
    pub minimum: f32,
    pub maximum: f32,
}

/// Scalar form of the legacy 64-byte `FeatureEdge`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RetailFeatureEdge {
    pub base: Vector3,
    pub direction: Vector3,
    pub plane_normal: Vector3,
    pub length: f32,
}

/// Scalar form of the legacy `rw::collision::Feature`.
///
/// `region` uses zero for the complete feature, odd values for vertices, and
/// even non-zero values for edges. `edge_count` maps to point/edge/face as
/// 0/1/2-or-more.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RetailFeature {
    pub region: u32,
    pub edges: [RetailFeatureEdge; FEATURE_EDGE_CAPACITY],
    pub own_normal: Vector3,
    pub point: Vector3,
    pub edge_count: u32,
}

impl RetailFeature {
    /// Original SDK `Feature::MappedType` expression:
    /// `edge_count > 1 ? 3 : (edge_count & 1)`.
    pub const fn mapped_type(self) -> u32 {
        if self.edge_count > 1 {
            3
        } else {
            self.edge_count & 1
        }
    }
}

/// The fields consumed by TU3's sphere primitive methods.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailGpSphere {
    pub position: Vector3,
}

impl RetailGpSphere {
    /// Port of `GPSphere::GetMaximumFeature` (`0x82ADD7E0`).
    ///
    /// TU3 ignores both winding and query direction here. It writes the sphere
    /// position as a point feature, then clears `region` and `edge_count`.
    pub fn maximum_feature(self) -> RetailFeature {
        RetailFeature {
            point: self.position,
            ..RetailFeature::default()
        }
    }

    /// Port of `GPSphere::GetInterval` (`0x82ADD800`).
    ///
    /// Sphere fatness is intentionally absent: this method projects the
    /// center only. The shared primitive-pair path applies primitive fatness.
    pub fn interval(self, axis: Vector3) -> RetailInterval {
        let projection = dot3(axis, self.position);
        RetailInterval {
            minimum: projection,
            maximum: projection,
        }
    }

    /// Loop/stride semantics of `GPSphere::GetIntervals` (`0x82ADD820`).
    pub fn intervals(self, axes: &[Vector3]) -> Vec<RetailInterval> {
        axes.iter().map(|axis| self.interval(*axis)).collect()
    }
}

/// The three points consumed by TU3's triangle interval methods.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailGpTriangle {
    pub vertex_0: Vector3,
    pub vertex_1: Vector3,
    pub vertex_2: Vector3,
}

impl RetailGpTriangle {
    /// Port of `GPTriangle::GetInterval` (`0x82ADE3B8`).
    pub fn interval(self, axis: Vector3) -> RetailInterval {
        let p0 = dot3(axis, self.vertex_0);
        let p1 = dot3(axis, self.vertex_1);
        let p2 = dot3(axis, self.vertex_2);
        RetailInterval {
            minimum: p0.min(p1).min(p2),
            maximum: p0.max(p1).max(p2),
        }
    }

    /// Loop/stride semantics of `GPTriangle::GetIntervals` (`0x82ADE400`).
    pub fn intervals(self, axes: &[Vector3]) -> Vec<RetailInterval> {
        axes.iter().map(|axis| self.interval(*axis)).collect()
    }
}

/// Original `rw::collision::TriangleFeatureType` values named by the public
/// Skate-era type export and matched to TU3 `0x82AD2A50`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum RetailTriangleFeatureType {
    Face = 0,
    Edge0 = 1,
    Edge1 = 2,
    Vertex1 = 3,
    Edge2 = 4,
    Vertex0 = 5,
    Vertex2 = 6,
}

/// The triangle fields consumed by TU3's legacy maximum-feature and fixup
/// routines. Values are accepted in already-instantiated GP order so this
/// module does not silently replace retail mesh metadata with a host mesh
/// builder.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailGpTriangleFeature {
    pub triangle: RetailGpTriangle,
    pub normal: Vector3,
    pub edge_directions: [Vector3; 3],
    pub edge_lengths: [f32; 3],
    pub edge_cosines: [f32; 3],
    pub flags: u32,
    pub fatness: f32,
}

impl RetailGpTriangleFeature {
    /// Port of the face-normal gate and
    /// `ComputeTriangleFeatureTypeFromNormal` call in
    /// `FixUpTriangleResult` (`0x82AD3130..0x82AD325C`), followed by the
    /// complete classifier at `0x82AD2A50`.
    pub fn feature_type_from_normal(
        self,
        normal_towards_triangle: Vector3,
    ) -> RetailTriangleFeatureType {
        let normal_projection = dot3(normal_towards_triangle, self.normal);
        if normal_projection.abs() >= TRIANGLE_FACE_NORMAL_TOLERANCE {
            return RetailTriangleFeatureType::Face;
        }

        let in_plane = normalize3(sub(
            normal_towards_triangle,
            scale(self.normal, normal_projection),
        ));
        let d0 = dot3(in_plane, self.edge_directions[0]);
        let d1 = dot3(in_plane, self.edge_directions[1]);
        let d2 = dot3(in_plane, self.edge_directions[2]);
        let threshold = TRIANGLE_FEATURE_SIMPLIFICATION_THRESHOLD;

        if d0 > threshold && d1 < -threshold {
            return RetailTriangleFeatureType::Vertex2;
        }
        if d1 > threshold && d2 < -threshold {
            return RetailTriangleFeatureType::Vertex1;
        }
        if d2 > threshold && d0 < -threshold {
            return RetailTriangleFeatureType::Vertex0;
        }
        if d0 > -d1 && -d2 >= d0 {
            return RetailTriangleFeatureType::Edge2;
        }
        if d1 > -d0 && -d2 >= d1 {
            return RetailTriangleFeatureType::Edge1;
        }
        if d2 > -d1 && -d0 >= d2 {
            return RetailTriangleFeatureType::Edge0;
        }
        RetailTriangleFeatureType::Face
    }

    /// The exact face-feature branch of
    /// `GPTriangle::GetMaximumFeature` (`0x82ADDD68`).
    ///
    /// The non-face branches remain intentionally unavailable. The
    /// sphere/triangle separating-direction path supplies the triangle face
    /// normal, so this is the branch used by the wheel/terrain pair.
    pub fn maximum_face_feature(
        self,
        counter_clockwise: bool,
        query_direction: Vector3,
    ) -> Option<RetailFeature> {
        let normal_projection = dot3(query_direction, self.normal);
        if normal_projection.abs() <= TRIANGLE_MAXIMUM_FACE_THRESHOLD {
            return None;
        }

        let same_winding = (normal_projection < 0.0) == counter_clockwise;
        let mut feature = RetailFeature {
            region: if same_winding { 8 } else { 0 },
            own_normal: self.normal,
            edge_count: 3,
            ..RetailFeature::default()
        };

        if same_winding {
            feature.edges[0] = RetailFeatureEdge {
                base: self.triangle.vertex_0,
                direction: self.edge_directions[0],
                length: self.edge_lengths[0],
                ..RetailFeatureEdge::default()
            };
            feature.edges[1] = RetailFeatureEdge {
                base: self.triangle.vertex_2,
                direction: self.edge_directions[1],
                length: self.edge_lengths[1],
                ..RetailFeatureEdge::default()
            };
            feature.edges[2] = RetailFeatureEdge {
                base: self.triangle.vertex_1,
                direction: self.edge_directions[2],
                length: self.edge_lengths[2],
                ..RetailFeatureEdge::default()
            };
        } else {
            feature.edges[0] = RetailFeatureEdge {
                base: self.triangle.vertex_0,
                direction: negate(self.edge_directions[2]),
                length: self.edge_lengths[2],
                ..RetailFeatureEdge::default()
            };
            feature.edges[1] = RetailFeatureEdge {
                base: self.triangle.vertex_1,
                direction: negate(self.edge_directions[1]),
                length: self.edge_lengths[1],
                ..RetailFeatureEdge::default()
            };
            feature.edges[2] = RetailFeatureEdge {
                base: self.triangle.vertex_2,
                direction: negate(self.edge_directions[0]),
                length: self.edge_lengths[0],
                ..RetailFeatureEdge::default()
            };
        }

        let extrusion = if counter_clockwise {
            query_direction
        } else {
            negate(query_direction)
        };
        for edge in feature.edges.iter_mut().take(feature.edge_count as usize) {
            edge.plane_normal = normalize_or_zero(cross(edge.direction, extrusion));
        }
        Some(feature)
    }

    /// Exact face result of `FixUpTriangleResult`.
    ///
    /// For the sphere/triangle pair the SAT direction is parallel to the
    /// triangle face normal, so the recovered classifier always selects this
    /// branch. A one-sided triangle accepts only a normal on its enabled side.
    pub fn accepts_face_normal(self, normal_towards_triangle: Vector3) -> bool {
        if self.flags & triangle_flags::ONE_SIDED == 0 {
            return true;
        }
        dot3(normal_towards_triangle, self.normal) > 0.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailPointFaceIntersection {
    pub point_on_face: Vector3,
    pub point_on_point_feature: Vector3,
    pub face_region: u32,
}

/// Port of the point/face helper at `0x82ACC160`.
///
/// TU3 projects the point along the supplied unit separating direction,
/// selects the face edge with the greatest positive plane violation, moves
/// onto that edge plane, and then invokes `FeatureEdge::constrain_point`.
pub fn intersect_point_face(
    point: Vector3,
    face: &mut RetailFeature,
    separating_direction: Vector3,
) -> RetailPointFaceIntersection {
    debug_assert!(face.edge_count > 1);
    let face_origin = face.edges[0].base;
    let mut projected = add(
        point,
        scale(
            separating_direction,
            dot3(separating_direction, sub(face_origin, point)),
        ),
    );

    let mut selected_edge = None;
    let mut greatest_violation = 0.0_f32;
    for (index, edge) in face.edges.iter().take(face.edge_count as usize).enumerate() {
        let violation = dot3(edge.plane_normal, sub(projected, edge.base));
        if selected_edge.is_none() || violation > greatest_violation {
            selected_edge = Some(index);
            greatest_violation = violation;
        }
    }

    if greatest_violation > 0.0 {
        let edge_index = selected_edge.expect("a face owns at least two edges");
        let edge = face.edges[edge_index];
        projected = sub(projected, scale(edge.plane_normal, greatest_violation));
        let clamp_region = constrain_point_to_edge(edge, &mut projected);
        face.region = face
            .region
            .wrapping_add((edge_index as u32).wrapping_mul(2))
            .wrapping_add(clamp_region);
    }

    RetailPointFaceIntersection {
        point_on_face: projected,
        point_on_point_feature: point,
        face_region: face.region,
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailSphereTriangleContact {
    /// TU3's final normal from sphere (primitive 1) towards triangle
    /// (primitive 2).
    pub normal: Vector3,
    pub point_on_sphere: Vector3,
    pub point_on_triangle: Vector3,
    pub distance: f32,
    pub face_region: u32,
}

/// Region written by `GPTriangle::GetMaximumFeature` for a point that remains
/// inside the three face edge planes.
///
/// Any other region has crossed an edge and requires TU3's still-unported
/// edge/vertex result fixup before it is eligible to become a solver contact.
pub const RETAIL_TRIANGLE_FACE_INTERIOR_REGION: u32 = 8;

impl RetailSphereTriangleContact {
    pub const fn is_face_interior(self) -> bool {
        self.face_region == RETAIL_TRIANGLE_FACE_INTERIOR_REGION
    }
}

/// Complete recovered legacy sphere/triangle path used by a wheel against a
/// terrain triangle.
///
/// This combines the generic one-axis SAT table entry, the sphere point
/// feature, the triangle face-feature branch, the point/face prism helper,
/// primitive fatness adjustment, and the face branch of triangle fixup.
pub fn intersect_sphere_triangle(
    sphere: RetailGpSphere,
    sphere_radius: f32,
    triangle: RetailGpTriangleFeature,
    minimum_separating_distance: f32,
) -> Option<RetailSphereTriangleContact> {
    let axis = triangle.normal;
    let sphere_interval = sphere.interval(axis);
    let triangle_interval = triangle.triangle.interval(axis);
    let sphere_after_triangle = sphere_interval.minimum - triangle_interval.maximum;
    let triangle_after_sphere = triangle_interval.minimum - sphere_interval.maximum;
    let (normal, separation) = if sphere_after_triangle >= triangle_after_sphere {
        (negate(axis), sphere_after_triangle)
    } else {
        (axis, triangle_after_sphere)
    };

    if separation > sphere_radius + triangle.fatness + minimum_separating_distance {
        return None;
    }

    let normal_towards_triangle = negate(normal);
    if triangle.feature_type_from_normal(normal_towards_triangle) != RetailTriangleFeatureType::Face
        || !triangle.accepts_face_normal(normal_towards_triangle)
    {
        return None;
    }

    let mut face = triangle.maximum_face_feature(false, normal_towards_triangle)?;
    let prism = intersect_point_face(sphere.position, &mut face, normal);
    let point_on_sphere = add(sphere.position, scale(normal, sphere_radius));
    let point_on_triangle = sub(prism.point_on_face, scale(normal, triangle.fatness));
    Some(RetailSphereTriangleContact {
        normal,
        point_on_sphere,
        point_on_triangle,
        distance: dot3(sub(point_on_triangle, point_on_sphere), normal),
        face_region: prism.face_region,
    })
}

fn constrain_point_to_edge(edge: RetailFeatureEdge, point: &mut Vector3) -> u32 {
    let along = dot3(sub(*point, edge.base), edge.direction);
    if along < 0.0 {
        *point = edge.base;
        1
    } else if along > edge.length {
        *point = add(edge.base, scale(edge.direction, edge.length));
        3
    } else {
        *point = add(edge.base, scale(edge.direction, along));
        2
    }
}

fn dot3(left: Vector3, right: Vector3) -> f32 {
    left.x * right.x + left.y * right.y + left.z * right.z
}

fn add(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x + right.x, left.y + right.y, left.z + right.z)
}

fn sub(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x - right.x, left.y - right.y, left.z - right.z)
}

fn scale(vector: Vector3, scalar: f32) -> Vector3 {
    Vector3::new(vector.x * scalar, vector.y * scalar, vector.z * scalar)
}

fn negate(vector: Vector3) -> Vector3 {
    scale(vector, -1.0)
}

fn cross(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    )
}

fn normalize3(vector: Vector3) -> Vector3 {
    let inverse_length = dot3(vector, vector).sqrt().recip();
    scale(vector, inverse_length)
}

fn normalize_or_zero(vector: Vector3) -> Vector3 {
    let length_squared = dot3(vector, vector);
    if length_squared > f32::EPSILON {
        scale(vector, length_squared.sqrt().recip())
    } else {
        Vector3::ZERO
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn old_gp_type_values_match_the_tu3_dispatch_index() {
        assert_eq!(RetailGpVolumeType::Sphere as u8, 1);
        assert_eq!(RetailGpVolumeType::Triangle as u8, 3);
        assert_eq!(
            RetailGpVolumeType::Sphere as usize * 6 + RetailGpVolumeType::Triangle as usize,
            9
        );
    }

    #[test]
    fn sphere_feature_is_the_recovered_point_feature() {
        let position = Vector3::new(1.25, -2.5, 4.0);
        let feature = RetailGpSphere { position }.maximum_feature();
        assert_eq!(feature.point, position);
        assert_eq!(feature.region, 0);
        assert_eq!(feature.edge_count, 0);
        assert_eq!(feature.mapped_type(), 0);
    }

    #[test]
    fn sphere_interval_projects_only_its_center() {
        let sphere = RetailGpSphere {
            position: Vector3::new(2.0, 3.0, 5.0),
        };
        assert_eq!(
            sphere.interval(Vector3::new(-1.0, 0.5, 2.0)),
            RetailInterval {
                minimum: 9.5,
                maximum: 9.5,
            }
        );
    }

    #[test]
    fn triangle_interval_uses_all_three_projected_vertices() {
        let triangle = RetailGpTriangle {
            vertex_0: Vector3::new(-2.0, 1.0, 0.0),
            vertex_1: Vector3::new(4.0, -3.0, 1.0),
            vertex_2: Vector3::new(0.5, 2.0, -2.0),
        };
        assert_eq!(
            triangle.interval(Vector3::new(1.0, 2.0, -1.0)),
            RetailInterval {
                minimum: -3.0,
                maximum: 6.5,
            }
        );
    }

    #[test]
    fn interval_batch_preserves_tu3_input_order() {
        let sphere = RetailGpSphere {
            position: Vector3::new(2.0, 3.0, 5.0),
        };
        assert_eq!(
            sphere.intervals(&[
                Vector3::new(1.0, 0.0, 0.0),
                Vector3::new(0.0, 1.0, 0.0),
                Vector3::new(0.0, 0.0, 1.0),
            ]),
            vec![
                RetailInterval {
                    minimum: 2.0,
                    maximum: 2.0,
                },
                RetailInterval {
                    minimum: 3.0,
                    maximum: 3.0,
                },
                RetailInterval {
                    minimum: 5.0,
                    maximum: 5.0,
                },
            ]
        );
    }

    fn horizontal_triangle(flags: u32) -> RetailGpTriangleFeature {
        RetailGpTriangleFeature {
            triangle: RetailGpTriangle {
                vertex_0: Vector3::new(-1.0, 0.0, -1.0),
                vertex_1: Vector3::new(0.0, 0.0, 1.0),
                vertex_2: Vector3::new(1.0, 0.0, -1.0),
            },
            normal: Vector3::new(0.0, 1.0, 0.0),
            edge_directions: [
                Vector3::new(1.0, 0.0, 0.0),
                normalize3(Vector3::new(-1.0, 0.0, 2.0)),
                normalize3(Vector3::new(-1.0, 0.0, -2.0)),
            ],
            edge_lengths: [2.0, 5.0_f32.sqrt(), 5.0_f32.sqrt()],
            edge_cosines: [-1.0; 3],
            flags,
            fatness: 0.0,
        }
    }

    fn equilateral_classifier_triangle() -> RetailGpTriangleFeature {
        let root_three_over_two = 0.866_025_4;
        RetailGpTriangleFeature {
            edge_directions: [
                Vector3::new(0.5, 0.0, root_three_over_two),
                Vector3::new(0.5, 0.0, -root_three_over_two),
                Vector3::new(-1.0, 0.0, 0.0),
            ],
            ..horizontal_triangle(triangle_flags::DEFAULT)
        }
    }

    fn horizontal_direction(degrees: f32) -> Vector3 {
        let radians = degrees.to_radians();
        Vector3::new(radians.cos(), 0.0, radians.sin())
    }

    #[test]
    fn recovered_triangle_threshold_constants_match_tu3_words() {
        assert_eq!(TRIANGLE_FACE_NORMAL_TOLERANCE.to_bits(), 0x3F7F_F62B);
        assert_eq!(
            TRIANGLE_FEATURE_SIMPLIFICATION_THRESHOLD.to_bits(),
            0x3D4C_CCCD
        );
        assert_eq!(TRIANGLE_MAXIMUM_FACE_THRESHOLD.to_bits(), 0x3F73_3333);
    }

    #[test]
    fn triangle_normal_classifier_preserves_all_retail_enum_values() {
        let triangle = equilateral_classifier_triangle();
        assert_eq!(
            triangle.feature_type_from_normal(Vector3::new(0.0, 1.0, 0.0)),
            RetailTriangleFeatureType::Face
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(269.0)),
            RetailTriangleFeatureType::Edge0
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(31.0)),
            RetailTriangleFeatureType::Edge1
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(29.0)),
            RetailTriangleFeatureType::Edge2
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(210.0)),
            RetailTriangleFeatureType::Vertex0
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(0.0)),
            RetailTriangleFeatureType::Vertex1
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(90.0)),
            RetailTriangleFeatureType::Vertex2
        );
        assert_eq!(
            triangle.feature_type_from_normal(horizontal_direction(150.0)),
            RetailTriangleFeatureType::Face
        );
    }

    #[test]
    fn maximum_face_feature_preserves_retail_edge_order_and_regions() {
        let triangle = horizontal_triangle(triangle_flags::DEFAULT);
        let forward = triangle
            .maximum_face_feature(false, Vector3::new(0.0, 1.0, 0.0))
            .unwrap();
        assert_eq!(forward.region, 8);
        assert_eq!(forward.edge_count, 3);
        assert_eq!(forward.edges[0].base, triangle.triangle.vertex_0);
        assert_eq!(forward.edges[1].base, triangle.triangle.vertex_2);
        assert_eq!(forward.edges[2].base, triangle.triangle.vertex_1);

        let reverse = triangle
            .maximum_face_feature(true, Vector3::new(0.0, 1.0, 0.0))
            .unwrap();
        assert_eq!(reverse.region, 0);
        assert_eq!(reverse.edges[0].base, triangle.triangle.vertex_0);
        assert_eq!(reverse.edges[1].base, triangle.triangle.vertex_1);
        assert_eq!(reverse.edges[2].base, triangle.triangle.vertex_2);
    }

    #[test]
    fn point_face_prism_projects_inside_and_constrains_outside() {
        let triangle = horizontal_triangle(triangle_flags::DEFAULT);
        let mut face = triangle
            .maximum_face_feature(false, Vector3::new(0.0, 1.0, 0.0))
            .unwrap();
        let inside = intersect_point_face(
            Vector3::new(0.0, 0.5, 0.0),
            &mut face,
            Vector3::new(0.0, -1.0, 0.0),
        );
        assert_eq!(inside.point_on_face, Vector3::ZERO);
        assert_eq!(inside.point_on_point_feature, Vector3::new(0.0, 0.5, 0.0));
        assert_eq!(inside.face_region, 8);

        let mut face = triangle
            .maximum_face_feature(false, Vector3::new(0.0, 1.0, 0.0))
            .unwrap();
        let outside = intersect_point_face(
            Vector3::new(2.0, 0.5, -1.0),
            &mut face,
            Vector3::new(0.0, -1.0, 0.0),
        );
        assert_eq!(outside.point_on_face, Vector3::new(1.0, 0.0, -1.0));
        assert_ne!(outside.face_region, 8);
    }

    #[test]
    fn wheel_sphere_contact_uses_face_prism_and_fatness_without_adhesion() {
        let triangle = horizontal_triangle(triangle_flags::DEFAULT);
        let contact = intersect_sphere_triangle(
            RetailGpSphere {
                position: Vector3::new(0.0, 0.02, 0.0),
            },
            0.031,
            triangle,
            0.1,
        )
        .unwrap();
        assert_eq!(contact.normal, Vector3::new(0.0, -1.0, 0.0));
        assert_eq!(contact.point_on_sphere, Vector3::new(0.0, -0.011, 0.0));
        assert_eq!(contact.point_on_triangle, Vector3::ZERO);
        assert!((contact.distance + 0.011).abs() < 1.0e-6);
        assert!(contact.is_face_interior());

        assert!(
            intersect_sphere_triangle(
                RetailGpSphere {
                    position: Vector3::new(0.0, 0.132, 0.0),
                },
                0.031,
                triangle,
                0.1,
            )
            .is_none()
        );
    }

    #[test]
    fn one_sided_face_gate_uses_the_recovered_normal_sign() {
        let triangle = horizontal_triangle(triangle_flags::DEFAULT | triangle_flags::ONE_SIDED);
        assert!(triangle.accepts_face_normal(Vector3::new(0.0, 1.0, 0.0)));
        assert!(!triangle.accepts_face_normal(Vector3::new(0.0, -1.0, 0.0)));
    }
}
