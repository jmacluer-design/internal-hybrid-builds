//! Deterministic analytic ground and surface queries.
//!
//! Evidence classification:
//! - Observed: TU3 `SurfaceQuery::GetResult` (`0x82D76F80`) separates query
//!   completion from contact validity and emits a contact position, a second
//!   vector of unresolved retail meaning, a 32-bit value, and a validity byte.
//! - Observed: `Skateboard::CalculateGroundPos` (`0x82C02840`) combines four
//!   transformed candidate points with a `0.25` scalar.
//! - Derived: the second result vector is represented at the port boundary as
//!   a contact normal; later board integration will need repeatable point,
//!   normal, surface identity, and contact-transition data without embedding
//!   a rigid body response in the query provider.
//! - Inferred: synchronous analytic queries, insertion-order tie breaking,
//!   two-sided primitives, Y-down convenience probes, and immediate
//!   acquire/loss transitions are port-side contracts. They are not claimed
//!   as retail Skate 3 constants or hysteresis rules.
//!
//! The two numeric tolerances below are implementation-only floating-point
//! guards. Neither value was recovered from the retail executable.
#![allow(dead_code)] // Standalone provider; central board integration is pending.

use std::{
    collections::HashMap,
    ops::{Add, Mul, Neg, Sub},
};

const NORMAL_MIN_LENGTH_SQUARED: f32 = 1.0e-12;
const INTERSECTION_EPSILON: f32 = 1.0e-6;

/// Minimal dependency-free vector used at the provider boundary.
///
/// Keeping the module independent of Bevy lets it be compiled and tested
/// before central integration. A later adapter can convert this type to the
/// engine's vector type without changing query semantics.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GroundVec3 {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl GroundVec3 {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0);
    pub const Y: Self = Self::new(0.0, 1.0, 0.0);
    pub const NEG_Y: Self = Self::new(0.0, -1.0, 0.0);

    pub const fn new(x: f32, y: f32, z: f32) -> Self {
        Self { x, y, z }
    }

    pub const fn to_array(self) -> [f32; 3] {
        [self.x, self.y, self.z]
    }

    pub fn is_finite(self) -> bool {
        self.x.is_finite() && self.y.is_finite() && self.z.is_finite()
    }

    pub fn dot(self, other: Self) -> f32 {
        self.x * other.x + self.y * other.y + self.z * other.z
    }

    pub fn cross(self, other: Self) -> Self {
        Self::new(
            self.y * other.z - self.z * other.y,
            self.z * other.x - self.x * other.z,
            self.x * other.y - self.y * other.x,
        )
    }

    pub fn length_squared(self) -> f32 {
        self.dot(self)
    }

    pub fn length(self) -> f32 {
        self.length_squared().sqrt()
    }

    pub fn normalized(self) -> Option<Self> {
        let length_squared = self.length_squared();
        if !length_squared.is_finite() || length_squared <= NORMAL_MIN_LENGTH_SQUARED {
            return None;
        }
        Some(self * length_squared.sqrt().recip())
    }

    pub fn is_unit(self, tolerance: f32) -> bool {
        self.is_finite()
            && tolerance.is_finite()
            && tolerance >= 0.0
            && (self.length_squared() - 1.0).abs() <= tolerance
    }
}

impl From<[f32; 3]> for GroundVec3 {
    fn from(value: [f32; 3]) -> Self {
        Self::new(value[0], value[1], value[2])
    }
}

impl From<GroundVec3> for [f32; 3] {
    fn from(value: GroundVec3) -> Self {
        value.to_array()
    }
}

impl Add for GroundVec3 {
    type Output = Self;

    fn add(self, rhs: Self) -> Self::Output {
        Self::new(self.x + rhs.x, self.y + rhs.y, self.z + rhs.z)
    }
}

impl Sub for GroundVec3 {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self::Output {
        Self::new(self.x - rhs.x, self.y - rhs.y, self.z - rhs.z)
    }
}

impl Mul<f32> for GroundVec3 {
    type Output = Self;

    fn mul(self, rhs: f32) -> Self::Output {
        Self::new(self.x * rhs, self.y * rhs, self.z * rhs)
    }
}

impl Neg for GroundVec3 {
    type Output = Self;

    fn neg(self) -> Self::Output {
        Self::new(-self.x, -self.y, -self.z)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SurfaceId(pub u32);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PrimitiveId(pub u32);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GroundGeometryError {
    NonFiniteInput,
    ZeroLengthDirection,
    NegativeMaxDistance,
    ZeroLengthNormal,
    DegenerateTriangle,
    TooManyPrimitives,
    InvalidBroadphaseCellSize,
}

/// A normalized finite segment-like ray used for an analytic surface query.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct GroundProbe {
    pub origin: GroundVec3,
    pub direction: GroundVec3,
    pub max_distance: f32,
}

impl GroundProbe {
    pub fn new(
        origin: GroundVec3,
        direction: GroundVec3,
        max_distance: f32,
    ) -> Result<Self, GroundGeometryError> {
        if !origin.is_finite() || !direction.is_finite() || !max_distance.is_finite() {
            return Err(GroundGeometryError::NonFiniteInput);
        }
        if max_distance < 0.0 {
            return Err(GroundGeometryError::NegativeMaxDistance);
        }
        let direction = direction
            .normalized()
            .ok_or(GroundGeometryError::ZeroLengthDirection)?;
        Ok(Self {
            origin,
            direction,
            max_distance,
        })
    }

