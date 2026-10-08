//! Deterministic transition-collision regression fixture.
//!
//! The former visual test map is not shipped or loaded at runtime. This
//! test-only module converts its retained collision faces into the recovered
//! TU3 sphere/triangle input layout; it contains no analytic ramp snap or
//! transition controller.

#![allow(dead_code)]

use serde::Deserialize;

use crate::skateboard_body::{
    Vector3,
    retail_collision::{
        RetailGpSphere, RetailGpTriangle, RetailGpTriangleFeature, RetailSphereTriangleContact,
        intersect_sphere_triangle, triangle_flags,
    },
};

const EMBEDDED_COLLIDER: &str =
    include_str!("../assets/transition/two_quarter_pipe_transition_test.collider.json");

#[derive(Clone, Debug, PartialEq)]
pub struct TransitionTestTerrain {
    pub triangles: Vec<RetailGpTriangleFeature>,
    pub surface_ids: Vec<u16>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RetailTerrainWheelCandidate {
    pub triangle_index: usize,
    pub surface_id: u16,
    pub contact: RetailSphereTriangleContact,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TransitionTerrainError {
    InvalidJson(String),
    UnsupportedSchema(u32),
    NonFiniteVertex { object: String, vertex: usize },
    TriangleIndexOutOfBounds { object: String, triangle: usize },
    DegenerateTriangle { object: String, triangle: usize },
    InvalidSurface { object: String },
}

#[derive(Deserialize)]
struct Fixture {
    schema: u32,
    objects: Vec<FixtureObject>,
}

#[derive(Deserialize)]
struct FixtureObject {
    source_object: String,
    skate_surface: FixtureSurface,
    vertices: Vec<[f32; 3]>,
    triangles: Vec<[u32; 3]>,
}

#[derive(Deserialize)]
struct FixtureSurface {
    audio: u8,
    physics: u8,
    pattern: u8,
    packed: u16,
}

impl TransitionTestTerrain {
    pub fn load_embedded() -> Result<Self, TransitionTerrainError> {
        Self::from_json(EMBEDDED_COLLIDER)
    }

    pub fn from_json(json: &str) -> Result<Self, TransitionTerrainError> {
        let fixture: Fixture = serde_json::from_str(json)
            .map_err(|error| TransitionTerrainError::InvalidJson(error.to_string()))?;
        if fixture.schema != 1 {
            return Err(TransitionTerrainError::UnsupportedSchema(fixture.schema));
        }

        let mut triangles = Vec::new();
        let mut surface_ids = Vec::new();
        for object in fixture.objects {
            let encoded_surface = u16::from(object.skate_surface.audio & 0x7f)
                | (u16::from(object.skate_surface.physics & 0x1f) << 7)
                | (u16::from(object.skate_surface.pattern & 0x0f) << 12);
            if object.skate_surface.audio > 0x7f
                || object.skate_surface.physics > 0x1f
                || object.skate_surface.pattern > 0x0f
                || object.skate_surface.packed != encoded_surface
            {
                return Err(TransitionTerrainError::InvalidSurface {
                    object: object.source_object,
                });
            }
            let vertices = object
                .vertices
                .iter()
                .enumerate()
                .map(|(index, vertex)| {
                    if !vertex.iter().all(|value| value.is_finite()) {
                        return Err(TransitionTerrainError::NonFiniteVertex {
                            object: object.source_object.clone(),
                            vertex: index,
                        });
                    }
                    Ok(Vector3::new(vertex[0], vertex[1], vertex[2]))
                })
                .collect::<Result<Vec<_>, _>>()?;

            for (triangle_index, indices) in object.triangles.iter().enumerate() {
                let [Some(vertex_0), Some(vertex_1), Some(vertex_2)] = indices.map(|index| {
                    usize::try_from(index)
                        .ok()
                        .and_then(|index| vertices.get(index).copied())
                }) else {
                    return Err(TransitionTerrainError::TriangleIndexOutOfBounds {
                        object: object.source_object.clone(),
                        triangle: triangle_index,
                    });
                };
                triangles.push(build_triangle(
                    vertex_0,
                    vertex_1,
                    vertex_2,
                    &object.source_object,
                    triangle_index,
                )?);
                surface_ids.push(encoded_surface);
            }
        }
        Ok(Self {
            triangles,
            surface_ids,
        })
    }

    /// Runs the complete recovered TU3 wheel-sphere/terrain-triangle face path
    /// against every authored riding triangle.
    ///
    /// This deliberately returns the raw primitive-pair candidates in fixture
    /// order. Contact reduction, persistence, and manifold ownership happen
    /// elsewhere in retail and remain evidence-gated; this routine does not
    /// select a "best" surface, snap the sphere, or synthesize a ramp normal.
    pub fn wheel_triangle_candidates(
        &self,
        wheel_center: Vector3,
        wheel_radius: f32,
        minimum_separating_distance: f32,
    ) -> Vec<RetailTerrainWheelCandidate> {
        let sphere = RetailGpSphere {
            position: wheel_center,
        };
        self.triangles
            .iter()
            .copied()
            .enumerate()
            .filter_map(|(triangle_index, triangle)| {
                intersect_sphere_triangle(
                    sphere,
                    wheel_radius,
                    triangle,
                    minimum_separating_distance,
                )
                .map(|contact| RetailTerrainWheelCandidate {
                    triangle_index,
                    surface_id: self.surface_ids[triangle_index],
                    contact,
                })
            })
            .collect()
    }
}

fn build_triangle(
    vertex_0: Vector3,
    vertex_1: Vector3,
    vertex_2: Vector3,
    object: &str,
    triangle: usize,
) -> Result<RetailGpTriangleFeature, TransitionTerrainError> {
    let edge_0 = subtract(vertex_2, vertex_0);
    let edge_1 = subtract(vertex_1, vertex_2);
    let edge_2 = subtract(vertex_0, vertex_1);
    let edge_lengths = [length(edge_0), length(edge_1), length(edge_2)];
    let normal = normalize(cross(subtract(vertex_1, vertex_0), edge_0)).ok_or_else(|| {
        TransitionTerrainError::DegenerateTriangle {
            object: object.to_owned(),
            triangle,
        }
    })?;
    let edge_directions = [
        scale(edge_0, edge_lengths[0].recip()),
        scale(edge_1, edge_lengths[1].recip()),
        scale(edge_2, edge_lengths[2].recip()),
    ];

    Ok(RetailGpTriangleFeature {
        triangle: RetailGpTriangle {
            vertex_0,
            vertex_1,
            vertex_2,
        },
        normal,
        edge_directions,
        edge_lengths,
        // The recovered wheel/terrain face path never reads edge cosines.
        // Poisoning them prevents an unresolved edge/vertex path from
        // accidentally treating placeholder metadata as evidence.
        edge_cosines: [f32::NAN; 3],
        flags: triangle_flags::ONE_SIDED,
        fatness: 0.0,
    })
}

fn subtract(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(left.x - right.x, left.y - right.y, left.z - right.z)
}

fn scale(value: Vector3, scalar: f32) -> Vector3 {
    Vector3::new(value.x * scalar, value.y * scalar, value.z * scalar)
}

fn cross(left: Vector3, right: Vector3) -> Vector3 {
    Vector3::new(
        left.y * right.z - left.z * right.y,
        left.z * right.x - left.x * right.z,
        left.x * right.y - left.y * right.x,
    )
}

fn length(value: Vector3) -> f32 {
    (value.x * value.x + value.y * value.y + value.z * value.z).sqrt()
}

fn normalize(value: Vector3) -> Option<Vector3> {
    let magnitude = length(value);
    (magnitude > f32::EPSILON).then(|| scale(value, magnitude.recip()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skateboard_body::{RETAIL_PHYSICS_DEFAULTS, RETAIL_WHEEL_RADIUS};

    fn add(left: Vector3, right: Vector3) -> Vector3 {
        Vector3::new(left.x + right.x, left.y + right.y, left.z + right.z)
    }

    fn triangle_centroid(triangle: RetailGpTriangle) -> Vector3 {
        scale(
            add(add(triangle.vertex_0, triangle.vertex_1), triangle.vertex_2),
            1.0 / 3.0,
        )
    }

    fn dot(left: Vector3, right: Vector3) -> f32 {
        left.x * right.x + left.y * right.y + left.z * right.z
    }

    #[test]
    fn embedded_blender_fixture_is_finite_non_degenerate_and_up_facing() {
        let terrain = TransitionTestTerrain::load_embedded().unwrap();

        assert_eq!(terrain.triangles.len(), 314);
        assert_eq!(terrain.surface_ids.len(), terrain.triangles.len());
        assert!(terrain.surface_ids.iter().all(|surface| *surface == 131));
        assert!(terrain.triangles.iter().all(|triangle| {
            triangle.normal.x.is_finite()
                && triangle.normal.y.is_finite()
                && triangle.normal.z.is_finite()
                && triangle.normal.y > 0.0
        }));
    }

    #[test]
    fn center_flat_and_both_vertical_lips_are_present() {
        let terrain = TransitionTestTerrain::load_embedded().unwrap();
        let has_center_flat = terrain.triangles.iter().any(|triangle| {
            triangle.normal.y > 0.999_999
                && triangle
                    .triangle
                    .vertex_0
                    .z
                    .min(triangle.triangle.vertex_1.z)
                    .min(triangle.triangle.vertex_2.z)
                    <= 0.0
                && triangle
                    .triangle
                    .vertex_0
                    .z
                    .max(triangle.triangle.vertex_1.z)
                    .max(triangle.triangle.vertex_2.z)
                    >= 0.0
        });
        let lip_threshold = 0.999;
        let has_negative_lip = terrain.triangles.iter().any(|triangle| {
            triangle.normal.z > lip_threshold
                && [
                    triangle.triangle.vertex_0,
                    triangle.triangle.vertex_1,
                    triangle.triangle.vertex_2,
                ]
                .iter()
                .any(|vertex| vertex.z < -14.49 && vertex.y > 2.49)
        });
        let has_positive_lip = terrain.triangles.iter().any(|triangle| {
            triangle.normal.z < -lip_threshold
                && [
                    triangle.triangle.vertex_0,
                    triangle.triangle.vertex_1,
                    triangle.triangle.vertex_2,
                ]
                .iter()
                .any(|vertex| vertex.z > 14.49 && vertex.y > 2.49)
        });

        assert!(has_center_flat);
        assert!(has_negative_lip);
        assert!(has_positive_lip);
    }

    #[test]
    fn unresolved_edge_metadata_is_not_silently_populated() {
        let terrain = TransitionTestTerrain::load_embedded().unwrap();
        assert!(terrain.triangles.iter().all(|triangle| {
            triangle.flags == triangle_flags::ONE_SIDED
                && triangle.edge_cosines.iter().all(|value| value.is_nan())
        }));
    }

    #[test]
    fn every_authored_riding_face_reaches_the_recovered_wheel_pair_path() {
        let terrain = TransitionTestTerrain::load_embedded().unwrap();

        for (triangle_index, triangle) in terrain.triangles.iter().copied().enumerate() {
            let center = add(
                triangle_centroid(triangle.triangle),
                scale(triangle.normal, RETAIL_WHEEL_RADIUS),
            );
            let candidates = terrain.wheel_triangle_candidates(
                center,
                RETAIL_WHEEL_RADIUS,
                RETAIL_PHYSICS_DEFAULTS.simulation_padding,
            );
            let source = candidates
                .iter()
                .find(|candidate| candidate.triangle_index == triangle_index)
                .unwrap_or_else(|| {
                    panic!("triangle {triangle_index} did not produce its wheel contact")
                });

            assert!(
                source.contact.distance.abs() <= 2.0e-6,
                "triangle {triangle_index} contact distance was {}",
                source.contact.distance
            );
            assert!(
                dot(source.contact.normal, triangle.normal) < -0.999_999,
                "triangle {triangle_index} returned a non-retail normal"
            );
        }
    }

    #[test]
    fn center_spawn_wheel_uses_flat_geometry_not_an_analytic_ground_plane() {
        let terrain = TransitionTestTerrain::load_embedded().unwrap();
        let candidates = terrain.wheel_triangle_candidates(
            Vector3::new(0.0, RETAIL_WHEEL_RADIUS, 0.0),
            RETAIL_WHEEL_RADIUS,
            RETAIL_PHYSICS_DEFAULTS.simulation_padding,
        );

        assert!(!candidates.is_empty());
        assert!(candidates.iter().any(|candidate| {
            candidate.surface_id == 131
                && candidate.contact.normal.y < -0.999_999
                && candidate.contact.point_on_triangle.y.abs() <= 1.0e-6
        }));
    }

    #[test]
    fn native_surface_channels_must_match_their_packed_renderware_id() {
        let invalid = r#"{
            "schema": 1,
            "objects": [{
                "source_object": "invalid",
                "skate_surface": {
                    "audio": 3,
                    "physics": 1,
                    "pattern": 0,
                    "packed": 130
                },
                "vertices": [[0, 0, 0], [1, 0, 0], [0, 0, 1]],
                "triangles": [[0, 2, 1]]
            }]
        }"#;

        assert_eq!(
            TransitionTestTerrain::from_json(invalid),
            Err(TransitionTerrainError::InvalidSurface {
                object: "invalid".to_owned()
            })
        );
    }

    #[test]
    fn retail_padding_rejects_faces_outside_its_exact_candidate_distance() {
        let terrain = TransitionTestTerrain::load_embedded().unwrap();
        let triangle_index = terrain
            .triangles
            .iter()
            .position(|triangle| {
                triangle.normal.y > 0.999_999 && triangle_centroid(triangle.triangle).z.abs() < 1.0
            })
            .unwrap();
        let triangle = terrain.triangles[triangle_index];
        let center = add(
            triangle_centroid(triangle.triangle),
            scale(
                triangle.normal,
                RETAIL_WHEEL_RADIUS + RETAIL_PHYSICS_DEFAULTS.simulation_padding + 1.0e-4,
            ),
        );
        let candidates = terrain.wheel_triangle_candidates(
            center,
            RETAIL_WHEEL_RADIUS,
            RETAIL_PHYSICS_DEFAULTS.simulation_padding,
        );

        assert!(
            candidates
                .iter()
                .all(|candidate| candidate.triangle_index != triangle_index)
        );
    }
}
