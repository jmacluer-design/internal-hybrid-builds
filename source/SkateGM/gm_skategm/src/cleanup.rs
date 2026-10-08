//! Making the map's collision a clean surface for the Skate engine.
//!
//! A map is built from many brushes that touch, and every brush contributes
//! all of its faces. Faces pressed against other brushes are invisible in the
//! game, but to the engine they change what an edge "is": a ramp sitting on a
//! floor has a bottom face, so the ramp's front edge looks like a sharp wedge
//! corner instead of a slope meeting the floor, and wheels can catch on it.
//! The map compiler removes such faces for rendering; we do the same for
//! collision, then repair T-junctions so neighbouring surfaces share edges the
//! engine can recognise as seams (it pairs edges by shared, welded vertices).

use glam::Vec3;
use std::collections::{HashMap, HashSet};

/// The map's solidity, kept after loading so props and brush entities can be
/// cleaned against the world too. Source's rule for "is this point solid":
/// the BSP leaf is solid, or the point is inside one of the leaf's brushes.
pub struct WorldSolid {
    head: i32,
    nodes: Vec<(u32, [i32; 2])>,
    planes: Vec<[f32; 4]>,
    leaves: Vec<(i32, u32, u32)>,
    leaf_brushes: Vec<u16>,
    brushes: Vec<(u32, u32, u32)>, // contents, first side, side count
    sides: Vec<u32>,               // plane index per brush side
    mask: u32,
    /// for diagnostics: which model owns each brush (0 world, n = brush entity
    /// "*n", -1 none), and each brush entity's class
    pub owner: Vec<i32>,
    pub classes: HashMap<i32, String>,
    /// each leaf's area, in file order
    pub leaf_areas: Vec<u16>,
}

impl WorldSolid {
    pub fn new(bsp: &vbsp::Bsp, leaves: &[crate::world::LeafBrushes], mask: u32) -> Self {
        Self {
            head: bsp.models.first().map_or(0, |m| m.head_node),
            nodes: bsp.nodes.iter().map(|n| (n.plane_index as u32, n.children)).collect(),
            planes: bsp.planes.iter().map(|p| [p.normal.x, p.normal.y, p.normal.z, p.dist]).collect(),
            leaves: leaves.iter().map(|l| (l.contents, l.first as u32, l.count as u32)).collect(),
            leaf_brushes: bsp.leaf_brushes.iter().map(|lb| lb.brush).collect(),
            brushes: bsp.brushes.iter().map(|b| (b.flags.bits(), b.brush_side as u32, b.num_brush_sides as u32)).collect(),
            sides: bsp.brush_sides.iter().map(|s| s.plane as u32).collect(),
            mask,
            owner: vec![-1; bsp.brushes.len()],
            classes: HashMap::new(),
            leaf_areas: leaves.iter().map(|l| l.area).collect(),
        }
    }

    pub fn brush_planes(&self, b: usize) -> Vec<[f32; 4]> {
        let Some(&(_, side, n)) = self.brushes.get(b) else { return Vec::new() };
        self.sides.iter().skip(side as usize).take(n as usize).filter_map(|&pi| self.planes.get(pi as usize).copied()).collect()
    }

    /// Every brush (any owner, any contents) whose volume holds this point.
    pub fn brushes_containing(&self, p: Vec3, tol: f32) -> Vec<usize> {
        (0..self.brushes.len())
            .filter(|&b| {
                let pl = self.brush_planes(b);
                !pl.is_empty() && pl.iter().all(|q| q[0] * p.x + q[1] * p.y + q[2] * p.z <= q[3] + tol)
            })
            .collect()
    }

    /// What happened to the collision at a surface the game says is solid
    /// (point on it, and its normal): one line per brush there.
    pub fn diagnose(&self, p: Vec3, n: Vec3, collision_has_surface: bool) -> Vec<String> {
        let inside = p - n * 0.3;
        let mut out = Vec::new();
        for b in self.brushes_containing(inside, 0.05) {
            let contents = self.brushes[b].0;
            let owner = self.owner.get(b).copied().unwrap_or(-1);
            let who = match owner {
                0 => "the world".to_string(),
                -1 => "no model (unused brush)".to_string(),
                m => format!("brush entity *{m} ({})", self.classes.get(&m).map(String::as_str).unwrap_or("unknown class")),
            };
            let planes = self.brush_planes(b);
            let faces = crate::world::brush_faces(&planes);
            let on = faces.iter().find(|f| {
                if f.len() < 3 { return false; }
                let fn_ = (f[1] - f[0]).cross(f[2] - f[0]).normalize_or_zero();
                fn_.dot(n) > 0.99 && (fn_.dot(p) - fn_.dot(f[0])).abs() < 0.5
            });
            let face = match on {
                None => "NO face was made on this surface (the brush's shape didn't come out right)".to_string(),
                Some(f) => {
                    let t = [f[0], f[1], f[2]];
                    if owner == 0 && buried(&t, |q| self.solid(q)) {
                        "its face here was REMOVED as hidden (the space in front counted as solid)".to_string()
                    } else if owner == 0 {
                        "its face here was kept".to_string()
                    } else if owner == -1 {
                        "the map compiler left this brush out of the level (it isn't solid in the game either)".to_string()
                    } else {
                        "it's part of a brush entity".to_string()
                    }
                }
            };
            let solid_for_us = contents & self.mask != 0;
            out.push(format!(
                "brush {b}, owned by {who}, contents 0x{contents:x}{}: {face}; skater collision has a surface here: {}",
                if solid_for_us { "" } else { " (NOT a contents type the skater's collision takes)" },
                if collision_has_surface { "yes" } else { "no" }
            ));
        }
        if out.is_empty() {
            out.push(format!(
                "no brush at this spot: it's displacement terrain or a model; skater collision has a surface here: {}",
                if collision_has_surface { "yes" } else { "no" }
            ));
        }
        out
    }

    /// The area of the map the point is in (None if outside it).
    pub fn area_at(&self, p: Vec3) -> Option<u16> {
        let mut n = self.head;
        let mut guard = 0;
        while n >= 0 {
            let &(plane, children) = self.nodes.get(n as usize)?;
            let pl = self.planes.get(plane as usize)?;
            n = if pl[0] * p.x + pl[1] * p.y + pl[2] * p.z < pl[3] { children[1] } else { children[0] };
            guard += 1;
            if guard > 100_000 {
                return None;
            }
        }
        self.leaf_areas.get((-1 - n) as usize).copied()
    }

    pub fn solid(&self, p: Vec3) -> bool {
        let mut n = self.head;
        let mut guard = 0;
        while n >= 0 {
            let Some(&(plane, children)) = self.nodes.get(n as usize) else { return false };
            let Some(pl) = self.planes.get(plane as usize) else { return false };
            n = if pl[0] * p.x + pl[1] * p.y + pl[2] * p.z < pl[3] { children[1] } else { children[0] };
            guard += 1;
            if guard > 100_000 {
                return false;
            }
        }
        let Some(&(contents, first, count)) = self.leaves.get((-1 - n) as usize) else { return false };
        if contents & 1 != 0 {
            return true;
        }
        self.leaf_brushes.iter().skip(first as usize).take(count as usize).any(|&b| {
            let Some(&(flags, side, sides)) = self.brushes.get(b as usize) else { return false };
            flags & self.mask != 0
                && self.sides.iter().skip(side as usize).take(sides as usize).all(|&pi| {
                    self.planes.get(pi as usize).is_some_and(|pl| pl[0] * p.x + pl[1] * p.y + pl[2] * p.z <= pl[3] + 0.01)
                })
        })
    }
}

#[cfg(test)]
impl WorldSolid {
    /// A world made of axis-aligned solid boxes (no BSP tree: one leaf lists them all).
    pub fn from_boxes(boxes: &[(Vec3, Vec3)]) -> Self {
        let mut planes = Vec::new();
        let mut brushes = Vec::new();
        let mut sides = Vec::new();
        for (lo, hi) in boxes {
            let first = sides.len() as u32;
            for p in [[1., 0., 0., hi.x], [-1., 0., 0., -lo.x], [0., 1., 0., hi.y], [0., -1., 0., -lo.y], [0., 0., 1., hi.z], [0., 0., -1., -lo.z]] {
                sides.push(planes.len() as u32);
                planes.push(p);
            }
            brushes.push((1u32, first, 6u32));
        }
        let n = brushes.len();
        Self { head: -1, nodes: vec![], planes, leaves: vec![(0, 0, n as u32)], leaf_brushes: (0..n as u16).collect(), brushes, sides, mask: 1, owner: vec![0; n], classes: HashMap::new(), leaf_areas: vec![0] }
    }
}

/// Test points in front of a triangle (centre and near each corner, 0.5 in out).
fn front_samples(t: &[Vec3; 3]) -> Option<[Vec3; 4]> {
    let n = (t[1] - t[0]).cross(t[2] - t[0]);
    let len = n.length();
    if len < 1e-6 {
        return None;
    }
    let n = n / len * 0.5;
    let c = (t[0] + t[1] + t[2]) / 3.0;
    Some([c + n, c + (t[0] - c) * 0.8 + n, c + (t[1] - c) * 0.8 + n, c + (t[2] - c) * 0.8 + n])
}

/// Is a triangle buried: solid all across the space just in front of it?
pub fn buried(t: &[Vec3; 3], solid: impl Fn(Vec3) -> bool) -> bool {
    buried_with(t, solid, on("densebury"))
}

/// As `buried`; with `dense`, tested on a grid over the whole face (every 24
/// units or so), not just four samples near the middle: a big floor with a box
/// standing on most of it still shows a strip beside the box, which the four
/// miss. (Measured in 5.28: neutral on tl_skatepark, a little worse on
/// pf_skatepark - so opt-in, SK8_ON=densebury.)
pub fn buried_with(t: &[Vec3; 3], solid: impl Fn(Vec3) -> bool, dense: bool) -> bool {
    let Some(s) = front_samples(t) else { return true }; // degenerate: drop
    if !s.iter().all(|&p| solid(p)) {
        return false;
    }
    if !dense {
        return true;
    }
    let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize() * 0.5;
    let c = (t[0] + t[1] + t[2]) / 3.0;
    let longest = (t[1] - t[0]).length().max((t[2] - t[1]).length()).max((t[0] - t[2]).length());
    let steps = ((longest / 24.0).ceil() as usize).clamp(1, 8);
    for i in 0..=steps {
        for j in 0..=(steps - i) {
            let p = t[0] + (t[1] - t[0]) * (i as f32 / steps as f32) + (t[2] - t[0]) * (j as f32 / steps as f32);
            // (a hair inside the face, clear of its neighbours' edges)
            if !solid(c + (p - c) * 0.95 + n) {
                return false;
            }
        }
    }
    true
}

/// Planes of a convex piece (from its outward triangles), for inside tests.
pub fn convex_planes(tris: &[[Vec3; 3]]) -> Vec<[f32; 4]> {
    let mut out: Vec<[f32; 4]> = Vec::new();
    for t in tris {
        let n = (t[1] - t[0]).cross(t[2] - t[0]);
        if n.length_squared() < 1e-8 {
            continue;
        }
        let n = n.normalize();
        let d = n.dot(t[0]);
        if !out.iter().any(|q| Vec3::new(q[0], q[1], q[2]).dot(n) > 0.9999 && (q[3] - d).abs() < 0.01) {
            out.push([n.x, n.y, n.z, d]);
        }
    }
    out
}

pub fn inside_convex(planes: &[[f32; 4]], p: Vec3) -> bool {
    !planes.is_empty() && planes.iter().all(|q| q[0] * p.x + q[1] * p.y + q[2] * p.z <= q[3] + 0.01)
}

/// Pieces of one object (convex hulls of a model, brushes of a brush entity):
/// drop each piece's faces that lie inside another piece. Returns the rest.
pub fn remove_buried_between(pieces: Vec<Vec<[Vec3; 3]>>) -> (Vec<[Vec3; 3]>, usize) {
    let planes: Vec<Vec<[f32; 4]>> = pieces.iter().map(|p| convex_planes(p)).collect();
    let mut out = Vec::new();
    let mut removed = 0;
    for (i, piece) in pieces.iter().enumerate() {
        for t in piece {
            let hidden = buried(t, |p| planes.iter().enumerate().any(|(j, pl)| j != i && inside_convex(pl, p)));
            if hidden {
                removed += 1;
            } else {
                out.push(*t);
            }
        }
    }
    (out, removed)
}

/// Drop triangles buried in the world (solid all across the space in front of them).
pub fn remove_buried(tris: Vec<[Vec3; 3]>, world: &WorldSolid) -> (Vec<[Vec3; 3]>, usize) {
    let before = tris.len();
    let kept: Vec<_> = tris.into_iter().filter(|t| !buried(t, |p| world.solid(p))).collect();
    let removed = before - kept.len();
    (kept, removed)
}

/// Split triangle edges at vertices of other triangles that lie on them, so
/// adjacent surfaces meet vertex-to-vertex. Returns the new list and how many
/// triangles were split.
pub fn fix_t_junctions(tris: Vec<[Vec3; 3]>, tags: Vec<u8>, eps: f32) -> (Vec<[Vec3; 3]>, Vec<u8>, usize) {
    const CELL: f32 = 64.0;
    let cell = |v: Vec3| [(v.x / CELL).floor() as i32, (v.y / CELL).floor() as i32, (v.z / CELL).floor() as i32];
    // unique vertices, bucketed
    let mut grid: HashMap<[i32; 3], Vec<Vec3>> = HashMap::new();
    let key = |v: Vec3| [(v.x * 64.0).round() as i64, (v.y * 64.0).round() as i64, (v.z * 64.0).round() as i64];
    let mut seen = std::collections::HashSet::new();
    for t in &tris {
        for &v in t {
            if seen.insert(key(v)) {
                grid.entry(cell(v)).or_default().push(v);
            }
        }
    }
    // each triangle on its own (in parallel), joined back in order
    let items: Vec<([Vec3; 3], u8)> = tris.into_iter().zip(tags).collect();
    let parts = par_map(&items, |chunk| {
    let mut out = Vec::with_capacity(chunk.len());
    let mut out_tags = Vec::with_capacity(chunk.len());
    let mut split = 0;
    for &(t, tag) in chunk {
        // the triangle's outline, with points inserted along each edge
        let mut ring: Vec<Vec3> = Vec::with_capacity(6);
        let mut inserted = false;
        for i in 0..3 {
            let (a, b) = (t[i], t[(i + 1) % 3]);
            ring.push(a);
            let ab = b - a;
            let len2 = ab.length_squared();
            if len2 < 1e-6 {
                continue;
            }
            let (lo, hi) = (a.min(b) - Vec3::splat(eps), a.max(b) + Vec3::splat(eps));
            let (cl, ch) = (cell(lo), cell(hi));
            let mut on_edge: Vec<(f32, Vec3)> = Vec::new();
            for x in cl[0]..=ch[0] {
                for y in cl[1]..=ch[1] {
                    for z in cl[2]..=ch[2] {
                        let Some(bucket) = grid.get(&[x, y, z]) else { continue };
                        for &v in bucket {
                            let s = (v - a).dot(ab) / len2;
                            if s <= 1e-4 || s >= 1.0 - 1e-4 {
                                continue;
                            }
                            if (a + ab * s - v).length_squared() <= eps * eps
                                && (v - a).length_squared() > eps * eps
                                && (v - b).length_squared() > eps * eps
                            {
                                on_edge.push((s, v));
                            }
                        }
                    }
                }
            }
            if !on_edge.is_empty() {
                on_edge.sort_by(|p, q| p.0.total_cmp(&q.0));
                on_edge.dedup_by(|p, q| (p.1 - q.1).length_squared() < eps * eps);
                ring.extend(on_edge.into_iter().map(|(_, v)| v));
                inserted = true;
            }
        }
        if !inserted {
            out.push(t);
            out_tags.push(tag);
            continue;
        }
        split += 1;
        // fan from the centroid keeps every piece valid, whichever edges split
        let c = (t[0] + t[1] + t[2]) / 3.0;
        for i in 0..ring.len() {
            let (p, q) = (ring[i], ring[(i + 1) % ring.len()]);
            if (q - p).cross(c - p).length_squared() > 1e-8 {
                out.push([p, q, c]);
                out_tags.push(tag);
            }
        }
    }
    (out, out_tags, split)
    });
    let mut out = Vec::with_capacity(items.len());
    let mut out_tags = Vec::with_capacity(items.len());
    let mut split = 0;
    for (o, g, n) in parts {
        out.extend(o);
        out_tags.extend(g);
        split += n;
    }
    (out, out_tags, split)
}

/// Vertical ray queries over a triangle soup (XY grid).
pub struct Heights<'a> {
    tris: &'a [[Vec3; 3]],
    cells: CellMap<Vec<u32>>,
}

impl<'a> Heights<'a> {
    const CELL: f32 = 32.0;
    pub fn new(tris: &'a [[Vec3; 3]]) -> Self {
        let mut cells: CellMap<Vec<u32>> = CellMap::default();
        for (i, t) in tris.iter().enumerate() {
            // (vertical faces can't be "below" anything: lookups skip them anyway)
            if (t[1] - t[0]).cross(t[2] - t[0]).z.abs() < 1e-6 {
                continue;
            }
            let lo = t[0].min(t[1]).min(t[2]);
            let hi = t[0].max(t[1]).max(t[2]);
            for x in (lo.x / Self::CELL).floor() as i32..=(hi.x / Self::CELL).floor() as i32 {
                for y in (lo.y / Self::CELL).floor() as i32..=(hi.y / Self::CELL).floor() as i32 {
                    cells.entry((x, y)).or_default().push(i as u32);
                }
            }
        }
        Self { tris, cells }
    }

    /// The highest surface at (x, y) at or below `top`: (height, normal z).
    pub fn below(&self, x: f32, y: f32, top: f32) -> Option<(f32, f32)> {
        let key = ((x / Self::CELL).floor() as i32, (y / Self::CELL).floor() as i32);
        let mut best: Option<(f32, f32)> = None;
        for &i in self.cells.get(&key)? {
            let t = &self.tris[i as usize];
            let n = (t[1] - t[0]).cross(t[2] - t[0]);
            if n.z.abs() < 1e-6 {
                continue;
            }
            // inside the triangle seen from above?
            let (a, b, c) = (t[0], t[1], t[2]);
            let d = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y);
            if d.abs() < 1e-9 {
                continue;
            }
            let l1 = ((b.y - c.y) * (x - c.x) + (c.x - b.x) * (y - c.y)) / d;
            let l2 = ((c.y - a.y) * (x - c.x) + (a.x - c.x) * (y - c.y)) / d;
            let l3 = 1.0 - l1 - l2;
            if l1 < -1e-4 || l2 < -1e-4 || l3 < -1e-4 {
                continue;
            }
            let z = l1 * a.z + l2 * b.z + l3 * c.z;
            if z <= top && best.map_or(true, |(bz, _)| z > bz) {
                best = Some((z, n.normalize().z));
            }
        }
        best
    }
}

/// Small steps (curbs, mismatched brushes, tiny lips) stop a Skate wheel dead;
/// GMod players just step up them. Where a walkable surface's edge has
/// walkable ground between `min_step` and `max_step` below it, with open space
/// in between, add a shallow ramp over the step. Its top edge shares the
/// upper surface's edge, so the engine sees a gentle, smooth seam there.
pub fn step_ramps(tris: &[[Vec3; 3]], min_step: f32, max_step: f32) -> Vec<[Vec3; 3]> {
    step_ramps_with(tris, &Heights::new(tris), min_step, max_step)
}

/// How far out from `p` (along `out`) the ground that dropped away just past
/// an edge climbs back to the edge's height, if it does so within `reach` as
/// one rideable surface: a trench (terrain starting a few units below a
/// floor's edge and rising back above it, or a channel between two floors),
/// not a drop.
pub fn trench_width(heights: &Heights, p: Vec3, out: Vec3, reach: f32) -> Option<f32> {
    let mut last: Option<(f32, f32)> = None;
    let mut d = 1.0;
    while d <= reach {
        // (looking a little above the edge: where the ground has climbed past
        // its height, a probe capped there would find whatever lies below)
        let (z, nz) = heights.below(p.x + out.x * d, p.y + out.y * d, p.z + 3.0)?;
        if nz < 0.7 {
            return None;
        }
        if let Some((ld, lz)) = last {
            if z >= p.z - 0.05 {
                return Some(ld + (d - ld) * ((p.z - lz) / (z - lz).max(1e-3)).clamp(0.0, 1.0));
            }
            if z < lz - 1.0 {
                return None;
            }
        } else if z >= p.z - 0.2 {
            return None;
        }
        last = Some((d, z));
        d += 2.0;
    }
    None
}