    /// Convenience for this project's Y-up coordinate convention.
    pub fn downward(origin: GroundVec3, max_distance: f32) -> Result<Self, GroundGeometryError> {
        Self::new(origin, GroundVec3::NEG_Y, max_distance)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnalyticPlane {
    pub point: GroundVec3,
    pub normal: GroundVec3,
    pub surface_id: SurfaceId,
}

impl AnalyticPlane {
    pub fn new(
        point: GroundVec3,
        normal: GroundVec3,
        surface_id: SurfaceId,
    ) -> Result<Self, GroundGeometryError> {
        if !point.is_finite() || !normal.is_finite() {
            return Err(GroundGeometryError::NonFiniteInput);
        }
        let normal = normal
            .normalized()
            .ok_or(GroundGeometryError::ZeroLengthNormal)?;
        Ok(Self {
            point,
            normal,
            surface_id,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AnalyticTriangle {
    pub a: GroundVec3,
    pub b: GroundVec3,
    pub c: GroundVec3,
    pub normal: GroundVec3,
    pub surface_id: SurfaceId,
}

impl AnalyticTriangle {
    pub fn new(
        a: GroundVec3,
        b: GroundVec3,
        c: GroundVec3,
        surface_id: SurfaceId,
    ) -> Result<Self, GroundGeometryError> {
        if !a.is_finite() || !b.is_finite() || !c.is_finite() {
            return Err(GroundGeometryError::NonFiniteInput);
        }
        let normal = (b - a)
            .cross(c - a)
            .normalized()
            .ok_or(GroundGeometryError::DegenerateTriangle)?;
        Ok(Self {
            a,
            b,
            c,
            normal,
            surface_id,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum AnalyticSurface {
    Plane(AnalyticPlane),
    Triangle(AnalyticTriangle),
}

impl AnalyticSurface {
    pub fn surface_id(self) -> SurfaceId {
        match self {
            Self::Plane(plane) => plane.surface_id,
            Self::Triangle(triangle) => triangle.surface_id,
        }
    }
}

/// Contact payload modeled after the fields observed in `SurfaceQueryResult`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceContact {
    pub point: GroundVec3,
    pub normal: GroundVec3,
    pub distance: f32,
    pub surface_id: SurfaceId,
    pub primitive_id: PrimitiveId,
    /// Retail collision material identity, when supplied by an imported mesh.
    pub material_id: Option<u32>,
    /// Portable collision mesh/surface identity before material classification.
    pub source_surface_id: Option<u32>,
    /// Native retail edge/corner classifications, when present.
    pub native_edge_codes: Option<[u8; 3]>,
    /// Present for triangle hits as weights for `(a, b, c)`.
    pub barycentric: Option<[f32; 3]>,
}

impl SurfaceContact {
    pub fn normal_is_valid(self, tolerance: f32) -> bool {
        self.normal.is_unit(tolerance)
    }
}

/// Query completion is deliberately distinct from contact validity.
///
/// This mirrors the observed `SurfaceQuery::GetResult` behavior: its Boolean
/// return reports whether a result can be consumed, while the result payload
/// carries a separate validity byte.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SurfaceQueryResult {
    completed: bool,
    contact: Option<SurfaceContact>,
}

impl SurfaceQueryResult {
    pub const fn pending() -> Self {
        Self {
            completed: false,
            contact: None,
        }
    }

    pub const fn completed(contact: Option<SurfaceContact>) -> Self {
        Self {
            completed: true,
            contact,
        }
    }

    pub const fn completed_miss() -> Self {
        Self::completed(None)
    }

    pub const fn is_completed(self) -> bool {
        self.completed
    }

    pub const fn has_contact(self) -> bool {
        self.completed && self.contact.is_some()
    }

    pub const fn contact(self) -> Option<SurfaceContact> {
        self.contact
    }
}

/// Insertion-ordered collection of deterministic analytic surfaces.
#[derive(Clone, Debug, PartialEq)]
pub struct GroundProvider {
    surfaces: Vec<AnalyticSurface>,
    indexed_meshes: Vec<IndexedTriangleMesh>,
}

impl GroundProvider {
    pub const fn new() -> Self {
        Self {
            surfaces: Vec::new(),
            indexed_meshes: Vec::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.surfaces.len()
            + self
                .indexed_meshes
                .iter()
                .map(|mesh| mesh.triangles.len())
                .sum::<usize>()
    }

    pub fn is_empty(&self) -> bool {
        self.surfaces.is_empty() && self.indexed_meshes.is_empty()
    }

    pub fn surfaces(&self) -> &[AnalyticSurface] {
        &self.surfaces
    }

    pub fn add_surface(
        &mut self,
        surface: AnalyticSurface,
    ) -> Result<PrimitiveId, GroundGeometryError> {
        let index = u32::try_from(self.surfaces.len())
            .map_err(|_| GroundGeometryError::TooManyPrimitives)?;
        self.surfaces.push(surface);
        Ok(PrimitiveId(index))
    }

    pub fn add_plane(
        &mut self,
        point: GroundVec3,
        normal: GroundVec3,
        surface_id: SurfaceId,
    ) -> Result<PrimitiveId, GroundGeometryError> {
        self.add_surface(AnalyticSurface::Plane(AnalyticPlane::new(
            point, normal, surface_id,
        )?))
    }

    pub fn add_triangle(
        &mut self,
        a: GroundVec3,
        b: GroundVec3,
        c: GroundVec3,
        surface_id: SurfaceId,
    ) -> Result<PrimitiveId, GroundGeometryError> {
        self.add_surface(AnalyticSurface::Triangle(AnalyticTriangle::new(
            a, b, c, surface_id,
        )?))
    }

    /// Adds an unchanged imported collision mesh behind a deterministic XZ
    /// broadphase. Triangle order remains the package order, preserving the
    /// provider's first-insertion seam policy.
    pub fn add_indexed_triangle_mesh(
        &mut self,
        triangles: Vec<ImportedCollisionTriangle>,
        cell_size: f32,
    ) -> Result<(), GroundGeometryError> {
        let existing = self.len();
        let total = existing
            .checked_add(triangles.len())
            .ok_or(GroundGeometryError::TooManyPrimitives)?;
        u32::try_from(total).map_err(|_| GroundGeometryError::TooManyPrimitives)?;
        self.indexed_meshes
            .push(IndexedTriangleMesh::new(triangles, cell_size)?);
        Ok(())
    }

    /// Runs a synchronous analytic query.
    ///
    /// The closest non-negative hit wins. Exact distance ties keep the surface
    /// inserted first, providing a stable seam policy without claiming a
    /// retail broadphase ordering rule.
    pub fn query(&self, probe: GroundProbe) -> SurfaceQueryResult {
        let mut closest: Option<SurfaceContact> = None;

        for (index, surface) in self.surfaces.iter().copied().enumerate() {
            let primitive_id = PrimitiveId(index as u32);
            let candidate = match surface {
                AnalyticSurface::Plane(plane) => intersect_plane(probe, plane, primitive_id),
                AnalyticSurface::Triangle(triangle) => {
                    intersect_triangle(probe, triangle, primitive_id, None, None, None)
                }
            };

            if let Some(candidate) = candidate {
                let replace = closest
                    .map(|current| candidate.distance < current.distance)
                    .unwrap_or(true);
                if replace {
                    closest = Some(candidate);
                }
            }
        }

        let mut primitive_base = self.surfaces.len();
        for mesh in &self.indexed_meshes {
            for index in mesh.candidate_indices(probe) {
                let source = mesh.triangles[index as usize];
                let primitive_id = PrimitiveId((primitive_base + index as usize) as u32);
                let candidate = intersect_triangle(
                    probe,
                    source.triangle,
                    primitive_id,
                    Some(source.material_id),
                    Some(source.source_surface_id),
                    source.native_edge_codes,
                );
                if let Some(candidate) = candidate {
                    let replace = closest
                        .map(|current| candidate.distance < current.distance)
                        .unwrap_or(true);
                    if replace {
                        closest = Some(candidate);
                    }
                }
            }
            primitive_base += mesh.triangles.len();
        }

        SurfaceQueryResult::completed(closest)
    }

    pub fn query_down(
        &self,
        origin: GroundVec3,
        max_distance: f32,
    ) -> Result<SurfaceQueryResult, GroundGeometryError> {
        Ok(self.query(GroundProbe::downward(origin, max_distance)?))
    }

    pub fn calculate_ground_position(
        &self,
        origin: GroundVec3,
        max_distance: f32,
    ) -> Result<Option<GroundVec3>, GroundGeometryError> {
        Ok(self
            .query_down(origin, max_distance)?
            .contact()
            .map(|contact| contact.point))
    }
}

impl Default for GroundProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ImportedCollisionTriangle {
    pub triangle: AnalyticTriangle,
    pub material_id: u32,
    pub source_surface_id: u32,
    pub native_edge_codes: Option<[u8; 3]>,
}

impl ImportedCollisionTriangle {
    pub fn new(
        a: GroundVec3,
        b: GroundVec3,
        c: GroundVec3,
        surface_id: SurfaceId,
        material_id: u32,
        source_surface_id: u32,
        native_edge_codes: Option<[u8; 3]>,
    ) -> Result<Self, GroundGeometryError> {
        Ok(Self {
            triangle: AnalyticTriangle::new(a, b, c, surface_id)?,
            material_id,
            source_surface_id,
            native_edge_codes,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
struct IndexedTriangleMesh {
    triangles: Vec<ImportedCollisionTriangle>,
    cell_size: f32,
    cells: HashMap<(i32, i32), Vec<u32>>,
}

impl IndexedTriangleMesh {
    fn new(
        triangles: Vec<ImportedCollisionTriangle>,
        cell_size: f32,
    ) -> Result<Self, GroundGeometryError> {
        if !cell_size.is_finite() || cell_size <= 0.0 {
            return Err(GroundGeometryError::InvalidBroadphaseCellSize);
        }
        let mut cells: HashMap<(i32, i32), Vec<u32>> = HashMap::new();
        for (index, source) in triangles.iter().enumerate() {
            let triangle = source.triangle;
            let minimum_x = triangle.a.x.min(triangle.b.x).min(triangle.c.x);
            let maximum_x = triangle.a.x.max(triangle.b.x).max(triangle.c.x);
            let minimum_z = triangle.a.z.min(triangle.b.z).min(triangle.c.z);
            let maximum_z = triangle.a.z.max(triangle.b.z).max(triangle.c.z);
            let first_x = cell_coordinate(minimum_x, cell_size);
            let last_x = cell_coordinate(maximum_x, cell_size);
            let first_z = cell_coordinate(minimum_z, cell_size);
            let last_z = cell_coordinate(maximum_z, cell_size);
            for x in first_x..=last_x {
                for z in first_z..=last_z {
                    cells.entry((x, z)).or_default().push(index as u32);
                }
            }
        }
        Ok(Self {
            triangles,
            cell_size,
            cells,
        })
    }

    fn candidate_indices(&self, probe: GroundProbe) -> CandidateIndices<'_> {
        let end = probe.origin + probe.direction * probe.max_distance;
        let mut cell = (
            cell_coordinate(probe.origin.x, self.cell_size),
            cell_coordinate(probe.origin.z, self.cell_size),
        );
        let end_cell = (
            cell_coordinate(end.x, self.cell_size),
            cell_coordinate(end.z, self.cell_size),
        );
        if cell == end_cell {
            CandidateIndices::Cell(self.cells.get(&cell).map(Vec::as_slice).unwrap_or_default())
        } else {
            // Traverse the XZ grid cells crossed by the finite probe segment.
            // Imported triangles are indexed into every cell touched by their
            // XZ bounds, so this remains conservative while avoiding the old
            // all-triangle path for slanted transition and camera probes.
            let delta_x = end.x - probe.origin.x;
            let delta_z = end.z - probe.origin.z;
            let step_x = if delta_x > 0.0 {
                1
            } else if delta_x < 0.0 {
                -1
            } else {
                0
            };
            let step_z = if delta_z > 0.0 {
                1
            } else if delta_z < 0.0 {
                -1
            } else {
                0
            };
            let t_delta_x = if step_x == 0 {
                f32::INFINITY
            } else {
                self.cell_size / delta_x.abs()
            };
            let t_delta_z = if step_z == 0 {
                f32::INFINITY
            } else {
                self.cell_size / delta_z.abs()
            };
            let next_x = if step_x > 0 {
                (cell.0 + 1) as f32 * self.cell_size
            } else {
                cell.0 as f32 * self.cell_size
            };
            let next_z = if step_z > 0 {
                (cell.1 + 1) as f32 * self.cell_size
            } else {
                cell.1 as f32 * self.cell_size
            };
            let mut t_max_x = if step_x == 0 {
                f32::INFINITY
            } else {
                (next_x - probe.origin.x) / delta_x
            };
            let mut t_max_z = if step_z == 0 {
                f32::INFINITY
            } else {
                (next_z - probe.origin.z) / delta_z
            };
            let mut candidates = Vec::new();
            loop {
                self.extend_cell_candidates(cell, &mut candidates);
                if cell == end_cell {
                    break;
                }
                if t_max_x < t_max_z {
                    cell.0 += step_x;
                    t_max_x += t_delta_x;
                } else if t_max_z < t_max_x {
                    cell.1 += step_z;
                    t_max_z += t_delta_z;
                } else {
                    // At an exact grid corner, include both side-adjacent
                    // cells before advancing diagonally. This keeps contacts
                    // whose triangle bounds terminate exactly on the corner.
                    self.extend_cell_candidates((cell.0 + step_x, cell.1), &mut candidates);
                    self.extend_cell_candidates((cell.0, cell.1 + step_z), &mut candidates);
                    cell.0 += step_x;
                    cell.1 += step_z;
                    t_max_x += t_delta_x;
                    t_max_z += t_delta_z;
                }
            }
            // A large triangle can occupy several traversed cells. Restore
            // package order and visit it once, preserving deterministic
            // first-insertion seam ties.
            candidates.sort_unstable();
            candidates.dedup();
            CandidateIndices::Segment(candidates.into_iter())
        }
    }

    fn extend_cell_candidates(&self, cell: (i32, i32), candidates: &mut Vec<u32>) {
        if let Some(indices) = self.cells.get(&cell) {
            candidates.extend_from_slice(indices);
        }
    }
}

enum CandidateIndices<'a> {
    Cell(&'a [u32]),
    Segment(std::vec::IntoIter<u32>),
}

impl Iterator for CandidateIndices<'_> {
    type Item = u32;

    fn next(&mut self) -> Option<Self::Item> {
        match self {
            Self::Cell(indices) => {
                let (first, rest) = indices.split_first()?;
                *indices = rest;
                Some(*first)
            }
            Self::Segment(indices) => indices.next(),
        }
    }
}

fn cell_coordinate(value: f32, cell_size: f32) -> i32 {
    (value / cell_size).floor() as i32
}

fn intersect_plane(
    probe: GroundProbe,
    plane: AnalyticPlane,
    primitive_id: PrimitiveId,
) -> Option<SurfaceContact> {
    let denominator = plane.normal.dot(probe.direction);
    if denominator.abs() <= INTERSECTION_EPSILON {
        return None;
    }

    let distance = (plane.point - probe.origin).dot(plane.normal) / denominator;
    let distance = bounded_distance(distance, probe.max_distance)?;
    let point = probe.origin + probe.direction * distance;
    let normal = normal_opposing_direction(plane.normal, probe.direction);

    Some(SurfaceContact {
        point,
        normal,
        distance,
        surface_id: plane.surface_id,
        primitive_id,
        material_id: None,
        source_surface_id: None,
        native_edge_codes: None,
        barycentric: None,
    })
}

fn intersect_triangle(
    probe: GroundProbe,
    triangle: AnalyticTriangle,
    primitive_id: PrimitiveId,
    material_id: Option<u32>,
    source_surface_id: Option<u32>,
    native_edge_codes: Option<[u8; 3]>,
) -> Option<SurfaceContact> {
    let edge_ab = triangle.b - triangle.a;
    let edge_ac = triangle.c - triangle.a;
    let perpendicular = probe.direction.cross(edge_ac);
    let determinant = edge_ab.dot(perpendicular);
    if determinant.abs() <= INTERSECTION_EPSILON {
        return None;
    }

    let inverse_determinant = determinant.recip();
    let from_a = probe.origin - triangle.a;
    let weight_b = from_a.dot(perpendicular) * inverse_determinant;
    if !(-INTERSECTION_EPSILON..=1.0 + INTERSECTION_EPSILON).contains(&weight_b) {
        return None;
    }

    let cross = from_a.cross(edge_ab);
    let weight_c = probe.direction.dot(cross) * inverse_determinant;
    if weight_c < -INTERSECTION_EPSILON || weight_b + weight_c > 1.0 + INTERSECTION_EPSILON {
        return None;
    }

    let distance = edge_ac.dot(cross) * inverse_determinant;
    let distance = bounded_distance(distance, probe.max_distance)?;
    let point = probe.origin + probe.direction * distance;
    let normal = normal_opposing_direction(triangle.normal, probe.direction);
    let barycentric = canonicalize_barycentric([1.0 - weight_b - weight_c, weight_b, weight_c]);

    Some(SurfaceContact {
        point,
        normal,
        distance,
        surface_id: triangle.surface_id,
        primitive_id,
        material_id,
        source_surface_id,
        native_edge_codes,
        barycentric: Some(barycentric),
    })
}

fn bounded_distance(distance: f32, max_distance: f32) -> Option<f32> {
    if !distance.is_finite()
        || distance < -INTERSECTION_EPSILON
        || distance > max_distance + INTERSECTION_EPSILON
    {
        return None;
    }
    if distance <= 0.0 {
        Some(0.0)
    } else {
        Some(distance.min(max_distance))
    }
}

fn normal_opposing_direction(normal: GroundVec3, direction: GroundVec3) -> GroundVec3 {
    if normal.dot(direction) > 0.0 {
        -normal
    } else {
        normal
    }
}

fn canonicalize_barycentric(mut weights: [f32; 3]) -> [f32; 3] {
    for weight in &mut weights {
        *weight = weight.clamp(0.0, 1.0);
    }
    let sum = weights[0] + weights[1] + weights[2];
    if sum > 0.0 {
        let inverse_sum = sum.recip();
        for weight in &mut weights {
            *weight *= inverse_sum;
        }
    }
    weights
}

/// Port-side contact lifecycle with no hidden hysteresis.
///
/// Immediate transitions are intentionally modest: the TU3 evidence proves
/// that completion and validity are separate, but it does not yet prove retail
/// release distances, grace frames, or reacquisition thresholds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ContactTransition {
    Pending,
    RemainedAirborne,
    Acquired,
    Maintained,
    Lost,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct GroundStateTracker {
    contact: Option<SurfaceContact>,
}

impl GroundStateTracker {
    pub const fn new() -> Self {
        Self { contact: None }
    }

    pub const fn is_grounded(self) -> bool {
        self.contact.is_some()
    }

    pub const fn contact(self) -> Option<SurfaceContact> {
        self.contact
    }

    pub fn observe(&mut self, result: SurfaceQueryResult) -> ContactTransition {
        if !result.is_completed() {
            return ContactTransition::Pending;
        }

        match (self.contact, result.contact()) {
            (None, None) => ContactTransition::RemainedAirborne,
            (None, Some(contact)) => {
                self.contact = Some(contact);
                ContactTransition::Acquired
            }
            (Some(_), Some(contact)) => {
                self.contact = Some(contact);
                ContactTransition::Maintained
            }
            (Some(_), None) => {
                self.contact = None;
                ContactTransition::Lost
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_TOLERANCE: f32 = 1.0e-5;

    fn assert_close(actual: f32, expected: f32) {
        assert!(
            (actual - expected).abs() <= TEST_TOLERANCE,
            "actual={actual:?}, expected={expected:?}"
        );
    }

    fn assert_vec_close(actual: GroundVec3, expected: GroundVec3) {
        assert_close(actual.x, expected.x);
        assert_close(actual.y, expected.y);
        assert_close(actual.z, expected.z);
    }

    fn contact_for(
        provider: &GroundProvider,
        origin: GroundVec3,
        max_distance: f32,
    ) -> SurfaceContact {
        provider
            .query_down(origin, max_distance)
            .expect("valid downward query")
            .contact()
            .expect("expected contact")
    }

    #[test]
    fn level_ground_returns_point_unit_normal_and_surface_identity() {
        let mut provider = GroundProvider::new();
        let primitive = provider
            .add_plane(GroundVec3::ZERO, GroundVec3::Y, SurfaceId(17))
            .expect("valid level plane");

        let result = provider
            .query_down(GroundVec3::new(2.0, 3.0, -4.0), 5.0)
            .expect("valid probe");
        let contact = result.contact().expect("level-ground contact");

        assert!(result.is_completed());
        assert!(result.has_contact());
        assert_eq!(contact.surface_id, SurfaceId(17));
        assert_eq!(contact.primitive_id, primitive);
        assert_eq!(contact.barycentric, None);
        assert_vec_close(contact.point, GroundVec3::new(2.0, 0.0, -4.0));
        assert_vec_close(contact.normal, GroundVec3::Y);
        assert_close(contact.distance, 3.0);
        assert!(contact.normal_is_valid(TEST_TOLERANCE));
    }

    #[test]
    fn positive_and_negative_five_and_fifteen_degree_slopes_are_analytic() {
        for angle_degrees in [-15.0_f32, -5.0, 5.0, 15.0] {
            let angle = angle_degrees.to_radians();
            let normal = GroundVec3::new(-angle.sin(), angle.cos(), 0.0);
            let mut provider = GroundProvider::new();
            provider
                .add_plane(GroundVec3::ZERO, normal, SurfaceId(1))
                .expect("valid slope");

            let x = 2.0;
            let expected_height = angle.tan() * x;
            let contact = contact_for(&provider, GroundVec3::new(x, 5.0, 0.75), 10.0);

            assert_close(contact.point.y, expected_height);
            assert_vec_close(contact.normal, normal);
            assert_close(contact.distance, 5.0 - expected_height);
            assert!(contact.normal_is_valid(TEST_TOLERANCE));
        }
    }

    #[test]
    fn bank_changes_height_across_lateral_axis_and_returns_bank_normal() {
        let bank_angle = 15.0_f32.to_radians();
        let normal = GroundVec3::new(0.0, bank_angle.cos(), -bank_angle.sin());
        let mut provider = GroundProvider::new();
        provider
            .add_plane(GroundVec3::ZERO, normal, SurfaceId(23))
            .expect("valid bank");

        let lateral = 2.5;
        let expected_height = bank_angle.tan() * lateral;
        let contact = contact_for(&provider, GroundVec3::new(-3.0, 4.0, lateral), 8.0);

        assert_vec_close(
            contact.point,
            GroundVec3::new(-3.0, expected_height, lateral),
        );
        assert_vec_close(contact.normal, normal);
        assert_eq!(contact.surface_id, SurfaceId(23));
    }

    #[test]
    fn coplanar_triangle_seam_crossing_is_continuous_and_stable() {
        let mut provider = GroundProvider::new();
        provider
            .add_triangle(
                GroundVec3::new(-1.0, 0.0, -1.0),
                GroundVec3::new(1.0, 0.0, -1.0),
                GroundVec3::new(1.0, 0.0, 1.0),
                SurfaceId(7),
            )
            .expect("first seam triangle");
        provider
            .add_triangle(
                GroundVec3::new(-1.0, 0.0, -1.0),
                GroundVec3::new(1.0, 0.0, 1.0),
                GroundVec3::new(-1.0, 0.0, 1.0),
                SurfaceId(7),
            )
            .expect("second seam triangle");

        let first_side = contact_for(&provider, GroundVec3::new(0.25, 2.0, -0.25), 4.0);
        let seam = contact_for(&provider, GroundVec3::new(0.0, 2.0, 0.0), 4.0);
        let second_side = contact_for(&provider, GroundVec3::new(-0.25, 2.0, 0.25), 4.0);

        assert_eq!(first_side.primitive_id, PrimitiveId(0));
        assert_eq!(seam.primitive_id, PrimitiveId(0));
        assert_eq!(second_side.primitive_id, PrimitiveId(1));
        for contact in [first_side, seam, second_side] {
            assert_close(contact.point.y, 0.0);
            assert_vec_close(contact.normal, GroundVec3::Y);
            assert_eq!(contact.surface_id, SurfaceId(7));
            let weights = contact.barycentric.expect("triangle barycentrics");
            assert_close(weights[0] + weights[1] + weights[2], 1.0);
            assert!(
                weights
                    .into_iter()
                    .all(|weight| (0.0..=1.0).contains(&weight))
            );
        }
    }

    #[test]
    fn contact_loss_and_reacquisition_have_explicit_transitions() {
        let mut provider = GroundProvider::new();
        provider
            .add_triangle(
                GroundVec3::new(-1.0, 0.0, -1.0),
                GroundVec3::new(1.0, 0.0, -1.0),
                GroundVec3::new(0.0, 0.0, 1.0),
                SurfaceId(5),
            )
            .expect("finite support triangle");
        let mut tracker = GroundStateTracker::new();

        let inside = provider
            .query_down(GroundVec3::new(0.0, 1.0, 0.0), 2.0)
            .expect("inside query");
        assert_eq!(tracker.observe(inside), ContactTransition::Acquired);
        assert!(tracker.is_grounded());
        assert_eq!(tracker.observe(inside), ContactTransition::Maintained);

        assert_eq!(
            tracker.observe(SurfaceQueryResult::pending()),
            ContactTransition::Pending
        );
        assert!(tracker.is_grounded(), "pending query must preserve state");

        let outside = provider
            .query_down(GroundVec3::new(3.0, 1.0, 0.0), 2.0)
            .expect("outside query");
        assert!(outside.is_completed());
        assert!(!outside.has_contact());
        assert_eq!(tracker.observe(outside), ContactTransition::Lost);
        assert!(!tracker.is_grounded());
        assert_eq!(
            tracker.observe(outside),
            ContactTransition::RemainedAirborne
        );

        assert_eq!(tracker.observe(inside), ContactTransition::Acquired);
        assert!(tracker.is_grounded());
    }

    #[test]
    fn invalid_geometry_is_rejected_and_returned_normals_are_valid() {
        assert_eq!(
            AnalyticPlane::new(GroundVec3::ZERO, GroundVec3::ZERO, SurfaceId(1)),
            Err(GroundGeometryError::ZeroLengthNormal)
        );
        assert_eq!(
            AnalyticPlane::new(
                GroundVec3::new(f32::NAN, 0.0, 0.0),
                GroundVec3::Y,
                SurfaceId(1)
            ),
            Err(GroundGeometryError::NonFiniteInput)
        );
        assert_eq!(
            AnalyticTriangle::new(
                GroundVec3::ZERO,
                GroundVec3::new(1.0, 0.0, 0.0),
                GroundVec3::new(2.0, 0.0, 0.0),
                SurfaceId(1)
            ),
            Err(GroundGeometryError::DegenerateTriangle)
        );
        assert_eq!(
            GroundProbe::new(GroundVec3::ZERO, GroundVec3::ZERO, 1.0),
            Err(GroundGeometryError::ZeroLengthDirection)
        );

        let mut provider = GroundProvider::new();
        provider
            .add_plane(GroundVec3::ZERO, GroundVec3::NEG_Y, SurfaceId(9))
            .expect("downward-authored plane remains queryable");
        let contact = contact_for(&provider, GroundVec3::new(0.0, 1.0, 0.0), 2.0);

        assert!(contact.point.is_finite());
        assert!(contact.normal.is_finite());
        assert!(contact.normal_is_valid(TEST_TOLERANCE));
        assert!(contact.normal.dot(GroundVec3::NEG_Y) <= 0.0);
        assert_vec_close(contact.normal, GroundVec3::Y);
    }

    #[test]
    fn repeat_queries_are_bitwise_deterministic_and_ties_keep_first_surface() {
        let mut provider = GroundProvider::new();
        provider
            .add_plane(GroundVec3::ZERO, GroundVec3::Y, SurfaceId(11))
            .expect("first overlapping plane");
        provider
            .add_plane(GroundVec3::ZERO, GroundVec3::Y, SurfaceId(22))
            .expect("second overlapping plane");
        let probe = GroundProbe::downward(GroundVec3::new(0.125, 3.5, -0.75), 5.0)
            .expect("repeatability probe");
        let expected = provider.query(probe);
        let expected_contact = expected.contact().expect("overlap contact");

        assert_eq!(expected_contact.surface_id, SurfaceId(11));
        assert_eq!(expected_contact.primitive_id, PrimitiveId(0));

        for _ in 0..4096 {
            let actual = provider.query(probe);
            let actual_contact = actual.contact().expect("repeat contact");
            assert_eq!(actual, expected);
            assert_eq!(
                actual_contact.point.x.to_bits(),
                expected_contact.point.x.to_bits()
            );
            assert_eq!(
                actual_contact.point.y.to_bits(),
                expected_contact.point.y.to_bits()
            );
            assert_eq!(
                actual_contact.point.z.to_bits(),
                expected_contact.point.z.to_bits()
            );
            assert_eq!(
                actual_contact.normal.x.to_bits(),
                expected_contact.normal.x.to_bits()
            );
            assert_eq!(
                actual_contact.normal.y.to_bits(),
                expected_contact.normal.y.to_bits()
            );
            assert_eq!(
                actual_contact.normal.z.to_bits(),
                expected_contact.normal.z.to_bits()
            );
            assert_eq!(
                actual_contact.distance.to_bits(),
                expected_contact.distance.to_bits()
            );
        }
    }

    #[test]
    fn zero_length_probe_can_report_contact_at_its_origin() {
        let mut provider = GroundProvider::new();
        provider
            .add_plane(GroundVec3::ZERO, GroundVec3::Y, SurfaceId(3))
            .expect("origin plane");
        let result = provider
            .query_down(GroundVec3::ZERO, 0.0)
            .expect("zero-length probe");
        let contact = result.contact().expect("origin contact");

        assert_eq!(contact.distance.to_bits(), 0.0_f32.to_bits());
        assert_vec_close(contact.point, GroundVec3::ZERO);
    }

    #[test]
    fn indexed_import_preserves_classification_material_mesh_and_edge_codes() {
        let mut provider = GroundProvider::new();
        provider
            .add_indexed_triangle_mesh(
                vec![
                    ImportedCollisionTriangle::new(
                        GroundVec3::new(-2.0, 1.0, -2.0),
                        GroundVec3::new(2.0, 1.0, -2.0),
                        GroundVec3::new(0.0, 1.0, 2.0),
                        SurfaceId(0x1A83),
                        712,
                        91,
                        Some([2, 7, 11]),
                    )
                    .expect("valid imported triangle"),
                ],
                16.0,
            )
            .expect("valid indexed mesh");

        let contact = contact_for(&provider, GroundVec3::new(0.0, 3.0, 0.0), 4.0);
        assert_eq!(contact.surface_id, SurfaceId(0x1A83));
        assert_eq!(contact.material_id, Some(712));
        assert_eq!(contact.source_surface_id, Some(91));
        assert_eq!(contact.native_edge_codes, Some([2, 7, 11]));
        assert_vec_close(contact.point, GroundVec3::new(0.0, 1.0, 0.0));
        assert_vec_close(contact.normal, GroundVec3::Y);
    }

    #[test]
    fn slanted_indexed_probe_visits_only_crossed_cells_in_package_order() {
        let triangle = |a: GroundVec3, b: GroundVec3, c: GroundVec3, id: u32| {
            ImportedCollisionTriangle::new(a, b, c, SurfaceId(id), id, id, None).unwrap()
        };
        let mesh = IndexedTriangleMesh::new(
            vec![
                triangle(
                    GroundVec3::new(0.1, 0.0, 0.1),
                    GroundVec3::new(0.3, 0.0, 0.1),
                    GroundVec3::new(0.1, 0.0, 0.4),
                    10,
                ),
                triangle(
                    GroundVec3::new(100.1, 0.0, 0.1),
                    GroundVec3::new(100.3, 0.0, 0.1),
                    GroundVec3::new(100.1, 0.0, 0.4),
                    20,
                ),
                triangle(
                    GroundVec3::new(2.1, 0.0, 0.1),
                    GroundVec3::new(2.3, 0.0, 0.1),
                    GroundVec3::new(2.1, 0.0, 0.4),
                    30,
                ),
                // This triangle spans all three traversed cells and must be
                // returned once rather than once per cell.
                triangle(
                    GroundVec3::new(0.2, 0.0, 0.2),
                    GroundVec3::new(2.2, 0.0, 0.2),
                    GroundVec3::new(0.2, 0.0, 0.4),
                    40,
                ),
            ],
            1.0,
        )
        .unwrap();
        let forward = GroundProbe::new(
            GroundVec3::new(0.25, 1.0, 0.3),
            GroundVec3::new(1.0, 0.0, 0.0),
            2.5,
        )
        .unwrap();
        let reverse = GroundProbe::new(
            GroundVec3::new(2.75, 1.0, 0.3),
            GroundVec3::new(-1.0, 0.0, 0.0),
            2.5,
        )
        .unwrap();

        assert_eq!(
            mesh.candidate_indices(forward).collect::<Vec<_>>(),
            vec![0, 2, 3]
        );
        assert_eq!(
            mesh.candidate_indices(reverse).collect::<Vec<_>>(),
            vec![0, 2, 3]
        );
    }

    #[test]
    fn slanted_indexed_query_still_hits_crossed_surface() {
        let wall = ImportedCollisionTriangle::new(
            GroundVec3::new(2.0, 0.0, 0.0),
            GroundVec3::new(2.0, 1.0, 0.0),
            GroundVec3::new(2.0, 0.0, 1.0),
            SurfaceId(73),
            9,
            12,
            None,
        )
        .unwrap();
        let mut provider = GroundProvider::new();
        provider.add_indexed_triangle_mesh(vec![wall], 1.0).unwrap();
        let probe = GroundProbe::new(
            GroundVec3::new(0.25, 0.25, 0.25),
            GroundVec3::new(1.0, 0.0, 0.0),
            3.0,
        )
        .unwrap();
        let contact = provider.query(probe).contact().expect("wall contact");

        assert_eq!(contact.surface_id, SurfaceId(73));
        assert_close(contact.distance, 1.75);
        assert_vec_close(contact.point, GroundVec3::new(2.0, 0.25, 0.25));
    }

    #[test]
    fn indexed_mesh_rejects_invalid_cell_sizes() {
        let mut provider = GroundProvider::new();
        assert_eq!(
            provider.add_indexed_triangle_mesh(Vec::new(), 0.0),
            Err(GroundGeometryError::InvalidBroadphaseCellSize)
        );
        assert_eq!(
            provider.add_indexed_triangle_mesh(Vec::new(), f32::NAN),
            Err(GroundGeometryError::InvalidBroadphaseCellSize)
        );
    }
}
