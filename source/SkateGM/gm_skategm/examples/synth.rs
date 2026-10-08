//! Synthetic lip scenes for the real-engine lip test (harness/lips.lua): small
//! steps, cracks, bumps, seams and overhangs built as a map would have them,
//! written raw and after the skateability pipeline (classic switches from the
//! environment), one Lua file per scene.
//!     cargo run --release --no-default-features --example synth -- <out dir>
use gmcl_skategm_win64::{pipeline, world::Smoothing};
use glam::Vec3;
use std::fmt::Write as _;

type Tri = [Vec3; 3];

fn quad(out: &mut Vec<Tri>, a: Vec3, b: Vec3, c: Vec3, d: Vec3) {
    out.push([a, b, c]);
    out.push([a, c, d]);
}

/// an axis-aligned box, outward-facing (as a brush's faces)
fn boxed(out: &mut Vec<Tri>, lo: Vec3, hi: Vec3) {
    let p = |x: f32, y: f32, z: f32| Vec3::new(x, y, z);
    let (x0, y0, z0, x1, y1, z1) = (lo.x, lo.y, lo.z, hi.x, hi.y, hi.z);
    quad(out, p(x0, y0, z1), p(x1, y0, z1), p(x1, y1, z1), p(x0, y1, z1)); // top
    quad(out, p(x0, y0, z0), p(x0, y1, z0), p(x1, y1, z0), p(x1, y0, z0)); // bottom
    quad(out, p(x1, y0, z0), p(x1, y1, z0), p(x1, y1, z1), p(x1, y0, z1)); // +x
    quad(out, p(x0, y0, z0), p(x0, y0, z1), p(x0, y1, z1), p(x0, y1, z0)); // -x
    quad(out, p(x0, y1, z0), p(x0, y1, z1), p(x1, y1, z1), p(x1, y1, z0)); // +y
    quad(out, p(x0, y0, z0), p(x1, y0, z0), p(x1, y0, z1), p(x0, y0, z1)); // -y
}

const L: f32 = 1024.0;
const W: f32 = 512.0;