/// As `step_ramps`, with a height index over the same triangles already built.
pub fn step_ramps_with(tris: &[[Vec3; 3]], heights: &Heights, min_step: f32, max_step: f32) -> Vec<[Vec3; 3]> {
    step_ramps_spans(tris, heights, min_step, max_step).0
}

/// Undersides too tight for a wheel to get under: a face looking down (or
/// down and out, like a coping's) with another surface less than `gap` away
/// out along its normal (a prop that floats a unit above the floor; a deck's
/// edge jutting over the top of a quarter pipe). The board can
/// never be in that gap, but riding past its edge the wheels dip just under
/// the face's plane and the engine treats it as a ceiling: on tl_skatepark's
/// prop kicker (foot 1.41 above the ground) the front wheels were slammed down
/// at the foot and the rider thrown, 9 rides in 9 at 11.5 m/s; without the
/// prop's underside, 0 (harness/kicklab.lua). true = take it out.
/// What a judged underside's rays can meet (low_undersides)
enum Near {
    List(Vec<u32>),
    Grid(HashMap<(i32, i32, i32), Vec<u32>>),
}

static GRID_NS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static GRID_TRIS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
pub fn low_undersides(tris: &[[Vec3; 3]], ground: &Heights, gap: f32) -> Vec<Option<Vec<[Vec3; 3]>>> {
    let _ = ground;
    // a grid of the triangles, to look a few units out from a face
    const CELL: f32 = 16.0;
    let cell = |v: Vec3| ((v.x / CELL).floor() as i32, (v.y / CELL).floor() as i32, (v.z / CELL).floor() as i32);
    let t_start = std::time::Instant::now();
    // Which triangles a ray can meet: a coarse index (128-unit cells) of the
    // triangles near a face that gets judged (one facing down); each judged
    // face then makes its own fine grid (16-unit cells) of just its
    // neighbourhood. One fine grid of everything was millions of cells on a
    // big map (pf: 4.7 s of its load) and took a whole terrain mesh in.
    const COARSE: f32 = 128.0;
    let coarse = |v: Vec3| ((v.x / COARSE).floor() as i32, (v.y / COARSE).floor() as i32, (v.z / COARSE).floor() as i32);
    let pad = Vec3::splat(gap + 0.1);
    let is_judged = |t: &[Vec3; 3]| {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        n.z <= -0.3 && n != Vec3::ZERO
    };
    let mut marked: HashSet<(i32, i32, i32)> = HashSet::new();
    for t in tris.iter().filter(|t| is_judged(t)) {
        let (c0, c1) = (coarse(t[0].min(t[1]).min(t[2]) - pad), coarse(t[0].max(t[1]).max(t[2]) + pad));
        for x in c0.0..=c1.0 { for y in c0.1..=c1.1 { for z in c0.2..=c1.2 { marked.insert((x, y, z)); } } }
    }
    if marked.is_empty() {
        return vec![None; tris.len()];
    }
    // (`SK8_OFF=flushbottoms`: triangles over 4096 fine cells left out, as
    // before, and touching surfaces not counted)
    let flush = !off("flushbottoms");
    let fine_cells = |lo: Vec3, hi: Vec3| {
        let (c0, c1) = (cell(lo), cell(hi));
        (c1.0 - c0.0 + 1) as i64 * (c1.1 - c0.1 + 1) as i64 * (c1.2 - c0.2 + 1) as i64
    };
    let mut index: HashMap<(i32, i32, i32), Vec<u32>> = HashMap::new();
    for (i, t) in tris.iter().enumerate() {
        let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
        if !flush && fine_cells(lo, hi) > 4096 { continue; }
        let (c0, c1) = (coarse(lo), coarse(hi));
        let cells = (c1.0 - c0.0 + 1) as i64 * (c1.1 - c0.1 + 1) as i64 * (c1.2 - c0.2 + 1) as i64;
        if cells > marked.len() as i64 {
            for &c in &marked {
                if c.0 >= c0.0 && c.0 <= c1.0 && c.1 >= c0.1 && c.1 <= c1.1 && c.2 >= c0.2 && c.2 <= c1.2 { index.entry(c).or_default().push(i as u32); }
            }
        } else {
            for x in c0.0..=c1.0 { for y in c0.1..=c1.1 { for z in c0.2..=c1.2 {
                if marked.contains(&(x, y, z)) { index.entry((x, y, z)).or_default().push(i as u32); }
            } } }
        }
    }
    // a judged face's neighbourhood: the triangles within reach of it, as a
    // list; a fine grid of them only when there are many (a big face over a
    // dense floor) - most faces have a few dozen, and a grid each was 51M
    // entries on pf
    let local = |t: &[Vec3; 3]| -> Near {
        let (lo, hi) = (t[0].min(t[1]).min(t[2]) - pad, t[0].max(t[1]).max(t[2]) + pad);
        let (k0, k1) = (coarse(lo), coarse(hi));
        let mut near: Vec<u32> = Vec::new();
        for x in k0.0..=k1.0 { for y in k0.1..=k1.1 { for z in k0.2..=k1.2 {
            if let Some(v) = index.get(&(x, y, z)) { near.extend_from_slice(v); }
        } } }
        near.sort_unstable();
        near.dedup();
        near.retain(|&j| {
            let u = &tris[j as usize];
            let (a, b) = (u[0].min(u[1]).min(u[2]).max(lo), u[0].max(u[1]).max(u[2]).min(hi));
            a.x <= b.x && a.y <= b.y && a.z <= b.z
        });
        if near.len() <= 256 {
            return Near::List(near);
        }
        let mut grid: HashMap<(i32, i32, i32), Vec<u32>> = HashMap::new();
        let reach = CELL * 0.87 + 0.1;
        for j in near {
            let u = &tris[j as usize];
            let (a, b) = (u[0].min(u[1]).min(u[2]).max(lo), u[0].max(u[1]).max(u[2]).min(hi));
            let (c0, c1) = (cell(a), cell(b));
            let cells = (c1.0 - c0.0 + 1) as i64 * (c1.1 - c0.1 + 1) as i64 * (c1.2 - c0.2 + 1) as i64;
            let n = (u[1] - u[0]).cross(u[2] - u[0]).normalize_or_zero();
            for x in c0.0..=c1.0 { for y in c0.1..=c1.1 { for z in c0.2..=c1.2 {
                if cells > 64 {
                    let mid = Vec3::new(x as f32 + 0.5, y as f32 + 0.5, z as f32 + 0.5) * CELL;
                    if (mid - u[0]).dot(n).abs() > reach { continue; }
                }
                grid.entry((x, y, z)).or_default().push(j);
            } } }
        }
        Near::Grid(grid)
    };
    // the nearest surface out from p along dir (within `gap`)?
    // (`touching`: a surface right on the face, facing back at it, counts too:
    // a prop's bottom lying flush on the floor)
    let ray = |near: &Near, p: Vec3, dir: Vec3, me: usize, touching: bool| -> bool {
        let end = p + dir * gap;
        let (c0, c1) = (cell(p.min(end) - Vec3::splat(0.05)), cell(p.max(end) + Vec3::splat(0.05)));
        let cells = (c0.0..=c1.0).flat_map(|x| (c0.1..=c1.1).flat_map(move |y| (c0.2..=c1.2).map(move |z| (x, y, z))));
        let candidates: Box<dyn Iterator<Item = &u32>> = match near {
            Near::List(v) => Box::new(v.iter()),
            Near::Grid(g) => Box::new(cells.flat_map(move |c| g.get(&c).map(|v| v.as_slice()).unwrap_or(&[]).iter())),
        };
        for j in candidates {
            let j = *j as usize;
            if j == me { continue; }
            let t = &tris[j];
            // (ray / triangle, Moller-Trumbore)
            let (e1, e2) = (t[1] - t[0], t[2] - t[0]);
            let h = dir.cross(e2);
            let a = e1.dot(h);
            if a.abs() < 1e-8 { continue; }
            let f = 1.0 / a;
            let sv = p - t[0];
            let u = f * sv.dot(h);
            if !(0.0..=1.0).contains(&u) { continue; }
            let q = sv.cross(e1);
            let v = f * dir.dot(q);
            if v < 0.0 || u + v > 1.0 { continue; }
            let d = f * e2.dot(q);
            if d > 0.02 && d < gap { return true; }
            if touching && d > -0.02 && d <= 0.02 && e1.cross(e2).normalize_or_zero().dot(dir) < -0.9 { return true; }
        }
        false
    };
    // tight: something within `gap` of p below the face - out along its normal,
    // straight down, or slanting down to any side (a sliver jutting out from a
    // wall just over a quarter pipe's top: open air along its normal, the
    // wall half a unit away on the slant)
    let r2 = std::f32::consts::FRAC_1_SQRT_2;
    let slants = [Vec3::new(0.0, 0.0, -1.0), Vec3::new(r2, 0.0, -r2), Vec3::new(-r2, 0.0, -r2), Vec3::new(0.0, r2, -r2), Vec3::new(0.0, -r2, -r2)];
    let hit_within = |grid: &Near, p: Vec3, n: Vec3, me: usize| -> bool {
        ray(grid, p, n, me, flush) || slants.iter().any(|d| ray(grid, p, *d, me, false))
    };
    // tight / open / mixed, from samples spread over the face (no further
    // apart than 24: a tight patch inside a big face isn't missed)
    // (the share of samples that are tight, spread over the face no further
    // apart than 24, so a tight patch inside a big face isn't missed)
    // (sampling stops once the outcome is settled - kept, halved or gone, or
    // for a thin face kept or gone by majority - and stands for it: 0, 0.5, 1)
    let judge = |grid: &Near, t: &[Vec3; 3], me: usize, n: Vec3, thin: bool| -> f32 {
        let longest = (t[1] - t[0]).length().max((t[2] - t[1]).length()).max((t[0] - t[2]).length());
        let k = ((longest / 24.0).ceil() as usize).clamp(1, 24);
        let c = (t[0] + t[1] + t[2]) / 3.0;
        let total = ((k + 1) * (k + 2) / 2) as f32;
        let (mut tight, mut seen) = (0usize, 0usize);
        for i in 0..=k {
            for j in 0..=(k - i) {
                let (u, v) = (i as f32 / k as f32, j as f32 / k as f32);
                let p = t[0] * (1.0 - u - v) + t[1] * u + t[2] * v;
                let p = p + (c - p) * 0.05;
                seen += 1;
                if hit_within(grid, p, n, me) { tight += 1 }
                let (lo, hi) = (tight as f32 / total, (tight as f32 + total - seen as f32) / total);
                if thin {
                    if lo >= 0.5 { return 1.0; }
                    if hi < 0.5 { return 0.0; }
                } else {
                    if hi < 0.3 { return 0.0; }
                    if lo >= 0.3 && hi < 0.999 { return 0.5; }
                }
            }
        }
        tight as f32 / total
    };
    fn halve(t: &[Vec3; 3]) -> [[Vec3; 3]; 2] {
        let lens = [(t[1] - t[0]).length(), (t[2] - t[1]).length(), (t[0] - t[2]).length()];
        let k = if lens[0] >= lens[1] && lens[0] >= lens[2] { 0 } else if lens[1] >= lens[2] { 1 } else { 2 };
        let (a, b, c) = (t[k], t[(k + 1) % 3], t[(k + 2) % 3]);
        let mid = (a + b) * 0.5;
        [[a, mid, c], [mid, b, c]]
    }
    // (each face judged on its own: spread over the worker threads)
    let one = |me: usize| -> Option<Vec<[Vec3; 3]>> {
        let t = &tris[me];
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        // (undersides: facing down, or down and out like a coping's)
        if n.z > -0.3 {
            return None;
        }
        // all open: kept as it is; all tight: gone; mixed: halved until each
        // piece is one or the other (or small), only along the boundary
        let tg = std::time::Instant::now();
        let grid = local(t);
        GRID_NS.fetch_add(tg.elapsed().as_nanos() as u64, std::sync::atomic::Ordering::Relaxed);
        GRID_TRIS.fetch_add(match &grid { Near::List(v) => v.len() as u64, Near::Grid(g) => g.values().map(|v| v.len() as u64).sum::<u64>() }, std::sync::atomic::Ordering::Relaxed);
        let mut kept = Vec::new();
        let mut todo = vec![(*t, 0u32)];
        let mut removed_any = false;
        while let Some((p, depth)) = todo.pop() {
            let longest = (p[1] - p[0]).length().max((p[2] - p[1]).length()).max((p[0] - p[2]).length());
            let thin = longest > 0.0 && (p[1] - p[0]).cross(p[2] - p[0]).length() / longest < 4.0;
            let share = judge(&grid, &p, me, n, thin);
            // (a thin face - narrower than 4 units across its longest side - is
            // never halved: that only makes slivers, which upset the engine's
            // contacts elsewhere; it goes or stays whole, by majority)
            let area2 = (p[1] - p[0]).cross(p[2] - p[0]).length();
            if longest > 0.0 && area2 / longest < 4.0 {
                if share >= 0.5 { removed_any = true } else { kept.push(p) }
                continue;
            }
            // (all open, or only a thin edge of it tight - a real overhang's
            // strip along the wall it hangs from: kept whole)
            if share < 0.3 { kept.push(p); continue; }
            if share >= 0.999 { removed_any = true; continue; }
            if longest <= 32.0 || depth >= 12 {
                // (small and mixed: gone if most of it is tight)
                let c = (p[0] + p[1] + p[2]) / 3.0;
                let pts = [c, (p[0] + c) * 0.5, (p[1] + c) * 0.5, (p[2] + c) * 0.5];
                let n_tight = pts.iter().filter(|q| hit_within(&grid, **q, n, me)).count();
                if n_tight >= 3 { removed_any = true } else { kept.push(p) }
                continue;
            }
            for h in halve(&p) { todo.push((h, depth + 1)); }
        }
        // (and no degenerate pieces kept)
        kept.retain(|p| (p[1] - p[0]).cross(p[2] - p[0]).length() > 0.05);
        removed_any.then_some(kept)
    };
    let down: Vec<usize> = (0..tris.len()).filter(|&i| {
        let t = &tris[i];
        (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().z <= -0.3
    }).collect();
    let t_grid = t_start.elapsed();
    let judged = par_map(&down, |part| part.iter().map(|&i| (i, one(i))).collect::<Vec<_>>());
    if env_var("SK8_UNDERTIME").is_ok() {
        eprintln!("undersides: {} faces judged, index {} cells, {:?} index, {:?} judging ({} ms building local grids over all threads, {} entries)", down.len(), index.len(), t_grid, t_start.elapsed() - t_grid,
            GRID_NS.swap(0, std::sync::atomic::Ordering::Relaxed) / 1_000_000, GRID_TRIS.swap(0, std::sync::atomic::Ordering::Relaxed));
    }
    let mut out = vec![None; tris.len()];
    for (i, r) in judged.into_iter().flatten() {
        out[i] = r;
    }
    out
}

/// A stretch of an edge a ramp now covers: its two ends (on the edge, at the
/// top) and the direction the ramp runs out to (horizontal).
pub type Covered = (Vec3, Vec3, Vec3);

/// As `step_ramps_with`, also saying which stretches of which edges got a ramp
/// (for `remove_covered_risers`).
pub fn step_ramps_spans(tris: &[[Vec3; 3]], heights: &Heights, min_step: f32, max_step: f32) -> (Vec<[Vec3; 3]>, Vec<Covered>) {
    if max_step <= min_step {
        return (Vec::new(), Vec::new());
    }
    let key = |v: Vec3| v.to_array().map(|x| (x * 8.).round() as i32);
    let edge_key = |a: Vec3, b: Vec3| { let (ka, kb) = (key(a), key(b)); if ka < kb { (ka, kb) } else { (kb, ka) } };
    // the upper side: rideable tops (level or gently sloped); each edge is
    // handled once, by the first top that has it (decided up front, so the
    // work can then be split over the CPU's cores)
    let tops: Vec<usize> = (0..tris.len())
        .filter(|&i| { let t = &tris[i]; (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().z >= 0.85 })
        .collect();
    // (and how many tops share it: an edge between two tops is continuous
    // surface - floor tiles, terrain, a ramp's facets - never a step)
    let mut owner: HashMap<([i32; 3], [i32; 3]), (usize, u8)> = HashMap::with_capacity(tops.len() * 2);
    for &ti in &tops {
        let t = &tris[ti];
        for i in 0..3 {
            owner.entry(edge_key(t[i], t[(i + 1) % 3])).and_modify(|e| e.1 = e.1.saturating_add(1)).or_insert((ti * 3 + i, 1));
        }
    }
    let trenches = !off("trenches");
    let trench_curve = trenches && on("trenchcurve");
    let parts = par_map(&tops, |chunk| {
    let mut ramps = Vec::new();
    let mut spans: Vec<Covered> = Vec::new();
    for &ti in chunk {
        let t = &tris[ti];
        let centroid = (t[0] + t[1] + t[2]) / 3.0;
        for i in 0..3 {
            let (a, b) = (t[i], t[(i + 1) % 3]);
            match owner.get(&edge_key(a, b)) {
                Some(&(o, 1)) if o == ti * 3 + i => {}
                _ => continue, // someone else's edge, or between two tops
            }
            let along = b - a;
            let len = along.length();
            // (sloped edges too, up to 45 degrees: a kicker's side, rising with
            // its face - near the foot it's a tiny edge the wheels stop dead at,
            // since to them any vertical face is a wall; the ramp is only built
            // where the step is small, each sample on its own height)
            let max_rise = if off("slopededges") { 0.15 } else { 0.71 };
            if len < 2.0 || along.z.abs() > max_rise * len {
                continue;
            }
            let mid = (a + b) * 0.5;
            let mut out = Vec3::new(along.y, -along.x, 0.0).normalize_or_zero();
            if out.dot(centroid - mid) > 0.0 {
                out = -out;
            }
            let probe = |p: Vec3, dist: f32, top: f32| heights.below(p.x + out.x * dist, p.y + out.y * dist, top + 0.25);
            // The lower side can be level ground (a curb onto a street) or a
            // slope (a kicker meeting a platform a few units short of its top).
            // It must be one continuous surface out to the ramp's foot: sampled
            // every 4 units, no jump - so a flight of stairs (a riser every step)
            // isn't turned into a slope. Only the stretches of the edge where
            // that holds are bridged (a kicker is often narrower than the
            // platform it leads onto).
            let foot = |p: Vec3| -> Option<(f32, f32)> {
                let top = p.z;
                // the surface below, just past the edge - across a small gap if
                // there is one (a kicker stopping short of a platform)
                let reach: &[f32] = if off("gaps") { &[1.0] } else { &[0.5, 1.0, 2.0, 3.0, 4.5, 6.0] };
                let (d0, z0, nz0) = reach.iter().find_map(|&d| {
                    probe(p, d, top).and_then(|(z, nz)| (top - z <= max_step + 3.0 && nz >= 0.7).then_some((d, z, nz)))
                })?;
                // A step is a jump: the lower surface, followed back to the edge
                // line, doesn't reach the upper one. (Comparing heights just past
                // the edge would make every edge of sloped terrain look like a step.)
                // the lower surface's slope, from a probe 1 unit further out (a
                // narrow band - trim along a plate's edge - may not reach 4);
                // a drop there means no slope to speak of
                let z1 = probe(p, d0 + 1.0, top).map(|(z, _)| z).filter(|z| (z - z0).abs() < 0.5).unwrap_or(z0);
                let at_edge = z0 + (z0 - z1) * d0;
                let step = top - at_edge;
                // A crack: the same height on the far side of a small gap (slab
                // joints, two props side by side, a platform edge beside a level
                // surface). A wheel drops into those; bridge it, level.
                if !off("cracks") && step.abs() < 0.2 && d0 >= 1.0 && nz0 >= 0.85 {
                    return Some((d0 + 0.5, z0));
                }
                if step < min_step.max(0.2) || step > max_step || nz0 < 0.7 {
                    return None;
                }
                // Ground that climbs back to the edge's height within 24 units
                // is a trench (terrain starting a few units below a floor's
                // edge): a wheel drops in and hits the far side. Bridged level,
                // like a crack. (SK8_OFF=trenches to compare without)
                if trenches {
                    if let Some(w) = trench_width(heights, p, out, 24.0) {
                        return Some((w.max(d0 + 0.5), top));
                    }
                }
                // (the same gentle slope for every step; a tiny step needs only a
                // short ramp - a 0.3 unit lip onto a 1.5 unit ramp - so it fits
                // on a narrow band; past a gap it must at least reach the far side)
                // (SK8_RAMP_RUN: run per unit of step, SK8_RAMP_MIN: shortest run;
                // to measure longer, gentler ramps)
                let per: f32 = env_var("SK8_RAMP_RUN").ok().and_then(|v| v.parse().ok()).unwrap_or(6.0);
                let shortest: f32 = env_var("SK8_RAMP_MIN").ok().and_then(|v| v.parse().ok()).unwrap_or(if off("shortsteps") { 6.0 } else { 1.5 });
                let run = (step * per).clamp(shortest, 36.0f32.max(shortest)).max(d0 + 1.0);
                let mut last = z0;
                let mut d = d0;
                loop {
                    d = (d + 4.0).min(run);
                    let (z, nz) = probe(p, d, top)?;
                    if nz < 0.7 || z > top - min_step * 0.5 || (z - last).abs() > 3.0 {
                        return None; // not rideable, rising back up, or a riser / drop
                    }
                    last = z;
                    if d >= run {
                        return Some((run, z));
                    }
                }
            };
            let samples = ((len / 8.0).ceil() as usize).max(1);
            // (the ramp's corners sit exactly on the edge's ends, so the ramps
            // of consecutive edges along one curb meet with no notch between
            // them; the ground is probed just inside, clear of the corner)
            let pts: Vec<(Vec3, Option<(f32, f32)>)> = (0..=samples)
                .map(|k| {
                    let s = k as f32 / samples as f32;
                    (a + along * s, foot(a + along * s.clamp(0.01, 0.99)))
                })
                .collect();
            if let Ok(spot) = env_var("SK8_LEDGE_DEBUG") {
                let v: Vec<f32> = spot.split(',').filter_map(|x| x.parse().ok()).collect();
                if v.len() == 2 && pts.iter().any(|(p, _)| (p.x - v[0]).abs() < 12.0 && (p.y - v[1]).abs() < 12.0) {
                    eprintln!("LEDGE edge {:?} -> {:?} (top z {:.2}, out {:?}): samples {:?}", a.to_array(), b.to_array(), a.z, out.to_array(),
                        pts.iter().map(|(_, f)| f.map(|(r, z)| format!("run {r:.1} to z {z:.2}")).unwrap_or("-".into())).collect::<Vec<_>>());
                }
            }
            let mut add = |p: Vec3, q: Vec3, r: Vec3| {
                if (q - p).cross(r - p).length_squared() > 1e-6 {
                    if (q - p).cross(r - p).z >= 0.0 { ramps.push([p, q, r]) } else { ramps.push([p, r, q]) }
                }
            };
            // (the stretches of this edge with a ramp all along: runs of samples)
            let mut run_start: Option<Vec3> = None;
            for (k, w) in pts.windows(2).enumerate() {
                let both = w[0].1.is_some() && w[1].1.is_some();
                if both && run_start.is_none() { run_start = Some(w[0].0); }
                let last = k + 2 == pts.len();
                if let Some(st) = run_start {
                    if !both { spans.push((st, w[0].0, out)); run_start = None; }
                    else if last { spans.push((st, w[1].0, out)); run_start = None; }
                }
            }
            for w in pts.windows(2) {
                let ((p, fp), (q, fq)) = (w[0], w[1]);
                let (Some((rp, zp)), Some((rq, zq))) = (fp, fq) else { continue };
                let (pf, qf) = (Vec3::new(p.x + out.x * rp, p.y + out.y * rp, zp), Vec3::new(q.x + out.x * rq, q.y + out.y * rq, zq));
                add(p, q, qf);
                add(p, qf, pf);
                // (SK8_ON=trenchcurve) a trench bridge ends where the ground
                // climbs back to its height: round that crease with a short
                // curve tangent to both, as the curves pass would have if it
                // ran after the ramps
                if trench_curve {
                    let curve = |e: Vec3, run: f32| -> Option<Vec<Vec3>> {
                        let w = trench_width(heights, e, out, 24.0)?;
                        if (run - w).abs() > 0.05 {
                            return None; // not a trench bridge (a crack or a slope)
                        }
                        let r = 4.0f32;
                        let at = |d: f32| Vec3::new(e.x + out.x * d, e.y + out.y * d, 0.0);
                        let far = at(w + r);
                        let (zf, nzf) = heights.below(far.x, far.y, e.z + r + 6.0)?;
                        if nzf < 0.7 || zf < e.z || zf > e.z + r * 1.2 {
                            return None;
                        }
                        let (p0, p1, p2) = (Vec3::new(at(w - r).x, at(w - r).y, e.z), Vec3::new(at(w).x, at(w).y, e.z), Vec3::new(far.x, far.y, zf));
                        Some((0..=4).map(|k| { let t = k as f32 / 4.0; p0 * (1.0 - t) * (1.0 - t) + p1 * 2.0 * t * (1.0 - t) + p2 * t * t }).collect())
                    };
                    if let (Some(cp), Some(cq)) = (curve(p, rp), curve(q, rq)) {
                        for k in 0..4 {
                            add(cp[k], cq[k], cq[k + 1]);
                            add(cp[k], cq[k + 1], cp[k + 1]);
                        }
                    }
                }
            }
            // Where a ramp stretch ends, its wedge would have an open side - a
            // lip as tall as the ramp to anyone rolling along the curb into it.
            // A wing closes it: from the ramp's end down to the floor at the
            // curb's base, further along the curb (only where that floor is
            // there and level with the ramp's foot).
            if !off("wings") {
                let dir = along / len;
                let n = pts.len();
                for i in 0..n {
                    let Some((run, zf)) = pts[i].1 else { continue };
                    for side in [-1.0f32, 1.0] {
                        let next = i as isize + side as isize;
                        let continues = next >= 0 && (next as usize) < n && pts[next as usize].1.is_some();
                        let has_prev = { let prev = i as isize - side as isize; prev >= 0 && (prev as usize) < n && pts[prev as usize].1.is_some() };
                        if continues || !has_prev {
                            continue; // not an end of a stretch (or a lone sample)
                        }
                        let p = pts[i].0;
                        let pf = Vec3::new(p.x + out.x * run, p.y + out.y * run, zf);
                        let reach = run.min(24.0);
                        let wing = p + dir * side * reach;
                        let Some((zw, nzw)) = probe(wing, 0.5, p.z) else { continue };
                        let Some((zm, _)) = probe(p + dir * side * reach * 0.5, 0.5, p.z) else { continue };
                        if nzw < 0.9 || (zw - zf).abs() > 0.75 || (zm - zf).abs() > 0.75 {
                            continue;
                        }
                        add(p, pf, Vec3::new(wing.x + out.x * 0.5, wing.y + out.y * 0.5, zw));
                    }
                }
            }
        }
    }
    (ramps, spans)
    });
    let mut ramps = Vec::new();
    let mut spans = Vec::new();
    for (r, sp) in parts {
        ramps.extend(r);
        spans.extend(sp);
    }
    (ramps, spans)
}

/// The face under a step that a ledge ramp now covers (the riser, facing the
/// ramp, from the edge down) stays in the collision behind the ramp - and at
/// speed the wheels, pressed a little into the ramp, catch it: measured with
/// the real engine on synthetic steps (harness/lips.lua), 0.3-4 unit steps
/// lost half their speed or bailed at 9-12 m/s straight on with it, kept
/// 93-100% without it. Steep faces lying in a covered stretch's vertical
/// plane, facing out, no higher than the edge, are removed.
/// Split a triangle by the plane n.p = d: (the pieces with n.p <= d, the
/// pieces with n.p > d), each a list of triangles.
fn split_by_plane(t: &[Vec3; 3], n: Vec3, d: f32) -> (Vec<[Vec3; 3]>, Vec<[Vec3; 3]>) {
    let side: Vec<f32> = t.iter().map(|p| n.dot(*p) - d).collect();
    if side.iter().all(|&s| s <= 1e-4) { return (vec![*t], Vec::new()); }
    if side.iter().all(|&s| s >= -1e-4) { return (Vec::new(), vec![*t]); }
    let (mut below, mut above) = (Vec::new(), Vec::new());
    for i in 0..3 {
        let (a, b) = (t[i], t[(i + 1) % 3]);
        let (sa, sb) = (side[i], side[(i + 1) % 3]);
        if sa <= 0.0 { below.push(a) } else { above.push(a) }
        if (sa < 0.0 && sb > 0.0) || (sa > 0.0 && sb < 0.0) {
            let x = a + (b - a) * (sa / (sa - sb));
            below.push(x);
            above.push(x);
        }
    }
    let fan = |poly: &Vec<Vec3>| -> Vec<[Vec3; 3]> {
        (1..poly.len().saturating_sub(1)).map(|k| [poly[0], poly[k], poly[k + 1]])
            .filter(|t| (t[1] - t[0]).cross(t[2] - t[0]).length_squared() > 1e-8).collect()
    };
    (fan(&below), fan(&above))
}

/// As `covered_risers`, but a riser a ramp covers only
/// part of is cut at the ramp's ends and only the covered part goes: the
/// kept pieces of every triangle (None: unchanged).
pub fn clip_covered_risers(tris: &[[Vec3; 3]], spans: &[Covered]) -> Vec<Option<Vec<[Vec3; 3]>>> {
    let cell = |v: Vec3| ((v.x / 256.0).floor() as i32, (v.y / 256.0).floor() as i32);
    let mut grid: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
    for (i, (a, b, _)) in spans.iter().enumerate() {
        let (lo, hi) = (a.min(*b) - Vec3::splat(64.0), a.max(*b) + Vec3::splat(64.0));
        let (c0, c1) = (cell(lo), cell(hi));
        for x in c0.0..=c1.0 { for y in c0.1..=c1.1 { grid.entry((x, y)).or_default().push(i); } }
    }
    tris.iter().map(|t| {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        if n.z.abs() > 0.3 { return None; }
        let mut cands: Vec<usize> = t.iter().flat_map(|p| grid.get(&cell(*p)).cloned().unwrap_or_default()).collect();
        cands.sort_unstable();
        cands.dedup();
        let mut pieces = vec![*t];
        let mut changed = false;
        for i in cands {
            let (a, b, out) = spans[i];
            let along = Vec3::new(b.x - a.x, b.y - a.y, 0.0);
            let len = along.length();
            if len < 1e-3 || n.dot(out) < 0.7 { continue; }
            let dir = along / len;
            let top = a.z.max(b.z) + 0.05;
            // in this stretch's vertical plane, no higher than its edge
            let in_plane = |p: &Vec3| { let d = Vec3::new(p.x - a.x, p.y - a.y, 0.0); (d - dir * d.dot(dir)).length() < 0.05 && p.z <= top };
            let mut next = Vec::new();
            for pc in pieces {
                if !pc.iter().all(in_plane) { next.push(pc); continue; }
                // keep what lies before the stretch's start and past its end
                let (before, rest) = split_by_plane(&pc, dir, dir.dot(a));
                let (inside, after) = {
                    let mut ins = Vec::new();
                    let mut aft = Vec::new();
                    for r in rest { let (i2, a2) = split_by_plane(&r, dir, dir.dot(a) + len); ins.extend(i2); aft.extend(a2); }
                    (ins, aft)
                };
                if !inside.is_empty() { changed = true; }
                next.extend(before);
                next.extend(after);
            }
            pieces = next;
        }
        changed.then_some(pieces)
    }).collect()
}

/// (which of `tris` to take out: true = covered)
pub fn covered_risers(tris: &[[Vec3; 3]], spans: &[Covered]) -> Vec<bool> {
    if spans.is_empty() {
        return vec![false; tris.len()];
    }
    // spans by a coarse grid cell of their midpoint, to look up quickly
    let cell = |v: Vec3| ((v.x / 256.0).floor() as i32, (v.y / 256.0).floor() as i32);
    let mut grid: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
    for (i, (a, b, _)) in spans.iter().enumerate() {
        let (lo, hi) = (a.min(*b), a.max(*b));
        let (c0, c1) = (cell(lo), cell(hi));
        for x in c0.0..=c1.0 { for y in c0.1..=c1.1 { grid.entry((x, y)).or_default().push(i); } }
    }
    let covered = |t: &[Vec3; 3]| -> bool {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        if n.z.abs() > 0.3 { return false; }
        let c = (t[0] + t[1] + t[2]) / 3.0;
        let Some(cands) = grid.get(&cell(c)) else { return false };
        cands.iter().any(|&i| {
            let (a, b, out) = spans[i];
            let along = Vec3::new(b.x - a.x, b.y - a.y, 0.0);
            let len = along.length();
            if len < 1e-3 || n.dot(out) < 0.7 { return false; }
            let dir = along / len;
            let top = a.z.max(b.z) + 0.05;
            t.iter().all(|p| {
                let d = Vec3::new(p.x - a.x, p.y - a.y, 0.0);
                let s = d.dot(dir);
                let off = (d - dir * s).length();
                off < 0.05 && s >= -0.05 && s <= len + 0.05 && p.z <= top
            })
        })
    };
    tris.iter().map(covered).collect()
}

/// Curved transitions ("fillets") in the creases where a slope meets the floor
/// or two slope facets meet. Source ramps usually meet the ground at a hard
/// crease; to Skate 3's physics running into it is an impact that throws away
/// the speed pointing into the slope. Real ramps curve into the ground, so we
/// add an arc tangent to both surfaces that the wheels roll along instead.
///
/// `tris` are the surfaces to look at (slope faces and matched creases);
/// `ground` answers "what's below here" for finding the floor at a slope's foot.
/// `max_d` caps how far the curve reaches along each surface.
pub fn transition_fillets(tris: &[[Vec3; 3]], ground: &Heights, max_d: f32) -> Vec<[Vec3; 3]> {
    transition_fillets_with(tris, None, ground, max_d, 1.0, &mut FilletStats::default())
}

/// How many concave creases there were on rideable surfaces, and how many got a curve.
#[derive(Default, Debug, Clone, Copy)]
pub struct FilletStats {
    pub creases: usize,
    pub rounded: usize,
    pub feet: usize,
    /// ramp feet standing above the floor, bridged with a short ramp
    pub lips: usize,
    /// creases where surfaces meet without sharing an edge (they cross)
    pub crossings: usize,
}

thread_local! {
    /// (transition_fillets_only) the faces a crease must touch; finders B and C skipped
    static FILLET_ONLY: std::cell::RefCell<Option<Vec<bool>>> = const { std::cell::RefCell::new(None) };
}

/// As transition_fillets_with, only for shared-edge creases with at least one
/// face in `only` (curves for what was added after the curves pass: ramps)
pub fn transition_fillets_only(tris: &[[Vec3; 3]], coarse: Option<&[bool]>, only: &[bool], ground: &Heights, max_d: f32, coarse_min_deg: f32) -> Vec<[Vec3; 3]> {
    FILLET_ONLY.with(|o| *o.borrow_mut() = Some(only.to_vec()));
    let out = transition_fillets_with(tris, coarse, ground, max_d, coarse_min_deg, &mut FilletStats::default());
    FILLET_ONLY.with(|o| *o.borrow_mut() = None);
    out
}

/// As `transition_fillets`, with a minimum crease angle (degrees) that
/// triangles marked in `coarse` need to reach before they're rounded (used
/// for displacement terrain, which is refined and smoothed on its own).
pub fn transition_fillets_with(
    tris: &[[Vec3; 3]],
    coarse: Option<&[bool]>,
    ground: &Heights,
    max_d: f32,
    coarse_min_deg: f32,
    stats: &mut FilletStats,
) -> Vec<[Vec3; 3]> {
    let mut out = Vec::new();
    if max_d <= 0.0 {
        return out;
    }
    let key = |v: Vec3| v.to_array().map(|x| (x * 8.).round() as i32);
    let normal = |t: &[Vec3; 3]| (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
    // how far a triangle reaches from the line through a,b, along direction u
    let extent = |t: &[Vec3; 3], a: Vec3, u: Vec3| t.iter().map(|&p| (p - a).dot(u)).fold(0.0f32, f32::max);

    // A) creases shared by two triangles (matched edges), both walkable-ish
    let mut edges: HashMap<([i32; 3], [i32; 3]), Vec<(usize, Vec3, Vec3)>> = HashMap::new();
    for (i, t) in tris.iter().enumerate() {
        for e in 0..3 {
            let (a, b) = (t[e], t[(e + 1) % 3]);
            let (ka, kb) = (key(a), key(b));
            edges.entry(if ka < kb { (ka, kb) } else { (kb, ka) }).or_default().push((i, a, b));
        }
    }
    // Every concave crease from 1 degree up: each curve reaches at most 45% into
    // the faces on either side, so on a faceted curve (a quarter pipe built of
    // flat facets) neighbouring curves meet mid-facet and the surface becomes
    // one continuous arc.
    // Phase 1 collects the curve each crease piece wants; phase 2 (below) settles
    // one size per vertex so pieces of the same crease join exactly, and tapers
    // curves to nothing where a crease ends (an open end is a lip from the side).
    struct Job { a: Vec3, b: Vec3, n1: Vec3, u1: Vec3, n2: Vec3, bend: f32, d: f32, src: u8 }
    let only_a = FILLET_ONLY.with(|o| o.borrow().is_some());
    let source = std::cell::Cell::new(0u8); // which finder is running: 0 A (shared edges), 1 B (feet), 2 C (crossings)
    let mut jobs: Vec<Job> = Vec::new();
    let mut make = |a: Vec3, b: Vec3, n1: Vec3, u1: Vec3, reach1: f32, n2: Vec3, u2: Vec3, reach2: f32, min_deg: f32, _out: &mut Vec<[Vec3; 3]>| -> bool {
        let bend = n1.dot(n2).clamp(-1.0, 1.0).acos();
        if !(min_deg.to_radians()..=60f32.to_radians()).contains(&bend) {
            return false;
        }
        // The curve's size scales with the ramp: up to 45% into the smaller of
        // its two faces (up to 256 units). A fixed small curve on a huge ramp is
        // a tight turn - at top speed that pull is a bail (a 30 degree crease
        // with a 16 unit curve: a 1.5 m turn, dozens of g at 20 m/s).
        let mut cap: f32 = env_var("SK8_CURVE_CAP").ok().and_then(|v| v.parse().ok()).unwrap_or(128.0);
        // steep creases (a steep kicker's foot) can take a bigger curve than
        // the cap the gentle ones get (opt-in: SK8_STEEP_CAP, from SK8_STEEP_DEG)
        if let Some(steep) = env_var("SK8_STEEP_CAP").ok().and_then(|v| v.parse::<f32>().ok()) {
            let from: f32 = env_var("SK8_STEEP_DEG").ok().and_then(|v| v.parse().ok()).unwrap_or(35.0);
            if bend >= from.to_radians() {
                cap = cap.max(steep);
            }
        }
        let d = (reach1.min(reach2) * 0.45).min(max_d.max(cap));
        if d < 0.5 {
            return false;
        }
        let _ = u2;
        // (transition_fillets_only: shared edges and crossings, no feet)
        if only_a && source.get() == 1 {
            return false;
        }
        jobs.push(Job { a, b, n1, u1, n2, bend, d, src: source.get() });
        true
    };
    // (in a fixed order, so the same map always comes out the same)
    let mut ordered: Vec<_> = edges.iter().collect();
    ordered.sort_unstable_by_key(|(k, _)| **k);
    let only = FILLET_ONLY.with(|o| o.borrow().clone());
    // (transition_fillets_only: a crease between one of the given faces - a
    // ramp - and terrain, the case it's for: a ledge ramp running into rising
    // displacement terrain; creases with brushes or props measured worse)
    let onto_terrain = |i: usize, j: usize| {
        let given = |k: usize| only.as_ref().is_some_and(|m| m.get(k).copied().unwrap_or(false));
        let terrain = |k: usize| coarse.is_some_and(|c| c.get(k).copied().unwrap_or(false));
        (given(i) && !given(j) && terrain(j)) || (given(j) && !given(i) && terrain(i))
    };
    for (_, faces) in ordered {
        if faces.len() != 2 {
            continue;
        }
        let (i, a, b) = faces[0];
        let (j, _, _) = faces[1];
        if only.is_some() && !onto_terrain(i, j) {
            continue;
        }
        let (t1, t2) = (&tris[i], &tris[j]);
        let (n1, n2) = (normal(t1), normal(t2));
        if n1.z < 0.2 || n2.z < 0.2 {
            continue;
        }
        let e = (b - a).normalize_or_zero();
        // each face's in-surface direction away from the crease, into the face
        let inward = |t: &[Vec3; 3], n: Vec3| {
            let mut u = n.cross(e).normalize_or_zero();
            let c = (t[0] + t[1] + t[2]) / 3.0;
            if u.dot(c - a) < 0.0 {
                u = -u;
            }
            u
        };
        let (u1, u2) = (inward(t1, n1), inward(t2, n2));
        // a crease (valley): face 2 rises above face 1's plane
        if u2.dot(n1) <= 0.02 {
            continue;
        }
        let (r1, r2) = (extent(t1, a, u1), extent(t2, a, u2));
        let is_coarse = coarse.is_some_and(|c| c.get(i).copied().unwrap_or(false) || c.get(j).copied().unwrap_or(false));
        // (terrain only gets curves from 5 degrees - on small bumpy facets that
        // keeps it cheap - but big terrain facets are a ramp's face, where even
        // a 2-3 degree crease is felt at speed)
        let mut min_deg = if is_coarse && (r1.min(r2) < 48.0 || off("bigterrain")) { coarse_min_deg } else { 1.0 };
        // between narrow facets (a finely modelled surface) small creases are
        // already smooth; curves there would only pile up triangles
        if r1 < 8.0 || r2 < 8.0 {
            min_deg = min_deg.max(10.0);
        }
        if n1.dot(n2) < (min_deg.to_radians()).cos() {
            stats.creases += 1;
            if make(a, b, n1, u1, r1, n2, u2, r2, min_deg, &mut out) {
                stats.rounded += 1;
            }
        }
    }

    source.set(1);
    // B) a slope's foot meeting the floor (no shared edge: the floor is one
    // big face under it, or a different surface - terrain against a brush
    // ramp). The two rarely meet exactly: the ramp's bottom edge is often a
    // unit or two above the floor (a lip the board hits dead, at any speed:
    // Skate 3's runout) or below it (the slope comes out of the floor further
    // up). Players step over this; the board needs a real transition.
    for t in tris {
        let n = normal(t);
        if !(0.35..0.9994).contains(&n.z) {
            continue; // from 2 degrees (a ramp's first, gentle facet) up to steep
        }
        let down = Vec3::new(n.x, n.y, 0.0).normalize_or_zero(); // horizontal, downhill
        for e in 0..3 {
            let (a, b) = (t[e], t[(e + 1) % 3]);
            let c = t[(e + 2) % 3];
            let along = b - a;
            let len = along.length();
            if len < 2.0 || along.z.abs() > 0.05 * len || c.z < a.z.max(b.z) + 0.2 {
                continue; // not the slope's bottom edge
            }
            // an edge two rideable surfaces share is a crease, already rounded
            // above; only a foot standing on some other surface is handled
            // here. (A closed prop's foot edge is shared too - with the prop's
            // own bottom and front faces, which face down or sideways and get
            // no curve - so those don't count: without this a kicker prop
            // standing flush on the floor never got its foot rounded, and at
            // 11.5 m/s the board bailed at it. SK8_OFF=propfeet: as before.)
            let (ka, kb) = (key(a), key(b));
            let shared_rideable = edges.get(&if ka < kb { (ka, kb) } else { (kb, ka) }).is_some_and(|f| {
                if off("propfeet") { return f.len() >= 2; }
                f.iter().filter(|(j, _, _)| normal(&tris[*j]).z >= 0.2).count() >= 2
            });
            if shared_rideable {
                continue;
            }
            let edge = along / len;
            let mut u2 = n.cross(edge).normalize_or_zero();
            if u2.z < 0.0 {
                u2 = -u2; // up the slope
            }
            let reach2 = extent(t, a, u2);
            // the floor just past the foot, within 3 units of the edge, level
            // and the same height all along the edge
            let floor_at = |from: Vec3, dist: f32, top: f32| {
                let heights: Vec<Option<(f32, f32)>> = [0.1f32, 0.5, 0.9].iter().map(|&s| {
                    let p = from + along * s + down * dist;
                    ground.below(p.x, p.y, top)
                }).collect();
                if heights.iter().any(|h| !h.is_some_and(|(_, nz)| nz > 0.98)) {
                    return None;
                }
                let zs: Vec<f32> = heights.iter().map(|h| h.unwrap().0).collect();
                let (lo, hi) = (zs.iter().copied().fold(f32::MAX, f32::min), zs.iter().copied().fold(f32::MIN, f32::max));
                (hi - lo < 0.35).then(|| (lo + hi) / 2.0)
            };
            let ez = (a.z + b.z) / 2.0;
            let Some(zf) = floor_at(a, 0.75, ez + 3.5) else { continue };
            let h = zf - ez; // floor above the edge (> 0) or below it (< 0)
            if h.abs() > 3.0 {
                continue;
            }
            // how far the floor carries on flat from `from`
            let reach_from = |from: Vec3| {
                let mut r = 0.0;
                for dist in [4.0f32, 8.0, 16.0, 24.0, 36.0] {
                    match floor_at(from, dist, zf + 0.5) {
                        Some(z) if (z - zf).abs() < 0.35 => r = dist,
                        _ => break,
                    }
                }
                r
            };
            if h.abs() < 0.35 {
                // meeting at the floor: a curve, as always
                let reach1 = reach_from(a);
                if make(a, b, Vec3::Z, down, reach1 / 0.45, n, u2, reach2, 1.0, &mut out) {
                    stats.feet += 1;
                }
            } else if h < 0.0 {
                // the edge stands above the floor: a short ramp up onto it
                let run = (-h * 8.0).clamp(8.0, 32.0);
                if reach_from(a) >= run.min(24.0) {
                    let (fa, fb) = (Vec3::new(a.x, a.y, zf) + down * run, Vec3::new(b.x, b.y, zf) + down * run);
                    for tri in [[a, b, fb], [a, fb, fa]] {
                        let m = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
                        out.push(if m.z >= 0.0 { tri } else { [tri[0], tri[2], tri[1]] });
                    }
                    stats.lips += 1;
                }
            } else {
                // the edge is buried: the slope comes out of the floor further up;
                // the curve goes there
                let shift = h / u2.z.max(0.02);
                if shift < reach2 * 0.8 {
                    let (sa, sb) = (a + u2 * shift, b + u2 * shift);
                    let reach1 = reach_from(sa);
                    if make(sa, sb, Vec3::Z, down, reach1 / 0.45, n, u2, reach2 - shift, 1.0, &mut out) {
                        stats.feet += 1;
                    }
                }
            }
        }
    }
    // C) any two rideable surfaces that meet without sharing an edge: pieces
    // of a prop's convex hulls, a prop ramp sunk into terrain (its slope comes
    // out of the floor), brushes whose edges don't coincide. The crease is the
    // line where their planes cross, over the stretch that lies on both.
    source.set(2);
    // (with near-misses counted this cut uphill crease kinks by ~60% on
    // tl_skatepark - SK8_OFF=crossings to compare without it)
    if !off("crossings") || only.is_some() {
        let rideable: Vec<usize> = (0..tris.len())
            .filter(|&i| { let t = &tris[i]; let n = (t[1] - t[0]).cross(t[2] - t[0]); n.length() > 2.0 && n.normalize().z > 0.5 })
            .collect();
        const CELL_C: f32 = 64.0;
        let mut grid: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
        for &i in &rideable {
            let t = &tris[i];
            let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
            let (x0, x1, y0, y1) = ((lo.x / CELL_C).floor() as i32, (hi.x / CELL_C).floor() as i32, (lo.y / CELL_C).floor() as i32, (hi.y / CELL_C).floor() as i32);
            if ((x1 - x0 + 1) * (y1 - y0 + 1)) as i64 > 4096 { continue; }
            for x in x0..=x1 { for y in y0..=y1 { grid.entry((x, y)).or_default().push(i); } }
        }
        // the stretch of a line (p + t d) inside a triangle (in its plane), padded
        let clip = |t: &[Vec3; 3], n: Vec3, p: Vec3, d: Vec3, pad: f32| -> Option<(f32, f32)> {
            let (mut lo, mut hi) = (f32::MIN, f32::MAX);
            for e in 0..3 {
                let (a, b) = (t[e], t[(e + 1) % 3]);
                let inward = n.cross(b - a).normalize_or_zero(); // points into the triangle
                let dist = (p - a).dot(inward) + pad; // >= 0 inside
                let rate = d.dot(inward);
                if rate.abs() < 1e-6 {
                    if dist < 0.0 { return None; }
                } else {
                    let t0 = -dist / rate;
                    if rate > 0.0 { lo = lo.max(t0); } else { hi = hi.min(t0); }
                }
            }
            (hi - lo > 1e-3).then_some((lo, hi))
        };
        let mut pairs: Vec<(usize, usize)> = Vec::new();
        let mut cells: Vec<_> = grid.iter().collect();
        cells.sort_unstable_by_key(|(k, _)| **k);
        let mut seen = std::collections::HashSet::new();
        for (_, list) in cells {
            // (only creases touching given faces: only cells holding one)
            if let Some(m) = &only {
                if !list.iter().any(|&i| m.get(i).copied().unwrap_or(false)) { continue; }
            }
            for (x, &i) in list.iter().enumerate() {
                for &j in &list[x + 1..] {
                    let (a, b) = if i < j { (i, j) } else { (j, i) };
                    if let Some(m) = &only {
                        if !(m.get(a).copied().unwrap_or(false) || m.get(b).copied().unwrap_or(false)) { continue; }
                    }
                    if seen.insert((a, b)) { pairs.push((a, b)); }
                }
            }
        }
        let candidate = |(i, j): (usize, usize)| -> Option<(Vec3, Vec3, Vec3, Vec3, f32, Vec3, Vec3, f32, f32)> {
            let (t1, t2) = (&tris[i], &tris[j]);
            // sharing an edge: that's A's
            let shared = t1.iter().filter(|p| t2.iter().any(|q| key(**p) == key(*q))).count();
            if shared >= 2 { return None; }
            let (n1, n2) = (normal(t1), normal(t2));
            let bend = n1.dot(n2).clamp(-1.0, 1.0).acos();
            // (from 5 degrees: gentler near-misses between nearly flat pieces
            // are many, cost a lot of triangles and hardly change the ride)
            let c_min: f32 = env_var("SK8_CROSS_MIN").ok().and_then(|v| v.parse().ok()).unwrap_or(5.0);
            if bend < c_min.to_radians() || bend > 60f32.to_radians() { return None; }
            // (only creases touching given faces - ramps: just where the ramp
            // runs into ground rising more steeply than it does, not every
            // ledge ramp's foot on the flat floor it starts from)
            if let Some(m) = &only {
                if !onto_terrain(i, j) { return None; }
                let (ramp_n, other_n) = if m.get(i).copied().unwrap_or(false) { (n1, n2) } else { (n2, n1) };
                if other_n.z > ramp_n.z - 5f32.to_radians().sin() * 0.5 { return None; }
            }
            let d = n1.cross(n2).normalize_or_zero();
            if d == Vec3::ZERO { return None; }
            // a point on both planes: n1.p = n1.a1, n2.p = n2.a2, on the line nearest the triangles
            let (c1, c2) = (n1.dot(t1[0]), n2.dot(t2[0]));
            let n12 = n1.dot(n2);
            let det = 1.0 - n12 * n12;
            if det < 1e-6 { return None; }
            let base = n1 * ((c1 - c2 * n12) / det) + n2 * ((c2 - c1 * n12) / det);
            let mid_tris = (t1[0] + t1[1] + t1[2] + t2[0] + t2[1] + t2[2]) / 6.0;
            let p0 = base + d * (mid_tris - base).dot(d);
            // (a near-miss counts: the crease line may lie up to `pad` outside a
            // triangle - two pieces of a prop that overlap, one's edge hanging a
            // fraction of a unit over the other: a tiny overhang to the board)
            let pad: f32 = env_var("SK8_CROSS_PAD").ok().and_then(|v| v.parse().ok()).unwrap_or(2.0);
            let (Some((a1, b1)), Some((a2, b2))) = (clip(t1, n1, p0, d, pad), clip(t2, n2, p0, d, pad)) else { return None };
            let (lo, hi) = (a1.max(a2), b1.min(b2));
            if hi - lo < 2.0 { return None; }
            let (a, b) = (p0 + d * lo, p0 + d * hi);
            // a valley: each surface rises above the other on its own side
            let mut u2 = n2.cross(d).normalize_or_zero();
            if u2.dot(n1) < 0.0 { u2 = -u2; }
            let mut u1 = n1.cross(d).normalize_or_zero();
            if u1.dot(n2) < 0.0 { u1 = -u1; }
            let (r1, r2) = (extent(t1, a, u1), extent(t2, a, u2));
            if r1 < 1.0 || r2 < 1.0 { return None; }
            let is_coarse = coarse.is_some_and(|c| c.get(i).copied().unwrap_or(false) || c.get(j).copied().unwrap_or(false));
            let min_deg = if is_coarse && r1.min(r2) < 48.0 { coarse_min_deg } else { 1.0 };
            Some((a, b, n1, u1, r1, n2, u2, r2, min_deg))
        };
        // (each pair on its own, over the CPU's cores; handed on in order)
        let found = par_map(&pairs, |chunk| chunk.iter().filter_map(|&pr| candidate(pr)).collect::<Vec<_>>());
        for (a, b, n1, u1, r1, n2, u2, r2, min_deg) in found.into_iter().flatten() {
            if make(a, b, n1, u1, r1, n2, u2, r2, min_deg, &mut out) {
                stats.crossings += 1;
            }
        }
    }

    // Phase 2: one curve size per vertex. Where pieces of the same crease (the
    // same two surfaces) meet, the size is the smallest any of them wants;
    // where a crease ends, zero. Along each piece the size then varies with
    // distance from its ends (growing half a unit per unit), so the curve
    // tapers in and out and joins its neighbours exactly.
    let vkey = |v: Vec3| v.to_array().map(|x| (x * 8.).round() as i32);
    let mut at: HashMap<[i32; 3], Vec<usize>> = HashMap::new();
    for (i, j) in jobs.iter().enumerate() {
        at.entry(vkey(j.a)).or_default().push(i);
        at.entry(vkey(j.b)).or_default().push(i);
    }
    let either_order = on("creaseorder");
    let same_crease = |x: &Job, y: &Job| {
        (x.n1.dot(y.n1) > 0.999 && x.n2.dot(y.n2) > 0.999) || (either_order && x.n1.dot(y.n2) > 0.999 && x.n2.dot(y.n1) > 0.999)
    };
    // The biggest curve (up to `want`) at crease point `e` whose two edges land
    // on real surface: faces are triangles, so a face narrows along the crease
    // and a curve sized by its widest point would hang off its slanted side
    // into the air (a floating edge the board hits). Deterministic in (e, job
    // surfaces), so neighbouring pieces agree at shared points.
    let fits = |j: &Job, e: Vec3, want: f32| -> f32 {
        let r_per_d = 1.0 / (j.bend * 0.5).tan();
        let edge_on_face2 = |d: f32| {
            // the curve's end on face 2: its cross-section at the last step
            let dir = -j.n2;
            e + (j.u1 + j.n1 * r_per_d + dir * r_per_d) * d
        };
        let lands = |p: Vec3, n: Vec3| {
            if n.z < 0.3 {
                return true; // a steep face: can't probe from above (the curve ends on it)
            }
            ground.below(p.x, p.y, p.z + 0.3).is_some_and(|(z, nz)| (z - p.z).abs() < 0.2 && (nz - n.z).abs() < 0.05)
        };
        let mut d = want;
        for _ in 0..4 {
            if d < 0.5 {
                return 0.0;
            }
            if lands(e + j.u1 * d, j.n1) && lands(edge_on_face2(d), j.n2) {
                return d;
            }
            d *= 0.5;
        }
        0.0
    };
    let size_at = |v: Vec3, me: usize| -> f32 {
        let mine = &jobs[me];
        let others: Vec<usize> = at.get(&vkey(v)).map(|l| l.iter().copied().filter(|&k| k != me && same_crease(&jobs[k], mine)).collect()).unwrap_or_default();
        if others.is_empty() {
            0.0 // the crease ends here
        } else {
            let d = others.iter().map(|&k| jobs[k].d).fold(mine.d, f32::min);
            fits(mine, v, d)
        }
    };
    const TAPER: f32 = 0.5; // size grows this much per unit along the crease
    // (each piece on its own, so spread over the CPU's cores; joined in order)
    let order: Vec<usize> = (0..jobs.len()).collect();
    let rejected: Vec<std::sync::atomic::AtomicU32> = (0..3).map(|_| std::sync::atomic::AtomicU32::new(0)).collect();
    let parts = par_map(&order, |chunk| {
    let mut out = Vec::new();
    for &ji in chunk {
        let j = &jobs[ji];
        // (a huge curve tapers proportionally faster - 0.5 units per unit would
        // leave it far from full size across a ramp narrower than 500 units)
        let taper = TAPER.max(j.d / 100.0);
        let (da, db) = if off("taper") { (j.d, j.d) } else { (size_at(j.a, ji), size_at(j.b, ji)) };
        let len = (j.b - j.a).length();
        let r_per_d = 1.0 / (j.bend * 0.5).tan();
        // strips: each turns at most 1.5 degrees and runs at most ~4 units of arc
        // (a big curve in 1.5 degree strips would be a kink every 10 units -
        // small, but felt at top speed)
        let arc = j.d * r_per_d * j.bend;
        // (but never finer than 0.3 degrees a strip: a gentle crease's long
        // curve barely turns, and splitting it finer only adds triangles)
        let by_angle = (j.bend / 1.5f32.to_radians()).ceil() as usize;
        let by_length = ((arc / 4.0).ceil() as usize).min((j.bend / 0.3f32.to_radians()).ceil() as usize);
        // (only big curves - the ones met at top speed - need the extra strips;
        // skatepark-sized ones are smooth enough at 1.5 degrees)
        let steps = if j.d >= 32.0 { by_angle.max(by_length) } else { by_angle }.clamp(4, 64);
        // the curve's cross-section for size 1 (it scales with the size)
        let unit = |k: usize| {
            let f = k as f32 / steps as f32;
            let dir = (-j.n1 * ((1.0 - f) * j.bend).sin() + -j.n2 * (f * j.bend).sin()) / j.bend.sin();
            j.u1 + j.n1 * r_per_d + dir.normalize() * r_per_d
        };
        // stations every 8 units along the piece, each checked against the
        // real surface
        // The size along the piece: from each end's size, an S-curve up to a flat
        // top (no kink where a taper meets the top), the top kept low enough on
        // a short crease that the two tapers end right in the middle - never a
        // peak, which would be a ridge across the transition.
        // (each taper lasts (size change / taper) units; both fit when...)
        let top = j.d.min((len * taper + da + db) / 2.0).max(da).max(db);
        let (la, lb) = ((top - da) / taper, (top - db) / taper);
        let smooth = |t: f32| { let t = t.clamp(0.0, 1.0); t * t * (3.0 - 2.0 * t) };
        // (measuring: SK8_TAPER=linear - the straight taper of 5.18; soft - the
        // straight taper with its corners rounded; default s - S-curves)
        // (soft is the default: it measured best on tl_skatepark)
        let mode = env_var("SK8_TAPER").unwrap_or_else(|_| "soft".into());
        let profile = |x: f32| -> f32 {
            if mode == "linear" {
                return j.d.min(da + x * taper).min(db + (len - x) * taper);
            }
            if mode == "soft" || mode == "soft+" {
                // straight tapers with their corners rounded: a smooth minimum
                // (never above the plain minimum; within w of it at a corner)
                let w = (j.d * 0.15).max(0.25);
                let d_full = if mode == "soft+" { j.d * 1.15 } else { j.d };
                let smin = |a: f32, b: f32| (a + b) * 0.5 - (((a - b) * 0.5).powi(2) + w * w).sqrt();
                return smin(smin(da + x * taper, db + (len - x) * taper), d_full).max(0.0);
            }
            if la > 1e-3 && x < la {
                da + (top - da) * smooth(x / la)
            } else if lb > 1e-3 && x > len - lb {
                db + (top - db) * smooth((len - x) / lb)
            } else {
                top
            }
        };
        // stations: four through each taper, then every 8 units along the rest
        let mut marks: Vec<f32> = vec![0.0];
        let push_range = |marks: &mut Vec<f32>, from: f32, to: f32, step: f32| {
            let n = ((to - from) / step.max(0.5)).ceil().max(1.0) as usize;
            for k in 1..=n.min(64) {
                marks.push(from + (to - from) * k as f32 / n.min(64) as f32);
            }
        };
        let (ta, tb) = (la.min(len * 0.5), lb.min(len * 0.5));
        // (how finely a taper is followed: a fold in it can't be worse than the
        // crease's own bend, so gentle creases just taper straight; a small
        // taper - under 2 units of size change - needs only one stop)
        let bend_deg = j.bend.to_degrees();
        let per = |change: f32| if bend_deg < 6.0 { 1.0 } else if bend_deg < 12.0 || change < 2.0 { 2.0 } else { 4.0 };
        if ta > 1e-3 { push_range(&mut marks, 0.0, ta, ta / per(top - da)); }
        push_range(&mut marks, ta, len - tb, 8.0);
        if tb > 1e-3 { push_range(&mut marks, len - tb, len, tb / per(top - db)); }
        marks.dedup_by(|a, b| (*a - *b).abs() < 1e-4);
        let size = |s: f32| {
            let want = profile(s * len);
            if s <= 0.0 { da.min(want) } else if s >= 1.0 { db.min(want) } else { fits(j, j.a + (j.b - j.a) * s, want) }
        };
        let up = (j.n1 + j.n2).normalize_or_zero();
        // the size at each station, then only the stations where it bends:
        // where it changes linearly (usually: it doesn't change at all), one
        // long strip is the same surface as several short ones
        let all: Vec<(f32, f32)> = marks.iter().map(|&x| { let s = (x / len.max(1e-6)).clamp(0.0, 1.0); (s, size(s)) }).collect();
        let mut keep: Vec<(f32, f32)> = vec![all[0]];
        // a station may go only if everything dropped since the last one kept
        // still lies on the new straight piece (checking just its neighbours
        // lets the line drift, cutting corners and shrinking curves)
        let tol: f32 = env_var("SK8_MERGE_TOL").ok().and_then(|v| v.parse().ok()).unwrap_or(0.02);
        let mut dropped: Vec<(f32, f32)> = Vec::new();
        for i in 1..all.len() - 1 {
            let (prev, here, next) = (*keep.last().unwrap(), all[i], all[i + 1]);
            let on_line = |p: (f32, f32)| {
                let t = (p.0 - prev.0) / (next.0 - prev.0).max(1e-6);
                (prev.1 + (next.1 - prev.1) * t - p.1).abs() <= (j.d * tol).max(0.05)
            };
            if on_line(here) && dropped.iter().all(|&p| on_line(p)) {
                dropped.push(here);
            } else {
                keep.push(here);
                dropped.clear();
            }
        }
        keep.push(*all.last().unwrap());
        if all.iter().all(|&(_, d)| d < 0.05) {
            rejected[jobs[ji].src as usize].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        }
        for w in keep.windows(2) {
            let ((s0, d0), (s1, d1)) = (w[0], w[1]);
            let (e0, e1) = (j.a + (j.b - j.a) * s0, j.a + (j.b - j.a) * s1);
            if d0 < 0.05 && d1 < 0.05 {
                continue;
            }
            for k in 0..steps {
                let quad = [e0 + unit(k) * d0, e1 + unit(k) * d1, e1 + unit(k + 1) * d1, e0 + unit(k + 1) * d0];
                // (a strip whose size changes along it is twisted; split in four
                // around its middle measured no better than two, so: two)
                let pieces = [[quad[0], quad[1], quad[2]], [quad[0], quad[2], quad[3]]];
                for &tri in &pieces {
                    let n = (tri[1] - tri[0]).cross(tri[2] - tri[0]);
                    if n.length_squared() < 1e-8 {
                        continue;
                    }
                    out.push(if n.dot(up) >= 0.0 { tri } else { [tri[0], tri[2], tri[1]] });
                }
            }
        }
    }
    out
    });
    for p in parts {
        out.extend(p);
    }
    if env_var("SK8_CURVESTATS").is_ok() {
        let mut by_bend = [0usize; 5];
        for j in &jobs {
            let b = j.bend.to_degrees();
            by_bend[if b < 3.0 { 0 } else if b < 6.0 { 1 } else if b < 12.0 { 2 } else if b < 25.0 { 3 } else { 4 }] += 1;
        }
        eprintln!("CURVES: {} pieces (bend <3: {}, 3-6: {}, 6-12: {}, 12-25: {}, 25+: {}), {} triangles", jobs.len(), by_bend[0], by_bend[1], by_bend[2], by_bend[3], by_bend[4], out.len());
        for (k, name) in ["A shared edges", "B ramp feet", "C crossings"].iter().enumerate() {
            let n = jobs.iter().filter(|j| j.src as usize == k).count();
            eprintln!("CURVES:   {name}: {n} pieces, {} rejected entirely by the landing check", rejected[k].load(std::sync::atomic::Ordering::Relaxed));
        }
    }
    out
}

/// Work split over the CPU's cores: `f` runs on slices of `items` at the same
/// time, and the results come back in order (so the output is the same as
/// doing it in one go).
/// (for measuring: SK8_OFF="cracks,gaps,..." turns individual steps off)
pub fn off(step: &str) -> bool {
    with_env("SK8_OFF", |v| v.is_some_and(|v| v.split(',').any(|s| s.trim() == step)))
}

/// (for measuring: SK8_ON="crossings,..." turns experimental steps on)
pub fn on(step: &str) -> bool {
    with_env("SK8_ON", |v| v.is_some_and(|v| v.split(',').any(|s| s.trim() == step)))
}

static ENV_GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

thread_local! {
    static ENV_CACHE: std::cell::RefCell<(u64, HashMap<String, Option<String>>)> = std::cell::RefCell::new((0, HashMap::new()));
}

pub fn set_env(name: &str, value: Option<&str>) {
    match value {
        Some(v) if !v.is_empty() => std::env::set_var(name, v),
        _ => std::env::remove_var(name),
    }
    ENV_GEN.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
}

fn with_env<R>(name: &str, f: impl FnOnce(Option<&str>) -> R) -> R {
    ENV_CACHE.with(|cache| {
        let mut cache = cache.borrow_mut();
        let gen = ENV_GEN.load(std::sync::atomic::Ordering::SeqCst);
        if cache.0 != gen {
            cache.1.clear();
            cache.0 = gen;
        }
        if !cache.1.contains_key(name) {
            let value = std::env::var(name).ok();
            cache.1.insert(name.to_string(), value);
        }
        f(cache.1.get(name).and_then(|v| v.as_deref()))
    })
}

pub fn env_var(name: &str) -> Result<String, std::env::VarError> {
    with_env(name, |v| v.map(str::to_string).ok_or(std::env::VarError::NotPresent))
}

#[derive(Default, Clone, Copy)]
pub struct CellHasher(u64);

impl std::hash::Hasher for CellHasher {
    fn finish(&self) -> u64 {
        self.0
    }
    fn write(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 = (self.0.rotate_left(5) ^ u64::from(b)).wrapping_mul(0x51_7cc1_b727_220a_95);
        }
    }
    fn write_i32(&mut self, n: i32) {
        self.0 = (self.0.rotate_left(5) ^ u64::from(n as u32)).wrapping_mul(0x51_7cc1_b727_220a_95);
    }
}

pub type CellMap<V> = HashMap<(i32, i32), V, std::hash::BuildHasherDefault<CellHasher>>;

thread_local! {
    static BACKGROUND: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

pub fn run_in_background() {
    BACKGROUND.with(|b| b.set(true));
    #[cfg(windows)]
    {
        extern "system" {
            fn GetCurrentThread() -> isize;
            fn SetThreadPriority(thread: isize, priority: i32) -> i32;
        }
        if env_var("SK8_NORMAL_PRIORITY").is_err() {
            unsafe {
                SetThreadPriority(GetCurrentThread(), -1);
            }
        }
    }
}

pub fn worker_threads() -> usize {
    env_var("SK8_THREADS").ok().and_then(|v| v.parse().ok())
        .unwrap_or_else(|| std::thread::available_parallelism().map_or(1, |n| n.get()).saturating_sub(1))
        .clamp(1, 16)
}

pub fn par_map<T: Sync, R: Send>(items: &[T], f: impl Fn(&[T]) -> R + Sync) -> Vec<R> {
    let threads = worker_threads();
    if threads <= 1 || items.len() < 512 {
        return vec![f(items)];
    }
    let chunk = items.len().div_ceil(threads * 3);
    let background = BACKGROUND.with(|b| b.get());
    std::thread::scope(|s| {
        let f = &f;
        let handles: Vec<_> = items.chunks(chunk).map(|c| s.spawn(move || {
            if background {
                run_in_background();
            }
            f(c)
        })).collect();
        handles.into_iter().map(|h| h.join().expect("worker thread")).collect()
    })
}

/// Where separate pieces nearly meet (brushes of a ramp's facets a few
/// hundredths of a unit apart), make them meet exactly: vertices within `tol`
/// of each other become one. Triangles that collapse are dropped, and so are
/// duplicates (two overlapping brushes producing the same face): otherwise a
/// joint is a micro-step the board hits, and an edge with three faces on it
/// isn't recognised as a crease to round. Returns (tris, tags, merged, removed).
pub fn weld_and_dedupe(tris: Vec<[Vec3; 3]>, tags: Vec<u8>, tol: f32) -> (Vec<[Vec3; 3]>, Vec<u8>, usize, usize) {
    let cell = |v: Vec3| ((v.x / tol).floor() as i64, (v.y / tol).floor() as i64, (v.z / tol).floor() as i64);
    let mut reps: Vec<Vec3> = Vec::new();
    let mut grid: HashMap<(i64, i64, i64), Vec<u32>> = HashMap::new();
    let mut merged = 0;
    let mut rep_of = |v: Vec3, reps: &mut Vec<Vec3>| -> u32 {
        let c = cell(v);
        for dx in -1..=1 {
            for dy in -1..=1 {
                for dz in -1..=1 {
                    if let Some(list) = grid.get(&(c.0 + dx, c.1 + dy, c.2 + dz)) {
                        for &i in list {
                            if (reps[i as usize] - v).length() <= tol {
                                if reps[i as usize] != v {
                                    merged += 1;
                                }
                                return i;
                            }
                        }
                    }
                }
            }
        }
        reps.push(v);
        let i = (reps.len() - 1) as u32;
        grid.entry(c).or_default().push(i);
        i
    };
    let mut out = Vec::with_capacity(tris.len());
    let mut out_tags = Vec::with_capacity(tris.len());
    let mut seen = std::collections::HashSet::new();
    let mut removed = 0;
    for (t, g) in tris.into_iter().zip(tags) {
        let ids = [rep_of(t[0], &mut reps), rep_of(t[1], &mut reps), rep_of(t[2], &mut reps)];
        if ids[0] == ids[1] || ids[1] == ids[2] || ids[0] == ids[2] {
            removed += 1;
            continue;
        }
        // the same face facing the same way (a rotation of the same ids)
        let m = (0..3).min_by_key(|&k| ids[k]).unwrap();
        let key = (ids[m], ids[(m + 1) % 3], ids[(m + 2) % 3]);
        if !seen.insert(key) {
            removed += 1;
            continue;
        }
        let w = ids.map(|i| reps[i as usize]);
        if (w[1] - w[0]).cross(w[2] - w[0]).length_squared() < 1e-6 {
            removed += 1;
            continue;
        }
        out.push(w);
        out_tags.push(g);
    }
    (out, out_tags, merged, removed)
}

/// Steep faces hidden just under a floor: the front of a ramp's brush buried
/// under terrain, its top edge flush with the terrain's surface. Hidden in the
/// game, but the wheels (which sit a hair into the floor, as contacts do) catch
/// that top edge and stop dead. A face is dropped when a rideable surface just
/// in front of it is at or above its top edge. (A real curb has lower ground in
/// front of it and stays.)
/// Steep faces by where they are, to ask whether a wall carries on at a point
#[derive(Default)]
struct Walls {
    tris: Vec<[Vec3; 3]>,
    grid: HashMap<(i32, i32), Vec<u32>>,
}

impl Walls {
    const CELL: f32 = 64.0;

    fn new(tris: &[[Vec3; 3]]) -> Self {
        let mut w = Walls::default();
        for t in tris {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
            if n.z.abs() >= 0.7 || n == Vec3::ZERO {
                continue;
            }
            let i = w.tris.len() as u32;
            w.tris.push(*t);
            let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
            for x in (lo.x / Self::CELL).floor() as i32..=(hi.x / Self::CELL).floor() as i32 {
                for y in (lo.y / Self::CELL).floor() as i32..=(hi.y / Self::CELL).floor() as i32 {
                    w.grid.entry((x, y)).or_default().push(i);
                }
            }
        }
        w
    }

    /// whether a steep face other than `own`, facing the same way as `n`,
    /// passes through `p` (within a hair of its plane, inside its edges)
    fn continues(&self, p: Vec3, n: Vec3, own: &[Vec3; 3]) -> bool {
        let key = ((p.x / Self::CELL).floor() as i32, (p.y / Self::CELL).floor() as i32);
        self.grid.get(&key).is_some_and(|list| list.iter().any(|&i| {
            let t = &self.tris[i as usize];
            if t == own {
                return false;
            }
            let m = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
            if m.dot(n) < 0.99 || (p - t[0]).dot(m).abs() > 0.05 {
                return false;
            }
            (0..3).all(|k| (t[(k + 1) % 3] - t[k]).cross(p - t[k]).dot(m) >= -1e-3)
        }))
    }
}

/// The face `t` without the stretches across its width (sampled every 8 units
/// along the wall, at the face's own top there) that have floor in front at
/// that height (`covered`) and no wall carrying on above (`wall_above`); None
/// when nothing is covered, or everything, or it's too narrow to cut.
fn cut_covered_stretches(
    t: &[Vec3; 3],
    flat_out: Vec3,
    covered: &dyn Fn(Vec3, f32) -> bool,
    wall_above: &dyn Fn(Vec3) -> bool,
) -> Option<Vec<[Vec3; 3]>> {
    const STEP: f32 = 8.0;
    let dir = Vec3::new(-flat_out.y, flat_out.x, 0.0);
    let s: Vec<f32> = t.iter().map(|p| p.dot(dir)).collect();
    let (lo, hi) = (s[0].min(s[1]).min(s[2]), s[0].max(s[1]).max(s[2]));
    let len = hi - lo;
    if len < 2.0 * STEP {
        return None;
    }
    // the face's highest point across it at position x along the wall
    let top_at = |x: f32| -> Option<Vec3> {
        let mut best: Option<Vec3> = None;
        for k in 0..3 {
            let (p, q, sp, sq) = (t[k], t[(k + 1) % 3], s[k], s[(k + 1) % 3]);
            if (sp - x) * (sq - x) > 0.0 || (sp - sq).abs() < 1e-6 {
                continue;
            }
            let c = p + (q - p) * ((x - sp) / (sq - sp));
            if best.is_none_or(|b| c.z > b.z) {
                best = Some(c);
            }
        }
        best
    };
    let steps = (len / STEP).ceil() as usize;
    let hit: Vec<bool> = (0..steps)
        .map(|i| {
            let x = lo + len * ((i as f32 + 0.5) / steps as f32);
            top_at(x).is_some_and(|p| covered(p, p.z) && !wall_above(p))
        })
        .collect();
    if hit.iter().all(|&h| !h) || hit.iter().all(|&h| h) {
        return None;
    }
    // keep the pieces between covered runs
    let mut keep: Vec<[Vec3; 3]> = Vec::new();
    let mut rest = vec![*t];
    let mut i = 0;
    while i < steps {
        let run = hit[i];
        let mut j = i;
        while j < steps && hit[j] == run {
            j += 1;
        }
        let cut = lo + len * (j as f32 / steps as f32);
        let mut next = Vec::new();
        for pc in rest {
            let (before, after) = if j == steps { (vec![pc], Vec::new()) } else { split_by_plane(&pc, dir, cut) };
            if !run {
                keep.extend(before);
            }
            next.extend(after);
        }
        rest = next;
        i = j;
    }
    Some(keep.into_iter().filter(|p| (p[1] - p[0]).cross(p[2] - p[0]).length() > 1e-4).collect())
}

/// SK8_HIDDEN_DEBUG=x,y: the hidden-face step's decision for faces near there
fn hidden_debug() -> Option<(f32, f32)> {
    let v = env_var("SK8_HIDDEN_DEBUG").ok()?;
    let mut it = v.split(',').map(|s| s.trim().parse::<f32>());
    Some((it.next()?.ok()?, it.next()?.ok()?))
}

/// (hiddenoutline) a hidden face stays if part of its upper outline stands
/// more than this above the ground in front of it: a wall's foot, not a curb
const OUTLINE_CLEAR: f32 = 8.0;

pub fn remove_hidden_under_floor(tris: Vec<[Vec3; 3]>, tags: Vec<u8>) -> (Vec<[Vec3; 3]>, Vec<u8>, usize) {
    remove_hidden_under_floor_with(tris, tags, on("hiddenwidth"))
}

/// As `remove_hidden_under_floor`; with `full_width`, each face is probed across
/// its whole width at its top (the lower half of a wall quad has a single top
/// corner, and probing only there can drop half of a visible curb front).
/// (Measured in 5.28 with densebury: not better - opt-in, SK8_ON=hiddenwidth.)
pub fn remove_hidden_under_floor_with(tris: Vec<[Vec3; 3]>, tags: Vec<u8>, full_width: bool) -> (Vec<[Vec3; 3]>, Vec<u8>, usize) {
    let rideable: Vec<[Vec3; 3]> = tris
        .iter()
        .filter(|t| (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().z > 0.7)
        .copied()
        .collect();
    let floors = Heights::new(&rideable);
    let outline = !off("hiddenoutline");
    let partial = on("hiddenpartial");
    let walls = if outline || partial { Walls::new(&tris) } else { Walls::default() };
    let items: Vec<([Vec3; 3], u8)> = tris.into_iter().zip(tags).collect();
    let parts = par_map(&items, |chunk| {
    let mut out = Vec::with_capacity(chunk.len());
    let mut out_tags = Vec::with_capacity(chunk.len());
    let mut removed = 0;
    for &(t, g) in chunk {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        let flat_out = Vec3::new(n.x, n.y, 0.0);
        if n.z.abs() >= 0.7 || flat_out.length_squared() < 0.25 {
            out.push(t);
            out_tags.push(g);
            continue;
        }
        let flat_out = flat_out.normalize();
        let top = t[0].z.max(t[1].z).max(t[2].z);
        // along the face's top edge, one unit out in front of it (or across
        // the face's whole width at its top: see above)
        let (a, b) = if !full_width {
            let tops: Vec<Vec3> = t.iter().filter(|p| p.z > top - 0.5).copied().collect();
            (tops[0], *tops.last().unwrap())
        } else {
            let along = Vec3::new(-flat_out.y, flat_out.x, 0.0);
            let s: Vec<f32> = t.iter().map(|p| p.dot(along)).collect();
            let (lo, hi) = (s.iter().copied().fold(f32::MAX, f32::min), s.iter().copied().fold(f32::MIN, f32::max));
            let base = Vec3::new(t[0].x, t[0].y, top) - along * s[0];
            (base + along * lo, base + along * hi)
        };
        // (ground in front at or above height h: searched down from the face's top)
        let covered = |p: Vec3, h: f32| {
            let q = p + flat_out * 1.0;
            floors.below(q.x, q.y, top + 1.0).is_some_and(|(z, _)| z >= h - 0.25)
        };
        let mut hidden = [0.15f32, 0.5, 0.85].iter().all(|&s| covered(a + (b - a) * s, top));
        // (not the foot of a taller wall - SK8_OFF=hiddenoutline to compare. A sliver along
        // a wall's foot has one top corner where the ground in front is high,
        // and judged there alone the whole strip went, leaving a slot under the
        // wall at floor height, gm_skatepark 150 -788. Kept when part of its
        // upper outline - the two edges down from its top corner - stands more
        // than a curb's height clear of the ground in front AND the same wall
        // carries on just above it; a face whose upper edge is the wall's real
        // top - a curb or ramp front - still goes)
        if hidden && outline {
            let hi = (0..3).max_by(|&i, &j| t[i].z.total_cmp(&t[j].z)).unwrap_or(0);
            let (p0, p1, p2) = (t[hi], t[(hi + 1) % 3], t[(hi + 2) % 3]);
            let clear = |p: Vec3| {
                let q = p + flat_out * 1.0;
                floors.below(q.x, q.y, top + 1.0).map_or(0.0, |(z, _)| p.z - z)
            };
            let wall_above = |p: Vec3| walls.continues(p + Vec3::Z * 1.0, n, &t);
            let foot_of_wall = [p1, p2].iter().any(|&q| [0.25f32, 0.5, 0.75].iter().any(|&s| {
                let p = p0 + (q - p0) * s;
                clear(p) > OUTLINE_CLEAR && wall_above(p)
            }));
            hidden = !foot_of_wall;
        }
        // (hiddenpartial) covered only along part of its top: the covered
        // stretches cut out (pf -2760 1590: an 860-long slab side, flush
        // with the floor in front at one end, open at its middle)
        if !hidden && partial {
            if let Some(pieces) = cut_covered_stretches(&t, flat_out, &covered, &|p| walls.continues(Vec3::new(p.x, p.y, top + 1.0), n, &t)) {
                removed += 1;
                for pc in pieces {
                    out.push(pc);
                    out_tags.push(g);
                }
                continue;
            }
        }
        if let Some((dx, dy)) = hidden_debug() {
            let c = (t[0] + t[1] + t[2]) / 3.0;
            if (c.x - dx).abs() < 120.0 && (c.y - dy).abs() < 120.0 {
                let probes: Vec<String> = [0.15f32, 0.5, 0.85].iter().map(|&s| {
                    let q = a + (b - a) * s + flat_out;
                    format!("{:?}", floors.below(q.x, q.y, top + 1.0).map(|(z, _)| z))
                }).collect();
                eprintln!("HIDDEN {:?} n {:.2},{:.2},{:.2} top {:.2} probes {} -> {}", t, n.x, n.y, n.z, top, probes.join(" "), if hidden { "removed" } else { "kept" });
            }
        }
        if hidden {
            removed += 1;
        } else {
            out.push(t);
            out_tags.push(g);
        }
    }
    (out, out_tags, removed)
    });
    let (mut out, mut out_tags, mut removed) = (Vec::with_capacity(items.len()), Vec::with_capacity(items.len()), 0);
    for (o, g, n) in parts {
        out.extend(o);
        out_tags.extend(g);
        removed += n;
    }
    (out, out_tags, removed)
}

/// Edges the engine would pair up (1 mm weld, reversed winding), for measuring.
pub fn unmatched_edges(tris: &[[Vec3; 3]]) -> (usize, usize) {
    let weld = |v: Vec3| {
        let s = crate::coords::to_skate(v.to_array());
        s.map(|x| (f64::from(x) * 1000.0).round() as i64)
    };
    let mut edges: HashMap<([i64; 3], [i64; 3]), u32> = HashMap::new();
    for t in tris {
        for i in 0..3 {
            *edges.entry((weld(t[i]), weld(t[(i + 1) % 3]))).or_insert(0) += 1;
        }
    }
    let total = edges.values().map(|&c| c as usize).sum();
    let unmatched = edges.iter().filter(|((a, b), _)| !edges.contains_key(&(*b, *a))).map(|(_, &c)| c as usize).sum();
    (unmatched, total)
}

/// Gently smooth a displacement's interior (keeping its border fixed so seams
/// with neighbours stay closed): Laplacian passes on the height grid.
pub fn smooth_grid(verts: &mut [Vec3], size: usize, passes: usize, strength: f32) {
    if size < 3 || verts.len() != size * size {
        return;
    }
    for _ in 0..passes {
        let old = verts.to_vec();
        for y in 1..size - 1 {
            for x in 1..size - 1 {
                let i = y * size + x;
                let avg = (old[i - 1] + old[i + 1] + old[i - size] + old[i + size]) * 0.25;
                verts[i] = old[i] + (avg - old[i]) * strength;
            }
        }
    }
}

/// Fewer triangles for a detailed mesh: merge vertices that fall in the same
/// small cube (the size doubles until the mesh fits `max` triangles), then drop
/// triangles that collapsed. Keeps the overall shape; used for visible meshes
/// of models that have no physics model.
pub fn simplify_mesh(tris: Vec<[Vec3; 3]>, max: usize) -> Vec<[Vec3; 3]> {
    if tris.len() <= max {
        return tris;
    }
    let mut cell = 0.5f32;
    loop {
        let key = |v: Vec3| ((v.x / cell).floor() as i64, (v.y / cell).floor() as i64, (v.z / cell).floor() as i64);
        // each cell's vertices merge into their average: it stays on the surface
        // (snapping to grid corners would turn a slope into a staircase)
        let mut sums: HashMap<(i64, i64, i64), (Vec3, f32)> = HashMap::new();
        for t in &tris {
            for &v in t {
                let e = sums.entry(key(v)).or_insert((Vec3::ZERO, 0.0));
                e.0 += v;
                e.1 += 1.0;
            }
        }
        let at = |v: Vec3| { let (s, n) = sums[&key(v)]; (key(v), s / n) };
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        for t in &tris {
            let (a, b, c) = (at(t[0]), at(t[1]), at(t[2]));
            if a.0 == b.0 || b.0 == c.0 || a.0 == c.0 {
                continue;
            }
            let mut k = [a.0, b.0, c.0];
            k.sort();
            if !seen.insert(k) {
                continue;
            }
            let n = (b.1 - a.1).cross(c.1 - a.1);
            let n0 = (t[1] - t[0]).cross(t[2] - t[0]);
            // drop slivers and anything that flipped round
            if n.length_squared() > 1e-6 && n.dot(n0) > 0.0 {
                out.push([a.1, b.1, c.1]);
            }
        }
        if out.len() <= max || cell > 32.0 {
            return out;
        }
        cell *= 2.0;
    }
}

/// Twice the resolution for a displacement grid (size x size, row-major):
/// new points inside come from a Catmull-Rom curve through their neighbours
/// (so creases soften, not just split); new points on the border are exact
/// midpoints, so seams with neighbouring surfaces stay closed.
pub fn refine_grid(verts: &[Vec3], size: usize) -> (Vec<Vec3>, usize) {
    if size < 2 || verts.len() != size * size {
        return (verts.to_vec(), size);
    }
    let n = size * 2 - 1;
    let mut out = vec![Vec3::ZERO; n * n];
    let at = |x: usize, y: usize| verts[y * size + x];
    // Catmull-Rom midpoint between p1 and p2 (p0, p3 the outer neighbours)
    let cr = |p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3| (p1 + p2) * 0.5625 - (p0 + p3) * 0.0625;
    for y in 0..size {
        for x in 0..size {
            out[(2 * y) * n + 2 * x] = at(x, y);
        }
    }
    // along the original rows
    for y in 0..size {
        for x in 0..size - 1 {
            let (p1, p2) = (at(x, y), at(x + 1, y));
            let border = y == 0 || y == size - 1;
            out[(2 * y) * n + 2 * x + 1] = if border {
                (p1 + p2) * 0.5
            } else {
                cr(at(x.saturating_sub(1), y), p1, p2, at((x + 2).min(size - 1), y))
            };
        }
    }
    // then along the columns of the half-filled grid
    for x in 0..n {
        for y in 0..size - 1 {
            let get = |yy: usize| out[(2 * yy) * n + x];
            let (p1, p2) = (get(y), get(y + 1));
            let border = x == 0 || x == n - 1;
            out[(2 * y + 1) * n + x] = if border {
                (p1 + p2) * 0.5
            } else {
                cr(get(y.saturating_sub(1)), p1, p2, get((y + 2).min(size - 1)))
            };
        }
    }
    (out, n)
}

/// The largest angle (degrees) between neighbouring triangles of a grid, and
/// the average upward-ness of its triangles (to tell ground from walls).
pub fn grid_roughness(verts: &[Vec3], size: usize) -> (f32, f32) {
    if size < 2 || verts.len() != size * size {
        return (0.0, 0.0);
    }
    let at = |x: usize, y: usize| verts[y * size + x];
    let mut normals = vec![Vec3::ZERO; (size - 1) * (size - 1)];
    let mut up = 0.0;
    for y in 0..size - 1 {
        for x in 0..size - 1 {
            let n = (at(x + 1, y) - at(x, y)).cross(at(x, y + 1) - at(x, y)).normalize_or_zero();
            let n = if n.z < 0.0 { -n } else { n };
            normals[y * (size - 1) + x] = n;
            up += n.z;
        }
    }
    let m = size - 1;
    let mut worst = 0.0f32;
    for y in 0..m {
        for x in 0..m {
            let a = normals[y * m + x];
            if x + 1 < m { worst = worst.max(a.dot(normals[y * m + x + 1]).clamp(-1.0, 1.0).acos()); }
            if y + 1 < m { worst = worst.max(a.dot(normals[(y + 1) * m + x]).clamp(-1.0, 1.0).acos()); }
        }
    }
    (worst.to_degrees(), up / (m * m) as f32)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cube(c: Vec3, h: f32) -> Vec<[Vec3; 3]> {
        let v = |x: f32, y: f32, z: f32| c + Vec3::new(x, y, z) * h;
        let q = [
            [v(-1., -1., 1.), v(1., -1., 1.), v(1., 1., 1.), v(-1., 1., 1.)],
            [v(-1., -1., -1.), v(-1., 1., -1.), v(1., 1., -1.), v(1., -1., -1.)],
            [v(1., -1., -1.), v(1., 1., -1.), v(1., 1., 1.), v(1., -1., 1.)],
            [v(-1., -1., -1.), v(-1., -1., 1.), v(-1., 1., 1.), v(-1., 1., -1.)],
            [v(-1., 1., -1.), v(-1., 1., 1.), v(1., 1., 1.), v(1., 1., -1.)],
            [v(-1., -1., -1.), v(1., -1., -1.), v(1., -1., 1.), v(-1., -1., 1.)],
        ];
        q.iter().flat_map(|f| [[f[0], f[1], f[2]], [f[0], f[2], f[3]]]).collect()
    }

    #[test]
    fn overlapping_pieces_lose_their_hidden_faces() {
        // two overlapping boxes (like two convex hulls of one ramp model)
        let a = cube(Vec3::ZERO, 10.0);
        let b = cube(Vec3::new(12.0, 0.0, 0.0), 10.0);
        let (kept, removed) = remove_buried_between(vec![a, b]);
        assert_eq!(removed, 4, "each box's face inside the other goes (2 triangles each)");
        assert_eq!(kept.len(), 20);
        // nothing that remains is entirely inside the other box (partly
        // exposed faces, like the tops spanning the overlap, correctly stay)
        let (pa, pb) = (convex_planes(&cube(Vec3::ZERO, 10.0)), convex_planes(&cube(Vec3::new(12.0, 0.0, 0.0), 10.0)));
        for t in &kept {
            assert!(!buried(t, |p| inside_convex(&pa, p) && inside_convex(&pb, p)), "no hidden face left");
        }
    }

    fn quad(a: Vec3, b: Vec3, c: Vec3, d: Vec3) -> [[Vec3; 3]; 2] {
        [[a, b, c], [a, c, d]]
    }

    #[test]
    fn small_steps_get_a_ramp_and_walls_do_not() {
        let v = Vec3::new;
        let mut world = Vec::new();
        // the ground, and a raised pad 2 units high (a mismatched brush / tiny lip)
        world.extend(quad(v(-200., -200., 0.), v(200., -200., 0.), v(200., 200., 0.), v(-200., 200., 0.)));
        world.extend(quad(v(-50., -50., 2.), v(50., -50., 2.), v(50., 50., 2.), v(-50., 50., 2.)));
        let ramps = step_ramps(&world, 0.25, 2.5);
        // a ramp on each of the pad's 4 sides (each side in several pieces now)
        let sides = [Vec3::X, -Vec3::X, Vec3::Y, -Vec3::Y];
        for side in sides {
            assert!(ramps.iter().any(|r| {
                let c = (r[0] + r[1] + r[2]) / 3.0;
                c.dot(side) > 50.0
            }), "a ramp on the {side:?} side");
        }
        for r in &ramps {
            let n = (r[1] - r[0]).cross(r[2] - r[0]).normalize();
            assert!(n.z > 0.9, "the ramps are shallow and face up");
            assert!(r.iter().all(|p| p.z >= -1e-4 && p.z <= 2.0 + 1e-4), "from the pad's edge down to the ground");
        }
        // a 20-unit block is a wall, not a step: no ramp
        let mut walls = Vec::new();
        walls.extend(quad(v(-200., -200., 0.), v(200., -200., 0.), v(200., 200., 0.), v(-200., 200., 0.)));
        walls.extend(quad(v(-50., -50., 20.), v(50., -50., 20.), v(50., 50., 20.), v(-50., 50., 20.)));
        assert!(step_ramps(&walls, 0.25, 6.0).is_empty(), "tall edges are left alone");
        // a step with a wall right behind it (no room to land) gets no ramp
        let mut boxed = Vec::new();
        boxed.extend(quad(v(-60., -60., 0.), v(60., -60., 0.), v(60., 60., 0.), v(-60., 60., 0.)));
        boxed.extend(quad(v(-50., -50., 2.), v(50., -50., 2.), v(50., 50., 2.), v(-50., 50., 2.)));
        assert!(step_ramps(&boxed, 0.25, 2.5).is_empty(), "no ramp where the lower ground ends");
    }

    /// How much the surface direction changes from one strip to the next, and
    /// whether the curve starts on the floor and ends on the slope.
    fn check_fillet(f: &[[Vec3; 3]], n_floor: Vec3, n_slope: Vec3) -> (f32, bool, bool) {
        let ns: Vec<Vec3> = f.iter().map(|t| (t[1] - t[0]).cross(t[2] - t[0]).normalize()).collect();
        // the turn between triangles that actually share an edge
        let key = |v: Vec3| v.to_array().map(|x| (x * 256.0).round() as i64);
        let mut by_edge: HashMap<([i64; 3], [i64; 3]), Vec<usize>> = HashMap::new();
        for (i, t) in f.iter().enumerate() {
            for e in 0..3 {
                let (a, b) = (key(t[e]), key(t[(e + 1) % 3]));
                by_edge.entry(if a < b { (a, b) } else { (b, a) }).or_default().push(i);
            }
        }
        let mut worst = 0.0f32;
        for faces in by_edge.values() {
            for (x, &i) in faces.iter().enumerate() {
                for &j in &faces[x + 1..] {
                    let a = ns[i].dot(ns[j]).clamp(-1.0, 1.0).acos().to_degrees();
                    if a > worst && std::env::var("SK8_FOLD").is_ok() {
                        eprintln!("FOLD {a:.2}: {:?} / {:?}", f[i].map(|p| (p * 10.0).round() / 10.0), f[j].map(|p| (p * 10.0).round() / 10.0));
                    }
                    worst = worst.max(a);
                }
            }
        }
        let starts = ns.iter().any(|n| n.dot(n_floor) > 0.99);
        let ends = ns.iter().any(|n| n.dot(n_slope) > 0.99);
        (worst, starts, ends)
    }

    #[test]
    fn kicker_on_the_floor_gets_a_curved_transition() {
        let v = Vec3::new;
        // floor, and a 30 degree kicker face whose foot sits on it at x = 0
        let rise = 30f32.to_radians().tan();
        let mut world = Vec::new();
        world.extend(quad(v(-300., -100., 0.), v(300., -100., 0.), v(300., 100., 0.), v(-300., 100., 0.)));
        let slope = quad(v(0., -40., 0.), v(0., 40., 0.), v(60., 40., 60. * rise), v(60., -40., 60. * rise));
        let slope = slope.map(|t| { let n = (t[1] - t[0]).cross(t[2] - t[0]); if n.z < 0.0 { [t[0], t[2], t[1]] } else { t } });
        world.extend(slope);
        let ground = Heights::new(&world);
        let f = transition_fillets(&slope, &ground, 16.0);
        assert!(!f.is_empty(), "a transition is added at the kicker's foot");
        let n_slope = (slope[0][1] - slope[0][0]).cross(slope[0][2] - slope[0][0]).normalize();
        let (worst, starts, ends) = check_fillet(&f, Vec3::Z, n_slope);
        // (1.5 degrees per strip across the curve; up to ~5 between neighbours
        // where its size tapers towards the crease's ends, which twists the
        // strips a little - still gentle next to the 30 degree crease)
        assert!(worst <= 5.0, "no strip turns more than 5 degrees (was a 30 degree crease), got {worst}");
        assert!(starts && ends, "tangent to the floor at one end and the slope at the other");
        // it lies on or above both surfaces (it's added in the air, not buried)
        for t in &f {
            for p in t {
                assert!(p.z >= -1e-3, "above the floor");
                if p.x > 0.0 {
                    assert!(p.z >= p.x * rise - 1e-2, "on or above the slope");
                }
            }
        }
    }

    #[test]
    fn faceted_quarter_pipe_creases_are_rounded_and_walls_are_not() {
        let v = Vec3::new;
        // two facets meeting in a 20 degree crease (sharing the edge x = 50)
        let a = [v(0., -40., 0.), v(50., -40., 50. * 10f32.to_radians().tan()), v(50., 40., 50. * 10f32.to_radians().tan())];
        let b = [v(0., -40., 0.), v(50., 40., 50. * 10f32.to_radians().tan()), v(0., 40., 0.)];
        let z1 = 50. * 10f32.to_radians().tan();
        let c = [v(50., -40., z1), v(100., -40., z1 + 50. * 30f32.to_radians().tan()), v(100., 40., z1 + 50. * 30f32.to_radians().tan())];
        let d = [v(50., -40., z1), v(100., 40., z1 + 50. * 30f32.to_radians().tan()), v(50., 40., z1)];
        let tris = vec![a, b, c, d];
        let ground = Heights::new(&tris);
        let f = transition_fillets(&tris, &ground, 16.0);
        assert!(!f.is_empty(), "the crease between facets is rounded");
        // a floor meeting a vertical wall is not a ramp: nothing added
        let wall = vec![[v(0., -40., 0.), v(0., 40., 0.), v(0., 40., 100.)], [v(0., -40., 0.), v(0., 40., 100.), v(0., -40., 100.)]];
        let mut w = Vec::new();
        w.extend(quad(v(-300., -100., 0.), v(300., -100., 0.), v(300., 100., 0.), v(-300., 100., 0.)));
        w.extend(wall.clone());
        let g2 = Heights::new(&w);
        assert!(transition_fillets(&wall, &g2, 16.0).is_empty(), "walls stay walls");
    }

    #[test]
    fn a_faceted_quarter_pipe_becomes_one_smooth_curve() {
        let v = Vec3::new;
        // 10 facets, 12 units wide each, turning 4 degrees at every join
        // (below the old 6 degree threshold: these used to stay as creases)
        let mut tris = Vec::new();
        let (mut x, mut z, mut ang) = (0.0f32, 0.0f32, 0.0f32);
        for _ in 0..10 {
            let (nx, nz) = (x + 12.0 * ang.to_radians().cos(), z + 12.0 * ang.to_radians().sin());
            let q = [v(x, -40., z), v(nx, -40., nz), v(nx, 40., nz), v(x, 40., z)];
            for t in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]] {
                let n = (t[1] - t[0]).cross(t[2] - t[0]);
                tris.push(if n.z < 0.0 { [t[0], t[2], t[1]] } else { t });
            }
            x = nx; z = nz; ang += 4.0;
        }
        let ground = Heights::new(&tris);
        let mut st = FilletStats::default();
        let f = transition_fillets_with(&tris, None, &ground, 16.0, 5.0, &mut st);
        assert_eq!(st.creases, 9, "the nine joins are creases");
        assert_eq!(st.rounded, 9, "all of them get a curve");
        // along the pipe (a cross-section at y = 0), the steepest surface change
        // between consecutive pieces is now well under the 4 degree joins
        let mut pieces: Vec<(f32, f32)> = tris.iter().chain(f.iter()).filter_map(|t| {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            let c = (t[0] + t[1] + t[2]) / 3.0;
            (n.z > 0.0).then(|| (c.x, (-n.x).atan2(n.z).to_degrees()))
        }).collect();
        pieces.sort_by(|a, b| a.0.total_cmp(&b.0));
        // for each x, the surface the wheel sees is the highest one; sample it
        let top_slope = |x: f32| -> f32 {
            let mut best: Option<(f32, f32)> = None;
            for t in tris.iter().chain(f.iter()) {
                let (lo, hi) = (t.iter().map(|p| p.x).fold(f32::MAX, f32::min), t.iter().map(|p| p.x).fold(f32::MIN, f32::max));
                if x < lo || x > hi { continue; }
                if let Some((z, _)) = Heights::new(std::slice::from_ref(t)).below(x, 0.0, 1e6) {
                    let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
                    if best.map_or(true, |(bz, _)| z > bz) { best = Some((z, (-n.x).atan2(n.z).to_degrees())); }
                }
            }
            best.map_or(0.0, |b| b.1)
        };
        let mut worst_jump = 0.0f32;
        let mut prev = top_slope(1.0);
        let mut xs = 1.0;
        while xs < 110.0 {
            let s = top_slope(xs);
            worst_jump = worst_jump.max((s - prev).abs());
            prev = s;
            xs += 0.5;
        }
        eprintln!("PIPE: worst sudden change along the pipe = {worst_jump:.2} degrees (joins were 4)");
        assert!(worst_jump < 1.3, "no sudden change left bigger than a fraction of a join (was 4 degrees), got {worst_jump}");
        let _ = pieces;
    }

    #[test]
    fn refining_a_curved_grid_softens_creases_and_keeps_borders() {
        // a 5x5 grid bent into a bump
        let size = 5;
        let g: Vec<Vec3> = (0..size * size).map(|i| {
            let (x, y) = ((i % size) as f32, (i / size) as f32);
            Vec3::new(x * 16.0, y * 16.0, 10.0 * (-(x - 2.0).powi(2) / 2.0).exp())
        }).collect();
        let (fine, n) = refine_grid(&g, size);
        assert_eq!(n, 9);
        // the interior (away from the border rows, which only get midpoints so
        // seams stay closed): the sharpest crease along the middle cross-section
        let crease = |pts: &[Vec3]| pts.windows(3).map(|w| {
            let (a, b) = ((w[1] - w[0]).normalize(), (w[2] - w[1]).normalize());
            a.dot(b).clamp(-1.0, 1.0).acos().to_degrees()
        }).fold(0.0f32, f32::max);
        let before: Vec<Vec3> = (0..size).map(|x| g[2 * size + x]).collect();
        let after: Vec<Vec3> = (0..n).map(|x| fine[4 * n + x]).collect();
        let (b, a) = (crease(&before), crease(&after));
        eprintln!("GRID: sharpest crease across the bump {b:.1} -> {a:.1} degrees");
        assert!(a < b * 0.8, "creases softer after refining: {b:.1} -> {a:.1} degrees");
        // the original points are all still there, and the border is straight midpoints
        for y in 0..size { for x in 0..size { assert_eq!(fine[(2 * y) * n + 2 * x], g[y * size + x]); } }
        for x in 0..size - 1 {
            assert_eq!(fine[2 * x + 1], (g[x] + g[x + 1]) * 0.5, "border midpoints exact (seams stay closed)");
        }
    }

    #[test]
    fn diagnosis_says_what_happened_at_a_surface() {
        // a world floor box; its top face at z = 0
        let w = WorldSolid::from_boxes(&[(Vec3::new(-100., -100., -32.), Vec3::new(100., 100., 0.))]);
        let lines = w.diagnose(Vec3::new(10., 10., 0.), Vec3::Z, false);
        assert_eq!(lines.len(), 1);
        assert!(lines[0].contains("brush 0") && lines[0].contains("the world") && lines[0].contains("kept"), "{}", lines[0]);
        assert!(lines[0].contains("has a surface here: no"));
        // nothing there
        let air = w.diagnose(Vec3::new(10., 10., 500.), Vec3::Z, false);
        assert!(air[0].contains("no brush at this spot"));
    }

    #[test]
    fn detailed_meshes_are_simplified_but_keep_their_shape() {
        // a finely tessellated 100 x 100 slope: 20,000 triangles
        let mut tris = Vec::new();
        for i in 0..100 {
            for j in 0..100 {
                let p = |x: f32, y: f32| Vec3::new(x, y, x * 0.5);
                let (x, y) = (i as f32, j as f32);
                tris.push([p(x, y), p(x + 1., y), p(x + 1., y + 1.)]);
                tris.push([p(x, y), p(x + 1., y + 1.), p(x, y + 1.)]);
            }
        }
        let out = simplify_mesh(tris, 8000);
        assert!(out.len() <= 8000 && out.len() > 1000, "fits the budget: {}", out.len());
        for t in &out {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            assert!(n.z > 0.85, "still the same slope, facing the same way");
            for v in t { assert!((v.z - v.x * 0.5).abs() < 1.5, "on (or next to) the original surface"); }
        }
    }

    /// A 7 degree first facet (like the ramp in the trace) meeting a floor at
    /// z = 0, with its bottom edge at `edge_z`.
    fn gentle_ramp_foot(edge_z: f32) -> (Vec<[Vec3; 3]>, Vec<[Vec3; 3]>, FilletStats) {
        let v = Vec3::new;
        let rise = 7f32.to_radians().tan();
        let mut world = Vec::new();
        world.extend(quad(v(-300., -100., 0.), v(0., -100., 0.), v(0., 100., 0.), v(-300., 100., 0.)));
        // the floor carries on under the ramp too (as terrain does)
        world.extend(quad(v(0., -100., 0.), v(300., -100., 0.), v(300., 100., 0.), v(0., 100., 0.)));
        let slope = quad(v(0., -40., edge_z), v(0., 40., edge_z), v(80., 40., edge_z + 80. * rise), v(80., -40., edge_z + 80. * rise))
            .map(|t| { let n = (t[1] - t[0]).cross(t[2] - t[0]); if n.z < 0.0 { [t[0], t[2], t[1]] } else { t } });
        world.extend(slope);
        let ground = Heights::new(&world);
        let mut st = FilletStats::default();
        let f = transition_fillets_with(&slope, None, &ground, 16.0, 5.0, &mut st);
        (slope.to_vec(), f, st)
    }

    #[test]
    fn a_ramp_edge_standing_above_the_floor_gets_a_ramp_up_onto_it() {
        let (_, f, st) = gentle_ramp_foot(1.5); // a 1.5 unit lip
        assert_eq!(st.lips, 1, "the ramp's bottom edge bridged");
        assert!(!f.is_empty());
        // it runs from the floor (z = 0) up to the lip (z = 1.5), gently, facing up
        let (lo, hi) = f.iter().flatten().fold((f32::MAX, f32::MIN), |(l, h), p| (l.min(p.z), h.max(p.z)));
        assert!(lo.abs() < 1e-3 && (hi - 1.5).abs() < 1e-3, "floor to lip: {lo}..{hi}");
        for t in &f {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            assert!(n.z > 0.98, "a gentle ramp, facing up");
        }
    }

    #[test]
    fn a_buried_ramp_edge_gets_its_curve_where_the_slope_leaves_the_floor() {
        // the edge 1.2 units below the floor: the slope comes out at x = 1.2 / tan 7deg ~ 9.8
        let (_, f, st) = gentle_ramp_foot(-1.2);
        assert!(st.feet >= 1 && !f.is_empty(), "a curve was made");
        let out_x = 1.2 / 7f32.to_radians().tan();
        let xs: Vec<f32> = f.iter().flatten().map(|p| p.x).collect();
        let (lo, hi) = (xs.iter().copied().fold(f32::MAX, f32::min), xs.iter().copied().fold(f32::MIN, f32::max));
        assert!(lo < out_x && hi > out_x, "the curve spans where the slope leaves the floor: {lo}..{hi} around {out_x}");
        assert!(f.iter().flatten().all(|p| p.z >= -1e-3), "and sits on or above the floor");
    }

    #[test]
    fn a_gentle_first_facet_meeting_the_floor_gets_a_curve() {
        // 7 degrees used to be ignored entirely (the rule started at 10)
        let (_, f, st) = gentle_ramp_foot(0.0);
        assert!(st.feet >= 1 && !f.is_empty());
    }

    #[test]
    fn a_real_curb_stays_but_a_buried_front_goes() {
        let v = Vec3::new;
        // street at 0, sidewalk at 6: the curb's face (facing the street) is real
        let mut tris = Vec::new();
        tris.extend(quad(v(-100., -100., 0.), v(0., -100., 0.), v(0., 100., 0.), v(-100., 100., 0.)));  // street
        tris.extend(quad(v(0., -100., 6.), v(100., -100., 6.), v(100., 100., 6.), v(0., 100., 6.)));     // sidewalk
        let curb = [v(0., -100., 0.), v(0., 100., 6.), v(0., 100., 0.)];                                 // facing -x
        let curb = if (curb[1] - curb[0]).cross(curb[2] - curb[0]).x < 0.0 { curb } else { [curb[0], curb[2], curb[1]] };
        tris.push(curb);
        let n = tris.len();
        let (kept, _, removed) = remove_hidden_under_floor(tris.clone(), vec![0; n]);
        assert_eq!(removed, 0, "a real curb (lower ground in front) stays");
        assert_eq!(kept.len(), n);
        // the same face with the floor in front at the curb's height (a buried
        // front, flush with terrain) goes
        let mut buried = tris;
        buried.extend(quad(v(-100., -100., 6.), v(0., -100., 6.), v(0., 100., 6.), v(-100., 100., 6.)));
        let m = buried.len();
        let (_, _, removed) = remove_hidden_under_floor(buried, vec![0; m]);
        assert_eq!(removed, 1, "hidden under a floor at its top edge: removed");
    }

    #[test]
    fn a_kicker_ending_short_of_a_platform_gets_bridged_but_stairs_dont() {
        let v = Vec3::new;
        let rise = 15f32.to_radians().tan();
        // a platform at z = 20 (x > 0); a 15 degree kicker climbing towards it
        // from x = -60 and stopping 5 units short of the platform's height
        let mut tris = Vec::new();
        tris.extend(quad(v(0., -50., 20.), v(100., -50., 20.), v(100., 50., 20.), v(0., 50., 20.)));
        let kz = |x: f32| 15.0 + x * rise; // 15 at the platform's edge (x = 0)
        tris.extend(quad(v(-60., -40., kz(-60.)), v(0., -40., kz(0.)), v(0., 40., kz(0.)), v(-60., 40., kz(-60.)))
            .map(|t| { let n = (t[1] - t[0]).cross(t[2] - t[0]); if n.z < 0.0 { [t[0], t[2], t[1]] } else { t } }));
        let ramps = step_ramps(&tris, 0.05, 8.0);
        assert!(!ramps.is_empty(), "the 5 unit curb onto the platform is bridged");
        for r in &ramps {
            let n = (r[1] - r[0]).cross(r[2] - r[0]).normalize();
            assert!(n.z > 0.9, "a ramp you can ride, facing up");
            for p in r {
                assert!(p.z <= 20.0 + 1e-3 && p.z >= kz(p.x.min(0.0)) - 1e-2, "from the platform's edge down onto the kicker, not below it");
            }
        }
        // stairs: 8 unit risers every 12 units going down away from a landing
        let mut stairs = Vec::new();
        stairs.extend(quad(v(0., -50., 40.), v(50., -50., 40.), v(50., 50., 40.), v(0., 50., 40.)));
        for k in 1..6 {
            let (x0, x1, z) = (-(k as f32) * 12.0, -(k as f32 - 1.0) * 12.0, 40.0 - k as f32 * 8.0);
            stairs.extend(quad(v(x0, -50., z), v(x1, -50., z), v(x1, 50., z), v(x0, 50., z)));
        }
        assert!(step_ramps(&stairs, 0.05, 8.0).is_empty(), "a flight of stairs stays stairs");
    }

    #[test]
    fn level_cracks_are_bridged_but_real_gaps_and_walls_are_not() {
        let v = Vec3::new;
        let slabs = |gap: f32| {
            let mut t = Vec::new();
            t.extend(quad(v(-100., -50., 0.), v(0., -50., 0.), v(0., 50., 0.), v(-100., 50., 0.)));
            t.extend(quad(v(gap, -50., 0.), v(gap + 100., -50., 0.), v(gap + 100., 50., 0.), v(gap, 50., 0.)));
            t.extend(quad(v(-200., -200., -60.), v(300., -200., -60.), v(300., 200., -60.), v(-200., 200., -60.))); // far below
            t
        };
        // a level piece reaching from one slab's edge over to the other
        let across = |r: &Vec<[Vec3; 3]>, gap: f32| r.iter().any(|t| {
            let (lo, hi) = (t.iter().map(|p| p.x).fold(f32::MAX, f32::min), t.iter().map(|p| p.x).fold(f32::MIN, f32::max));
            lo <= 0.05 && hi >= gap - 0.05 && t.iter().all(|p| p.z.abs() < 0.05)
        });
        let r = step_ramps(&slabs(3.0), 0.05, 8.0);
        assert!(across(&r, 3.0), "a 3 unit crack between level slabs is bridged");
        for t in &r {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            assert!(n.z > 0.99, "level, facing up");
        }
        let r = step_ramps(&slabs(12.0), 0.05, 8.0);
        assert!(!across(&r, 12.0), "a 12 unit gap is a real gap: not bridged");
        // a floor meeting a thick wall: nothing on the other side to bridge to
        let mut room = Vec::new();
        room.extend(quad(v(-100., -50., 0.), v(0., -50., 0.), v(0., 50., 0.), v(-100., 50., 0.)));
        room.extend(quad(v(0., -50., 0.), v(0., 50., 0.), v(0., 50., 100.), v(0., -50., 100.)));
        room.extend(quad(v(0., -50., 100.), v(0., 50., 100.), v(30., 50., 100.), v(30., -50., 100.)));
        assert!(step_ramps(&room, 0.05, 8.0).is_empty(), "a floor against a wall gets nothing");
    }

    #[test]
    fn a_floor_mostly_under_a_box_keeps_the_strip_beside_it() {
        let v = Vec3::new;
        // floor top at z 0; a box stands on all of it but a 64-unit strip (y < 64)
        let solid = |p: Vec3| p.z < 0.0 || (p.y >= 64.0 && p.z < 64.0 && (0.0..=1024.0).contains(&p.x));
        let floor = [v(0., 0., 0.), v(1024., 0., 0.), v(1024., 1024., 0.)];
        assert!(buried_with(&floor, solid, false), "four samples near the middle miss the strip (why dense exists)");
        assert!(!buried_with(&floor, solid, true), "dense: the uncovered strip is visible, so the face stays");
        let hidden = [v(0., 100., 0.), v(1024., 100., 0.), v(1024., 1024., 0.)];
        assert!(buried_with(&hidden, solid, true), "a face fully under the box still goes");
    }

    #[test]
    fn both_halves_of_a_wall_get_the_same_verdict() {
        let v = Vec3::new;
        // a wall 8 high facing -x, y 0..100; in front of it a same-height
        // platform only beside its far end (y 95..200), plain ground elsewhere
        let (a, b, c, d) = (v(0., 0., 0.), v(0., 100., 0.), v(0., 100., 8.), v(0., 0., 8.));
        let mut world = vec![[a, c, b], [a, d, c]];
        world.extend(quad(v(-50., 95., 8.), v(0., 95., 8.), v(0., 200., 8.), v(-50., 200., 8.)));
        world.extend(quad(v(-50., 0., 0.), v(0., 0., 0.), v(0., 95., 0.), v(-50., 95., 0.)));
        let n = world.len();
        let (_, _, before) = remove_hidden_under_floor_with(world.clone(), vec![0; n], false);
        assert_eq!(before, 1, "probing only the single top corner drops the lower half (why full width exists)");
        let (out, _, removed) = remove_hidden_under_floor_with(world, vec![0; n], true);
        assert_eq!(removed, 0, "full width: the wall shows over most of its width, neither half is hidden");
        assert_eq!(out.len(), n);
    }

    #[test]
    fn a_trench_at_a_floors_edge_is_bridged_level_and_is_no_rail() {
        let v = Vec3::new;
        // a floor ending at x = 0; past it terrain starting 4 units lower and
        // climbing back above the floor within 12 units (and far below, more floor)
        let world = |rises: bool| {
            let mut t = Vec::new();
            t.extend(quad(v(-100., -50., 0.), v(0., -50., 0.), v(0., 50., 0.), v(-100., 50., 0.)));
            let far = if rises { 4.0 } else { -4.0 };
            t.extend(quad(v(0., -50., -4.), v(24., -50., far), v(24., 50., far), v(0., 50., -4.)));
            t.extend(quad(v(-200., -200., -60.), v(300., -200., -60.), v(300., 200., -60.), v(-200., 200., -60.)));
            t
        };
        let trench = world(true);
        let r = step_ramps(&trench, 0.05, 8.0);
        let level_to = |r: &Vec<[Vec3; 3]>| r.iter().filter(|t| t.iter().all(|p| p.z.abs() < 0.05)).map(|t| t.iter().map(|p| p.x).fold(f32::MIN, f32::max)).fold(0.0f32, f32::max);
        let reach = level_to(&r);
        assert!((11.0..13.0).contains(&reach), "bridged level out to where the terrain is back at floor height (12 units): {reach}");
        let heights = Heights::new(&trench);
        // (the floor's edge itself: the terrain's own low edge, tucked under it
        // in this hollow test world, is another matter)
        let at_edge = |rails: Vec<Vec<Vec3>>| rails.iter().any(|r| r.iter().all(|p| p.x.abs() < 0.5 && p.z.abs() < 0.5));
        assert!(at_edge(crate::rails::find(&trench).0), "the floor's edge looks like a lip to the rail finder on its own");
        assert!(!at_edge(crate::rails::find_with(&trench, Some(&heights)).0), "but a trench's edge is no rail");
        // lower ground that doesn't climb back: a real step down, ramped down to it
        let step = world(false);
        let r = step_ramps(&step, 0.05, 8.0);
        assert!(level_to(&r) < 0.5 && r.iter().any(|t| t.iter().any(|p| p.z < -3.0)), "a real step gets a ramp down, not a bridge");
        let heights = Heights::new(&step);
        assert!(at_edge(crate::rails::find_with(&step, Some(&heights)).0), "and its edge stays a rail");
    }

    #[test]
    fn t_junction_is_split() {
        // a big floor triangle whose edge has a vertex of a neighbouring (smaller) one on it
        let big = [Vec3::new(0., 0., 0.), Vec3::new(100., 0., 0.), Vec3::new(0., 100., 0.)];
        let small = [Vec3::new(50., 0., 0.), Vec3::new(100., 0., 0.), Vec3::new(75., -20., 0.)];
        let (out, _, split) = fix_t_junctions(vec![big, small], vec![0, 0], 0.05);
        assert_eq!(split, 1);
        assert!(out.iter().any(|t| t.contains(&Vec3::new(50., 0., 0.)) && t.contains(&Vec3::new(0., 0., 0.))),
            "the big triangle now has a vertex at the junction");
        let area = |t: &[Vec3; 3]| (t[1] - t[0]).cross(t[2] - t[0]).length() / 2.0;
        let total: f32 = out.iter().map(area).sum();
        assert!((total - (area(&big) + area(&small))).abs() < 1e-2, "splitting keeps the surface area");
    }

    #[test]
    fn smoothing_keeps_borders_and_flattens_bumps() {
        let size = 5;
        let mut g: Vec<Vec3> = (0..size * size).map(|i| Vec3::new((i % size) as f32, (i / size) as f32, 0.0)).collect();
        g[12].z = 10.0; // a spike in the middle
        let border: Vec<Vec3> = g.iter().enumerate().filter(|(i, _)| i % size == 0 || i / size == 0 || i % size == size - 1 || i / size == size - 1).map(|(_, v)| *v).collect();
        smooth_grid(&mut g, size, 2, 0.5);
        assert!(g[12].z < 5.0, "the spike is smoothed");
        let after: Vec<Vec3> = g.iter().enumerate().filter(|(i, _)| i % size == 0 || i / size == 0 || i % size == size - 1 || i / size == size - 1).map(|(_, v)| *v).collect();
        assert_eq!(border, after, "the border is untouched, so seams stay closed");
    }
}

#[cfg(test)]
mod lip_probe {
    use super::*;
    /// Why terrain points aren't averaged any more: on a curved terrain ramp
    /// (a quarter-pipe profile) with its edge held in place, averaging lifts
    /// the inside and leaves a crease at the edge.
    #[test]
    fn averaging_a_curved_ramp_made_a_lip_at_its_edge() {
        let size = 9;
        let g: Vec<Vec3> = (0..size * size).map(|i| {
            let (x, y) = ((i % size) as f32, (i / size) as f32);
            Vec3::new(x * 16.0, y * 16.0, 2.0 * x * x) // concave: rising faster and faster
        }).collect();
        // the ramp's foot: where its fixed edge meets the flat floor outside it
        // (the floor carries on level; the ramp's first stretch rises from it)
        let kink_with_floor = |g: &[Vec3]| {
            let row = 4;
            let d = (g[row * size + 1] - g[row * size]).normalize();
            d.z.asin().to_degrees()
        };
        let before = kink_with_floor(&g);
        let mut light = g.clone();
        smooth_grid(&mut light, size, 1, 0.5);
        let mut strong = g.clone();
        smooth_grid(&mut strong, size, 3, 0.6);
        let (l, s) = (kink_with_floor(&light), kink_with_floor(&strong));
        eprintln!("LIP: kink where the ramp meets the floor: as built {before:.1} deg, old light {l:.1} deg, old strong {s:.1} deg");
        assert!(l > before && s > l, "averaging made the foot kink sharper, and stronger was worse");
    }
}

/// The real geometry from a trace on tl_skatepark: the collision around the
/// board where it stopped dead at a ramp's foot (4.52 s in the user's run).
#[cfg(test)]
mod covered_risers_tests {
    use super::*;

    // a wall's foot cut into a sliver whose single top corner stands where the
    // ground in front rises (a ramp beside it): judged at that corner alone it
    // looked buried; along its sloped top it's in the open
    #[test]
    fn a_walls_foot_sliver_isnt_buried_by_ground_rising_at_one_corner() {
        let v = Vec3::new;
        let quad = |a: Vec3, b: Vec3, c: Vec3, d: Vec3| [[a, b, c], [a, c, d]];
        let mut t = Vec::new();
        // floor at 64 in front of the wall (y > -788), up to x = 200
        t.extend(quad(v(0., -788., 64.), v(200., -788., 64.), v(200., -500., 64.), v(0., -500., 64.)));
        // a ramp from x = 200 rising past the sliver's top corner (z 90.9 at x = 256)
        t.extend(quad(v(200., -788., 64.), v(280., -788., 102.4), v(280., -500., 102.4), v(200., -500., 64.)));
        // the sliver along the wall's foot (facing +y), its top corner at x = 256, z = 90.67
        let sliver = [v(102., -788., 64.), v(64., -788., 64.), v(256., -788., 90.67)];
        t.push(sliver);
        let lone = t.clone();
        // the rest of the wall above it, up to 176
        t.push([v(64., -788., 64.), v(64., -788., 176.), v(256., -788., 90.67)]);
        t.push([v(256., -788., 90.67), v(64., -788., 176.), v(256., -788., 176.)]);
        let run = |scene: &Vec<[Vec3; 3]>, o: Option<&str>| {
            crate::cleanup::set_env("SK8_OFF", o);
            let (kept, _, _) = remove_hidden_under_floor(scene.clone(), vec![0; scene.len()]);
            crate::cleanup::set_env("SK8_OFF", None);
            kept.contains(&sliver)
        };
        assert!(!run(&t, Some("hiddenoutline")), "the old rule drops it");
        assert!(run(&t, None), "the foot of a taller wall stays");
        assert!(!run(&lone, None), "a face whose top is the wall's real top still goes");
    }

    // a slab's side (facing +y, top at 0) with floor in front at its top for
    // x 0-100 and a drop past that: only the open half stays (hiddenpartial)
    #[test]
    fn a_partly_covered_side_keeps_only_its_open_stretch() {
        let v = Vec3::new;
        let quad = |a: Vec3, b: Vec3, c: Vec3, d: Vec3| [[a, b, c], [a, c, d]];
        let mut t = Vec::new();
        t.extend(quad(v(0., 0., 0.), v(100., 0., 0.), v(100., 200., 0.), v(0., 200., 0.)));
        t.extend(quad(v(100., 0., -100.), v(200., 0., -100.), v(200., 200., -100.), v(100., 200., -100.)));
        let side = [[v(0., 0., -16.), v(200., 0., 0.), v(200., 0., -16.)], [v(0., 0., -16.), v(0., 0., 0.), v(200., 0., 0.)]];
        t.extend(side);
        let steep = |on: Option<&str>| {
            crate::cleanup::set_env("SK8_ON", on);
            let (kept, _, _) = remove_hidden_under_floor(t.clone(), vec![0; t.len()]);
            crate::cleanup::set_env("SK8_ON", None);
            kept.into_iter().filter(|f| (f[1] - f[0]).cross(f[2] - f[0]).normalize_or_zero().y > 0.9).collect::<Vec<_>>()
        };
        let before = steep(None);
        assert_eq!(before.len(), 2, "as before, the whole side stays");
        let after = steep(Some("hiddenpartial"));
        let xs: Vec<f32> = after.iter().flat_map(|f| f.iter().map(|p| p.x)).collect();
        assert!(!after.is_empty(), "the open stretch stays");
        assert!(xs.iter().all(|&x| x >= 96.0), "the covered stretch is gone: {xs:?}");
        let area: f32 = after.iter().map(|f| (f[1] - f[0]).cross(f[2] - f[0]).length() / 2.0).sum();
        assert!((area - 100.0 * 16.0).abs() < 8.0 * 16.0 + 1.0, "about half is left: {area}");
    }

    // a floor at 0 and a 40 x 40 x 10 block on it, flush or `lift` above it:
    // what's left of the block's bottom
    fn block_bottom_left(lift: f32) -> usize {
        let v = Vec3::new;
        let quad = |a: Vec3, b: Vec3, c: Vec3, d: Vec3| [[a, b, c], [a, c, d]];
        let mut t = Vec::new();
        t.extend(quad(v(-200.0, -200.0, 0.0), v(200.0, -200.0, 0.0), v(200.0, 200.0, 0.0), v(-200.0, 200.0, 0.0)));
        t.extend(quad(v(-20.0, -20.0, lift), v(-20.0, 20.0, lift), v(20.0, 20.0, lift), v(20.0, -20.0, lift)));
        t.extend(quad(v(-20.0, -20.0, lift + 10.0), v(20.0, -20.0, lift + 10.0), v(20.0, 20.0, lift + 10.0), v(-20.0, 20.0, lift + 10.0)));
        let low = low_undersides(&t, &Heights::new(&t), 3.0);
        (2..4).map(|i| match &low[i] { None => 1, Some(p) => p.len() }).sum()
    }

    #[test]
    fn a_bottom_lying_flush_on_the_floor_goes() {
        assert_eq!(block_bottom_left(0.0), 0, "flush on the floor");
        assert_eq!(block_bottom_left(1.4), 0, "just above it");
        assert_eq!(block_bottom_left(6.0), 2, "well above it: a real underside");
    }
    // a 0.5 step: floor at 0 for x < 0, at 0.5 for x > 0, the riser between
    fn step() -> Vec<[Vec3; 3]> {
        let v = Vec3::new;
        let quad = |a: Vec3, b: Vec3, c: Vec3, d: Vec3| [[a, b, c], [a, c, d]];
        let mut t = Vec::new();
        t.extend(quad(v(-200.0, -100.0, 0.0), v(0.0, -100.0, 0.0), v(0.0, 100.0, 0.0), v(-200.0, 100.0, 0.0)));
        t.extend(quad(v(0.0, -100.0, 0.5), v(200.0, -100.0, 0.5), v(200.0, 100.0, 0.5), v(0.0, 100.0, 0.5)));
        // (facing -x, out over the lower floor)
        t.extend(quad(v(0.0, -100.0, -2.0), v(0.0, -100.0, 0.5), v(0.0, 100.0, 0.5), v(0.0, 100.0, -2.0)));
        t
    }
    #[test]
    fn a_riser_under_a_ramp_goes_and_only_where_the_ramp_covers_it() {
        let t = step();
        // a ramp over half the edge only (y -100..0), running out to -x
        let spans = vec![(Vec3::new(0.0, -100.0, 0.5), Vec3::new(0.0, 0.0, 0.5), Vec3::new(-1.0, 0.0, 0.0))];
        let out = clip_covered_risers(&t, &spans);
        assert!(out[0].is_none() && out[2].is_none(), "floors untouched");
        let kept: Vec<_> = out[4..].iter().zip(&t[4..]).flat_map(|(c, orig)| c.clone().unwrap_or_else(|| vec![*orig])).collect();
        assert!(!kept.is_empty(), "the uncovered half of the riser stays");
        for k in &kept {
            for p in k {
                assert!(p.y >= -0.01, "nothing of the riser left where the ramp is: {p:?}");
            }
        }
    }
    #[test]
    fn faces_not_facing_the_ramp_stay() {
        let t = step();
        // a ramp running out to +x (the other side): the riser faces -x, so it stays
        let spans = vec![(Vec3::new(0.0, -100.0, 0.5), Vec3::new(0.0, 100.0, 0.5), Vec3::new(1.0, 0.0, 0.0))];
        assert!(clip_covered_risers(&t, &spans).iter().all(|c| c.is_none()));
    }
}

#[cfg(test)]
mod real_ramp_foot {
    use super::*;

    fn fixture() -> (Vec<[Vec3; 3]>, Vec<u8>) {
        let mut tris = Vec::new();
        let mut tags = Vec::new();
        for line in include_str!("testdata/tl_skatepark_ramp_foot.txt").lines() {
            let parts: Vec<&str> = line.split('|').map(str::trim).collect();
            if parts.len() != 4 || parts[0].starts_with("step ramp") {
                continue; // (what the old smoothing added isn't part of the map)
            }
            let p = |s: &str| {
                let v: Vec<f32> = s.split_whitespace().map(|x| x.parse().unwrap()).collect();
                Vec3::new(v[0], v[1], v[2])
            };
            tris.push([p(parts[1]), p(parts[2]), p(parts[3])]);
            tags.push(if parts[0] == "displacement" { 1 } else { 0 });
        }
        // The capture only holds what was within 48 units of the board; in the
        // map the terrain floor (z = 412) runs the whole length of the ramp's
        // foot (see the screenshot). Add that strip so the far end is as real.
        let (a, b) = (FOOT_A, FOOT_B);
        let back = -up_ramp() * 60.0;
        let q = [a + back - (b - a) * 0.1, b + back + (b - a) * 0.1, b + (b - a) * 0.1, a - (b - a) * 0.1];
        for t in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]] {
            let n = (t[1] - t[0]).cross(t[2] - t[0]);
            tris.push(if n.z < 0.0 { [t[0], t[2], t[1]] } else { t });
            tags.push(1);
        }
        (tris, tags)
    }

    // the ramp's foot line, and the way up it
    const FOOT_A: Vec3 = Vec3::new(-2413.72, -750.35, 412.0);
    const FOOT_B: Vec3 = Vec3::new(-2636.75, -973.37, 412.0);
    fn up_ramp() -> Vec3 { Vec3::new(0.7071, -0.7071, 0.0) }
    fn along_foot(p: Vec3) -> f32 { (p - FOOT_A).dot(up_ramp()) }

    fn steep(t: &[Vec3; 3]) -> bool { (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero().z.abs() < 0.7 }

    /// Steep faces the board meets at wheel height on its way from the floor
    /// up the first facets (the path in the trace: the middle of the ramp).
    fn obstacles_on_path(tris: &[[Vec3; 3]]) -> Vec<[Vec3; 3]> {
        tris.iter().filter(|t| {
            if !steep(t) { return false; }
            let c = (t[0] + t[1] + t[2]) / 3.0;
            let d = along_foot(c);
            // near the floor-to-ramp line or the first joints, below the surface there
            let surface_z = 412.0 + (d.max(0.0).min(48.0) * 0.125) + (d - 48.0).max(0.0) * 0.42;
            let top = t[0].z.max(t[1].z).max(t[2].z);
            (-2.0..60.0).contains(&d) && (top - surface_z).abs() < 1.5
        }).copied().collect()
    }

    fn run() -> (Vec<[Vec3; 3]>, Vec<[Vec3; 3]>, FilletStats, usize, usize, usize) {
        let (tris, tags) = fixture();
        let (w, wt, merged, dropped) = weld_and_dedupe(tris, tags, 0.15);
        let (h, ht, hidden) = remove_hidden_under_floor(w, wt);
        let (fixed, ftags, _) = fix_t_junctions(h, ht, 0.05);
        let ground = Heights::new(&fixed);
        let coarse: Vec<bool> = ftags.iter().map(|&g| g == 1).collect();
        let mut st = FilletStats::default();
        let fillets = transition_fillets_with(&fixed, Some(&coarse), &ground, 16.0, 5.0, &mut st);
        let _ = (merged, dropped);
        (fixed, fillets, st, merged, dropped, hidden)
    }

    #[test]
    fn the_real_ramp_foot_is_clean_after_the_fix() {
        let (before, _) = fixture();
        let obstacles_before = obstacles_on_path(&before);
        let (after, fillets, st, merged, dropped, hidden) = run();
        let obstacles_after = obstacles_on_path(&after);
        eprintln!("REAL: {} triangles; merged {merged} near-miss vertices, dropped {dropped} duplicates/slivers, removed {hidden} hidden faces", before.len());
        eprintln!("REAL: steep faces at wheel height on the way up: {} before, {} after", obstacles_before.len(), obstacles_after.len());
        eprintln!("REAL: creases found {}, rounded {}; curve triangles {}", st.creases, st.rounded, fillets.len());
        for t in &obstacles_after { eprintln!("REAL:   left: {:?}", t.map(|v| (v * 100.0).round() / 100.0)); }
        assert!(!obstacles_before.is_empty(), "the fixture does show the problem");
        assert!(obstacles_after.is_empty(), "nothing steep left at wheel height on the way up");
        // the 7 -> 23 degree joint (height 418) gets its curve
        let at_418 = fillets.iter().any(|t| t.iter().all(|p| (p.z - 418.0).abs() < 4.0 && (along_foot(*p) - 48.0).abs() < 12.0));
        assert!(at_418, "the joint at 418 is rounded");
    }
}

/// Big ramps at top speed: how hard a straight run through a megaramp-style
/// transition pulls on the rider (the force that turns into a bail).
#[cfg(test)]
pub(crate) mod megaramp {
    use super::*;

    /// A drop-in (30 degrees, 1200 units long), a flat bottom, and a run-up
    /// built of big flat facets turning 5 degrees at each crease up to 45
    /// degrees - how a mapper builds a huge transition from brushes.
    pub fn build() -> (Vec<[Vec3; 3]>, Vec<u8>) {
        let v = Vec3::new;
        let w = 200.0;
        let mut profile: Vec<(f32, f32)> = vec![(-1200.0 * 30f32.to_radians().cos(), 1200.0 * 30f32.to_radians().sin()), (0.0, 0.0), (300.0, 0.0)];
        let (mut x, mut z) = (300.0f32, 0.0f32);
        for k in 1..=9 {
            let a = (k as f32 * 5.0).to_radians();
            x += 96.0 * a.cos();
            z += 96.0 * a.sin();
            profile.push((x, z));
        }
        let mut tris = Vec::new();
        for p in profile.windows(2) {
            let (a, b) = (p[0], p[1]);
            let q = [v(a.0, -w, a.1), v(b.0, -w, b.1), v(b.0, w, b.1), v(a.0, w, a.1)];
            for t in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]] {
                let n = (t[1] - t[0]).cross(t[2] - t[0]);
                tris.push(if n.z < 0.0 { [t[0], t[2], t[1]] } else { t });
            }
        }
        let n = tris.len();
        (tris, vec![0; n])
    }

    /// Peak pull (in g) at `speed_mps` along the ramp's centre line: from the
    /// sharpest turn of the surface a wheel follows (sampled every half unit,
    /// taking the highest surface - with curves, that's the curve).
    pub fn peak_g(tris: &[[Vec3; 3]], speed_mps: f32) -> f32 {
        let h = Heights::new(tris);
        let mut pts = Vec::new();
        let mut x = -1000.0f32;
        while x < 1150.0 {
            if let Some((z, _)) = h.below(x, 0.0, 2000.0) {
                pts.push(Vec3::new(x, 0.0, z));
            }
            x += 0.5;
        }
        let mut worst = 0.0f32;
        // the turn over each 4-unit stretch (a wheelbase or so), as curvature
        let span = 8;
        for i in span..pts.len() - span {
            let (a, b, c) = (pts[i - span], pts[i], pts[i + span]);
            let (d1, d2) = ((b - a).normalize(), (c - b).normalize());
            let turn = d1.dot(d2).clamp(-1.0, 1.0).acos();
            let len_m = ((b - a).length() + (c - b).length()) * 0.5 * 0.0254;
            let kappa = turn / len_m; // 1 / metres
            let g = speed_mps * speed_mps * kappa / 9.81;
            if g > worst {
                worst = g;
                if std::env::var("SK8_WHERE").is_ok() { eprintln!("MEGA   peak so far {g:.1} g at x {:.1} z {:.1}", b.x, b.z); }
            }
        }
        worst
    }

    #[test]
    fn a_terrain_megaramp_gets_its_small_creases_rounded() {
        // the same run-up, as terrain with 3 degree creases (15 of them)
        let v = Vec3::new;
        let w = 200.0;
        let (mut x, mut z) = (0.0f32, 0.0f32);
        let mut profile = vec![(-600.0, 0.0), (0.0, 0.0)];
        for k in 1..=15 {
            let a = (k as f32 * 3.0).to_radians();
            x += 64.0 * a.cos();
            z += 64.0 * a.sin();
            profile.push((x, z));
        }
        let mut tris = Vec::new();
        for p in profile.windows(2) {
            let (a, b) = (p[0], p[1]);
            let q = [v(a.0, -w, a.1), v(b.0, -w, b.1), v(b.0, w, b.1), v(a.0, w, a.1)];
            for t in [[q[0], q[1], q[2]], [q[0], q[2], q[3]]] {
                let n = (t[1] - t[0]).cross(t[2] - t[0]);
                tris.push(if n.z < 0.0 { [t[0], t[2], t[1]] } else { t });
            }
        }
        let n = tris.len();
        let raw = peak_g(&tris, 20.0);
        let out = crate::pipeline::run(tris, vec![crate::world::TAG_DISPLACEMENT; n], &crate::world::Smoothing::preset(1));
        let smoothed = peak_g(&out.tris, 20.0);
        eprintln!("MEGA: terrain run-up (3 degree creases) at 20 m/s: as built {raw:.1} g, smoothed {smoothed:.1} g");
        assert!(smoothed < 6.0, "small creases on a big terrain ramp are rounded too: {smoothed:.1} g");
    }

    #[test]
    fn megaramp_transition_at_top_speed() {
        let (tris, tags) = build();
        let raw = peak_g(&tris, 20.0);
        let opts = crate::world::Smoothing::preset(1);
        let out = crate::pipeline::run(tris, tags, &opts);
        let smoothed = peak_g(&out.tris, 20.0);
        eprintln!("MEGA: peak pull at 20 m/s through the run-up: as built {raw:.1} g, smoothed {smoothed:.1} g");
        assert!(smoothed < 6.0, "a big ramp gets big, gentle transitions: {smoothed:.1} g at top speed");
    }
}

