//! Source engine <-> Skate 3 coordinates. Source (like MW2/IW4, both Quake
//! descendants) is inches with Z up; Skate is metres with Y up. These are the
//! same conversions the IW4L mashup uses (crates/render_anim/src/skate/collision.rs).

use std::sync::atomic::{AtomicU32, Ordering};

pub const INCH: f32 = 0.0254;

/// Metres per map unit the engine sees. True scale is one inch; a smaller value
/// makes the map smaller to the engine (lower, shorter ramps), which suits
/// Source maps built at generous player proportions. Set once per session.
static METRES_PER_UNIT: AtomicU32 = AtomicU32::new(0x3CD0_13A9); // 0.0254_f32

pub fn set_world_scale(scale: f32) {
    let s = if scale.is_finite() { scale.clamp(0.25, 2.0) } else { 1.0 };
    METRES_PER_UNIT.store((INCH * s).to_bits(), Ordering::Relaxed);
}

pub fn metres_per_unit() -> f32 {
    f32::from_bits(METRES_PER_UNIT.load(Ordering::Relaxed))
}

pub fn to_skate(p: [f32; 3]) -> [f32; 3] {
    let m = metres_per_unit();
    [p[0] * m, p[2] * m, -p[1] * m]
}

pub fn from_skate(p: [f32; 3]) -> [f32; 3] {
    let m = metres_per_unit();
    [p[0] / m, -p[2] / m, p[1] / m]
}

/// A direction (no scale): skate (x, y, z) -> source (x, -z, y).
pub fn dir_from_skate(v: [f32; 3]) -> [f32; 3] {
    [v[0], -v[2], v[1]]
}

/// Source view yaw (degrees) -> skate heading (radians), as the mashup passes it.
pub fn heading_from_yaw(yaw_deg: f32) -> f32 {
    yaw_deg.to_radians() + std::f32::consts::FRAC_PI_2
}

/// A flat square floor in skate space, `half` metres from the centre, at the
/// source point `centre`. Counter-clockwise faces with +Y normals, as Skate expects.
pub fn flat_floor(centre: [f32; 3], half: f32) -> Vec<[[f32; 3]; 3]> {
    let c = to_skate(centre);
    let (x, h, z) = (c[0], c[1], c[2]);
    let a = [x - half, h, z - half];
    let b = [x - half, h, z + half];
    let cc = [x + half, h, z + half];
    let d = [x + half, h, z - half];
    vec![[a, b, cc], [a, cc, d]]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn default_scale_is_one_inch() {
        assert_eq!(metres_per_unit(), INCH);
    }
    #[test]
    fn round_trip() {
        let p = [123.0, -456.0, 78.0];
        let q = from_skate(to_skate(p));
        for i in 0..3 {
            assert!((p[i] - q[i]).abs() < 1e-3);
        }
    }
    #[test]
    fn floor_faces_up() {
        for t in flat_floor([0.0, 0.0, 0.0], 10.0) {
            let u = [t[1][0] - t[0][0], t[1][1] - t[0][1], t[1][2] - t[0][2]];
            let v = [t[2][0] - t[0][0], t[2][1] - t[0][1], t[2][2] - t[0][2]];
            let ny = u[2] * v[0] - u[0] * v[2];
            assert!(ny > 0.0, "floor normal must point +Y");
        }
    }
}