fn scene(kind: &str, v: f32) -> Vec<Tri> {
    let mut t = Vec::new();
    let v3 = Vec3::new;
    match kind {
        // floor at 0 for x < 0, at v for x > 0 (a riser of height v at x = 0)
        "step" => {
            boxed(&mut t, v3(-L, -W, -16.0), v3(0.0, W, 0.0));
            boxed(&mut t, v3(0.0, -W, -16.0), v3(L, W, v));
        }
        // the same step as a BSP leaves it: the faces between the two touching
        // boxes (buried) taken out, the riser kept
        "stepbsp" => {
            let mut lower = Vec::new();
            boxed(&mut lower, v3(-L, -W, -16.0), v3(0.0, W, 0.0));
            let mut upper = Vec::new();
            boxed(&mut upper, v3(0.0, -W, -16.0), v3(L, W, v));
            let at_seam = |t: &Tri| t.iter().all(|p| p.x.abs() < 1e-3);
            // the lower box's +x face is all buried; the upper box's -x face only below 0
            t.extend(lower.into_iter().filter(|q| !at_seam(q)));
            for q in upper {
                if at_seam(&q) {
                    // split at z = 0: keep the part above (the riser)
                    quad(&mut t, v3(0.0, -W, 0.0), v3(0.0, -W, v), v3(0.0, W, v), v3(0.0, W, 0.0));
                    break;
                }
            }
            for q in { let mut u = Vec::new(); boxed(&mut u, v3(0.0, -W, -16.0), v3(L, W, v)); u } {
                if !at_seam(&q) { t.push(q); }
            }
        }
        // a slot v wide across the floor, 16 deep
        "crack" => {
            boxed(&mut t, v3(-L, -W, -16.0), v3(0.0, W, 0.0));
            boxed(&mut t, v3(v, -W, -16.0), v3(L, W, 0.0));
            boxed(&mut t, v3(-L, -W, -32.0), v3(L, W, -16.0));
        }
        // a strip 8 wide, v high, lying on the floor
        "bump" => {
            boxed(&mut t, v3(-L, -W, -16.0), v3(L, W, 0.0));
            boxed(&mut t, v3(0.0, -W, 0.0), v3(8.0, W, v));
        }
        // the floor ahead is v higher and sticks out 3 units over the lower
        // floor, as a 1-unit slab with a gap under it (a "tiny overhang")
        "overhang" => {
            boxed(&mut t, v3(-L, -W, -16.0), v3(0.0, W, 0.0));
            boxed(&mut t, v3(0.0, -W, -16.0), v3(L, W, v));
            boxed(&mut t, v3(-3.0, -W, v - 1.0), v3(0.0, W, v));
        }
        // one continuous surface: floor, a slope rising v over `run` units
        // (shared edges, as a mapper builds a ramp), upper floor; v encodes
        // the run as v + run / 1000 (0.516 = a 0.5 rise over 16)
        "slope" => {
            let rise = (v * 10.0).floor() / 10.0;
            let run = ((v - rise) * 1000.0).round().max(1.0);
            let top = [v3(-L, 0.0, 0.0), v3(-run, 0.0, 0.0), v3(0.0, 0.0, rise), v3(L, 0.0, rise)];
            for k in 0..3 {
                let (a, b) = (top[k], top[k + 1]);
                quad(&mut t, v3(a.x, -W, a.z), v3(b.x, -W, b.z), v3(b.x, W, b.z), v3(a.x, W, a.z));
            }
        }
        // the same slope, with the old floor still under it and the old riser
        // behind it (what an overlaid ledge ramp leaves); "slopefloor" the
        // floor only, "sloperiser" the riser only
        "slopeold" | "slopefloor" | "sloperiser" => {
            let rise = (v * 10.0).floor() / 10.0;
            let run = ((v - rise) * 1000.0).round().max(1.0);
            let top = [v3(-L, 0.0, 0.0), v3(-run, 0.0, 0.0), v3(0.0, 0.0, rise), v3(L, 0.0, rise)];
            for k in 0..3 {
                let (a, b) = (top[k], top[k + 1]);
                quad(&mut t, v3(a.x, -W, a.z), v3(b.x, -W, b.z), v3(b.x, W, b.z), v3(a.x, W, a.z));
            }
            if kind != "sloperiser" {
                quad(&mut t, v3(-run, -W, 0.0), v3(0.0, -W, 0.0), v3(0.0, W, 0.0), v3(-run, W, 0.0));
            }
            if kind != "slopefloor" {
                quad(&mut t, v3(0.0, -W, 0.0), v3(0.0, W, 0.0), v3(0.0, W, rise), v3(0.0, -W, rise));
            }
        }
        // the slope's bottom edge lying inside the floor's face (not on an edge
        // of it), its top edge shared ("slopeloose"); or both floors whole
        // and the slope cut into 8-unit strips across, like a ledge ramp
        // ("slopestrips": T-junctions at both its edges)
        "slopeloose" | "slopestrips" => {
            let rise = (v * 10.0).floor() / 10.0;
            let run = ((v - rise) * 1000.0).round().max(1.0);
            quad(&mut t, v3(-L, -W, 0.0), v3(0.0, -W, 0.0), v3(0.0, W, 0.0), v3(-L, W, 0.0));
            quad(&mut t, v3(0.0, -W, rise), v3(L, -W, rise), v3(L, W, rise), v3(0.0, W, rise));
            if kind == "slopeloose" {
                quad(&mut t, v3(-run, -W, 0.0), v3(0.0, -W, rise), v3(0.0, W, rise), v3(-run, W, 0.0));
            } else {
                let mut y = -W;
                while y < W {
                    quad(&mut t, v3(-run, y, 0.0), v3(0.0, y, rise), v3(0.0, y + 8.0, rise), v3(-run, y + 8.0, 0.0));
                    y += 8.0;
                }
            }
        }
        // a kicker with tl_skatepark's facets (17, then 35, then 45 degrees):
        // "kickermapper" one surface rising from the floor; "kickerprop" a
        // separate closed piece whose foot stands v above the floor (a prop
        // that isn't sunk in)
        "kickermapper" | "kickerprop" => {
            let lift = if kind == "kickerprop" { v } else { 0.0 };
            let (a17, a35, a45) = (17f32.to_radians().tan(), 35f32.to_radians().tan(), 45f32.to_radians().tan());
            let prof = [(0.0, 0.0), (40.0, 40.0 * a17), (55.0, 40.0 * a17 + 15.0 * a35), (65.0, 40.0 * a17 + 15.0 * a35 + 10.0 * a45)];
            if kind == "kickermapper" {
                let mut top = vec![v3(-L, 0.0, 0.0)];
                for (x, z) in prof { top.push(v3(x, 0.0, z)); }
                for k in 0..top.len() - 1 {
                    let (a, b) = (top[k], top[k + 1]);
                    quad(&mut t, v3(a.x, -W, a.z), v3(b.x, -W, b.z), v3(b.x, W, b.z), v3(a.x, W, a.z));
                }
            } else {
                boxed(&mut t, v3(-L, -W, -16.0), v3(L, W, 0.0));
                // the prop: its sloped faces lifted by `lift`, a front face at
                // its foot, a back and a bottom (closed)
                for k in 0..prof.len() - 1 {
                    let (a, b) = (prof[k], prof[k + 1]);
                    quad(&mut t, v3(a.0, -W, a.1 + lift), v3(b.0, -W, b.1 + lift), v3(b.0, W, b.1 + lift), v3(a.0, W, a.1 + lift));
                }
                let top = prof[3].1 + lift;
                quad(&mut t, v3(0.0, -W, 0.0), v3(0.0, -W, lift), v3(0.0, W, lift), v3(0.0, W, 0.0));
                quad(&mut t, v3(65.0, W, 0.0), v3(65.0, W, top), v3(65.0, -W, top), v3(65.0, -W, 0.0));
                quad(&mut t, v3(0.0, W, 0.0), v3(65.0, W, 0.0), v3(65.0, -W, 0.0), v3(0.0, -W, 0.0));
            }
        }
        // the same kicker 48 wide, with sides: "narrowmapper" as a BSP leaves
        // it (no bottom), "narrowprop" a closed prop sitting flush on the floor
        "narrowmapper" | "narrowprop" => {
            let (a17, a35, a45) = (17f32.to_radians().tan(), 35f32.to_radians().tan(), 45f32.to_radians().tan());
            let prof = [(0.0, 0.0), (40.0, 40.0 * a17), (55.0, 40.0 * a17 + 15.0 * a35), (65.0, 40.0 * a17 + 15.0 * a35 + 10.0 * a45)];
            let h = 24.0;
            boxed(&mut t, v3(-L, -W, -16.0), v3(L, W, 0.0));
            for k in 0..prof.len() - 1 {
                let (a, b) = (prof[k], prof[k + 1]);
                quad(&mut t, v3(a.0, -h, a.1), v3(b.0, -h, b.1), v3(b.0, h, b.1), v3(a.0, h, a.1));
                // the sides (facing -y and +y)
                t.push([v3(a.0, -h, 0.0), v3(b.0, -h, 0.0), v3(b.0, -h, b.1)]);
                if a.1 > 0.0 { t.push([v3(a.0, -h, 0.0), v3(b.0, -h, b.1), v3(a.0, -h, a.1)]); }
                t.push([v3(a.0, h, 0.0), v3(b.0, h, b.1), v3(b.0, h, 0.0)]);
                if a.1 > 0.0 { t.push([v3(a.0, h, 0.0), v3(a.0, h, a.1), v3(b.0, h, b.1)]); }
            }
            let top = prof[3].1;
            quad(&mut t, v3(65.0, h, 0.0), v3(65.0, h, top), v3(65.0, -h, top), v3(65.0, -h, 0.0));
            if kind == "narrowprop" {
                quad(&mut t, v3(0.0, h, 0.0), v3(65.0, h, 0.0), v3(65.0, -h, 0.0), v3(0.0, -h, 0.0));
            }
        }
        // two floors at the same height meeting at x = 0 without shared
        // vertices (the far one cut into strips v wide: T-junctions)
        "seam" => {
            boxed(&mut t, v3(-L, -W, -16.0), v3(0.0, W, 0.0));
            let mut y = -W;
            while y < W {
                let y1 = (y + v).min(W);
                boxed(&mut t, v3(0.0, y, -16.0), v3(L, y1, 0.0));
                y = y1;
            }
        }
        _ => {}
    }
    t
}