/// A real tiny overhang from tl_skatepark: a prop ramp made of two convex
/// pieces - a 16 degree face, and a 35 degree face whose bottom edge starts
/// 1.17 units back over it, hanging 0.33 units above the surface.
#[cfg(test)]
mod real_overhang {
    use super::*;

    #[test]
    fn a_prop_ramps_tiny_overhang_is_curved_over() {
        let v = Vec3::new;
        let tris = vec![
            [v(-3211.28, -1591.32, 502.72), v(-3067.26, -1843.3, 480.25), v(-3013.28, -1789.32, 502.72)],
            [v(-3211.28, -1591.32, 502.72), v(-3265.26, -1645.3, 480.25), v(-3067.26, -1843.3, 480.25)],
            [v(-3014.11, -1790.14, 502.72), v(-2970.98, -1747.02, 546.48), v(-3168.97, -1549.02, 546.48)],
            [v(-3212.1, -1592.15, 502.72), v(-3014.11, -1790.14, 502.72), v(-3168.97, -1549.02, 546.48)],
        ];
        let tris: Vec<[Vec3; 3]> = tris.into_iter().map(|t| if (t[1] - t[0]).cross(t[2] - t[0]).z < 0.0 { [t[0], t[2], t[1]] } else { t }).collect();
        // ride straight up the middle of the ramp, over the joint
        let profile = |all: &[[Vec3; 3]]| {
            let h = Heights::new(all);
            let (start, dir) = (v(-3166.0, -1717.0, 0.0), v(0.7071, 0.7071, 0.0));
            (0..160).filter_map(|k| { let p = start + dir * (k as f32 * 0.5); h.below(p.x, p.y, 600.0).map(|(z, nz)| (z, nz)) }).collect::<Vec<_>>()
        };
        let worst_lip = |pr: &[(f32, f32)]| pr.windows(2).map(|w| {
            let slope_rise = |nz: f32| 0.5 * nz.clamp(0.05, 1.0).acos().tan();
            (w[1].0 - w[0].0) - slope_rise(w[0].1).max(slope_rise(w[1].1))
        }).fold(0.0f32, f32::max);
        let before = worst_lip(&profile(&tris));
        let ground = Heights::new(&tris);
        let mut st = FilletStats::default();
        let curves = transition_fillets_with(&tris, None, &ground, 16.0, 5.0, &mut st);
        let mut all = tris.clone();
        all.extend(curves);
        let after = worst_lip(&profile(&all));
        eprintln!("OVERHANG: worst rise beyond the slope, riding up: {before:.2} units as built, {after:.2} after");
        assert!(before > 0.2, "the overhang is there to begin with");
        assert!(after < 0.1, "and it's curved over: {after:.2}");
    }
}