fn lua(tris: &[Tri]) -> String {
    let mut s = String::with_capacity(tris.len() * 60);
    s.push('{');
    for t in tris {
        for p in t {
            let _ = write!(s, "{:.3},{:.3},{:.3},", p.x, p.y, p.z);
        }
    }
    s.push('}');
    s
}

fn main() {
    let out = std::env::args().nth(1).expect("out dir");
    std::fs::create_dir_all(&out).unwrap();
    let opts = Smoothing::preset(1);
    let mut index = String::from("return {\n");
    let scenes: Vec<(&str, Vec<f32>)> = vec![
        ("step", vec![0.0, 0.02, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 1.0, 2.0, 4.0]),
        ("stepbsp", vec![1.0, 2.0, 4.0]),
        ("crack", vec![0.5, 1.0, 2.0, 4.0, 8.0]),
        ("bump", vec![0.1, 0.25, 0.5, 1.0, 2.0]),
        ("overhang", vec![0.5, 1.0, 2.0, 4.0]),
        ("seam", vec![16.0, 64.0]),
        ("slope", vec![0.506, 0.516, 1.006, 1.016, 2.016, 4.024]),
        ("kickermapper", vec![0.0]),
        ("kickerprop", vec![0.0, 0.5, 1.41]),
        ("narrowmapper", vec![0.0]),
        ("narrowprop", vec![0.0]),
        ("slopeold", vec![0.506, 1.006]),
        ("slopeloose", vec![0.506, 1.006]),
        ("slopestrips", vec![0.506, 1.006]),
        ("slopefloor", vec![0.506, 1.006]),
        ("sloperiser", vec![0.506, 1.006]),
    ];
    for (kind, values) in scenes {
        for v in values {
            let raw = scene(kind, v);
            let tags = vec![0u8; raw.len()];
            let mut processed = pipeline::run(raw.clone(), tags, &opts);
            // (SK8_SYNTH_NORISER=1: the riser a step ramp now covers taken out, to
            // see whether the board catches it through the ramp at speed)
            if std::env::var("SK8_SYNTH_NORISER").is_ok() && (kind == "step" || kind == "overhang") {
                processed.tris.retain(|t| {
                    let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
                    let at_edge = t.iter().all(|p| p.x.abs() < 0.01 && p.z <= v + 0.01);
                    !(at_edge && n.z.abs() < 0.1)
                });
            }
            let name = format!("{kind}_{v}");
            std::fs::write(format!("{out}/{name}.lua"),
                format!("return {{ raw = {}, piped = {} }}\n", lua(&raw), lua(&processed.tris))).unwrap();
            let _ = writeln!(index, "  {{ name = \"{name}\", kind = \"{kind}\", v = {v}, added = {} }},", processed.tris.len() as i64 - raw.len() as i64);
            eprintln!("{name}: {} raw, {} after the pipeline ({})", raw.len(), processed.tris.len(), processed.report);
        }
    }
    index.push_str("}\n");
    std::fs::write(format!("{out}/index.lua"), index).unwrap();
}
