//! The collision along a skater's line at many points at once (one map load).
//! Each line of the points file: "label x y z heading_degrees" (z: the engine's
//! position, ~3.4 above the ground). For each, the ground height every unit from
//! 6 behind to 24 ahead on three lines (board centre and 4 units either side),
//! and every steep face those lines cross below 12 units above the ground.
use glam::{Vec2, Vec3};
use gmcl_skategm_win64::{coords, phy, scene::Scene, world};

fn height_at(t: &[Vec3; 3], p: Vec2) -> Option<f32> {
    let (a, b, c) = (t[0].truncate(), t[1].truncate(), t[2].truncate());
    let d = (b - a).perp_dot(c - a);
    if d.abs() < 1e-9 { return None; }
    let u = (p - a).perp_dot(c - a) / d;
    let v = (b - a).perp_dot(p - a) / d;
    if u < -1e-4 || v < -1e-4 || u + v > 1.0 + 1e-4 { return None; }
    Some(t[0].z + u * (t[1].z - t[0].z) + v * (t[2].z - t[0].z))
}

fn crate_height(t: &[Vec3; 3], p: Vec2) -> Option<f32> { height_at(t, p) }

fn seg_hits(t: &[Vec3; 3], p: Vec3, q: Vec3) -> Option<f32> {
    let (e1, e2) = (t[1] - t[0], t[2] - t[0]);
    let dir = q - p;
    let h = dir.cross(e2);
    let a = e1.dot(h);
    if a.abs() < 1e-9 { return None; }
    let s = p - t[0];
    let u = s.dot(h) / a;
    let qv = s.cross(e1);
    let v = dir.dot(qv) / a;
    let k = e2.dot(qv) / a;
    (u >= 0.0 && v >= 0.0 && u + v <= 1.0 && (0.0..=1.0).contains(&k)).then_some(k)
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&a[1]).unwrap();
    let pak = std::path::PathBuf::from(&a[2]);
    let points: Vec<(String, Vec3, f32)> = std::fs::read_to_string(&a[3]).unwrap().lines().filter_map(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        if f.len() < 5 { return None; }
        let n = |i: usize| f[i].parse::<f32>().unwrap();
        Some((f[0].to_string(), Vec3::new(n(1), n(2), n(3)), n(4)))
    }).collect();
    let mut scene = Scene::new(world::from_bsp_with(&bytes, 1).unwrap());
    scene.background_layer = false;
    for name in scene.wanted() {
        let mdl = name.trim_end_matches("#bbox").to_string();
        let hulls = std::fs::read(pak.join(mdl.to_lowercase().replace(".mdl", ".phy"))).ok().and_then(|p| phy::hulls(&p).ok())
            .map(|h| h.into_iter().map(|piece| piece.into_iter().flatten().collect()).collect()).unwrap_or_default();
        scene.define(name, hulls);
    }
    let centre = points.iter().fold(Vec3::ZERO, |s, p| s + p.1) / points.len().max(1) as f32;
    let (tris, rails, _, tags) = scene.build_tagged(centre);
    let rails: Vec<Vec<Vec3>> = rails.iter().map(|r| r.iter().map(|v| Vec3::from_array(coords::from_skate(*v))).collect()).collect();
    let tris: Vec<[Vec3; 3]> = tris.iter().map(|t| t.map(|v| Vec3::from_array(coords::from_skate(v)))).collect();
    for (label, at, heading) in &points {
        let d = Vec2::new(heading.to_radians().cos(), heading.to_radians().sin());
        let side = d.perp();
        let ground0 = at.z - 3.42;
        println!("=== {label} at {:.1} {:.1} {:.2} heading {heading:.0} (ground ~{ground0:.2})", at.x, at.y, at.z);
        let near: Vec<(usize, &[Vec3; 3])> = tris.iter().enumerate().filter(|(_, t)| {
            let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
            let r = 32.0;
            !(at.x < lo.x - r || at.x > hi.x + r || at.y < lo.y - r || at.y > hi.y + r || lo.z > at.z + 30.0 || hi.z < at.z - 30.0)
        }).collect();
        if std::env::var("SK8_NEAR_DEBUG").is_ok() {
            let mut near_all: Vec<(f32, f32, u8, f32)> = tris.iter().enumerate().filter(|(_, t)| {
                let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
                !(at.x < lo.x - 8.0 || at.x > hi.x + 8.0 || at.y < lo.y - 8.0 || at.y > hi.y + 8.0)
            }).map(|(i, t)| { let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero(); (t[0].z.min(t[1].z).min(t[2].z), t[0].z.max(t[1].z).max(t[2].z), tags[i], n.z) }).collect();
            near_all.sort_by(|a, b| b.1.total_cmp(&a.1));
            println!("  columns over this spot: {} triangles; top 12 (zlo, zhi, tag, nz): {:?}", near_all.len(), &near_all.iter().filter(|x| x.1 < at.z + 100.0).collect::<Vec<_>>());
            if std::env::var("SK8_NEAR_DEBUG").ok().as_deref() == Some("2") {
                for (i, t) in tris.iter().enumerate() {
                    if crate_height(t, at.truncate()).is_some_and(|z| (z - at.z).abs() < 40.0) { println!("    tag {} {:?}", tags[i], t.map(|v| v.to_array().map(|c| (c * 100.0).round() / 100.0))); }
                }
            }
        }
        for off in [-4.0f32, 0.0, 4.0] {
            let mut prof = Vec::new();
            let mut walls = Vec::new();
            let mut prev: Option<(Vec2, f32)> = None;
            for s in -6..=24 {
                let p = at.truncate() + d * s as f32 + side * off;
                let mut best: Option<(f32, u8)> = None;
                for (i, t) in &near {
                    let n = (t[1] - t[0]).cross(t[2] - t[0]);
                    if n.z <= 0.3 * n.length() { continue; }
                    if let Some(h) = height_at(t, p) {
                        if h <= at.z + 6.0 && best.is_none_or(|b| h > b.0) { best = Some((h, tags[*i])); }
                    }
                }
                prof.push(match best { Some((h, g)) => format!("{:+.2}{}", h - ground0, if g == 0 { "" } else { ["", "d", "p", "e", "x", "r", "c"][g as usize] }), None => "--".into() });
                if let (Some((pp, pg)), Some((h, _))) = (prev, best) {
                    let g = pg.max(h);
                    for lift in [0.3f32, 1.5, 4.0, 10.0] {
                        let (a3, b3) = (pp.extend(g + lift), p.extend(g + lift));
                        for (i, t) in &near {
                            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
                            if n.z.abs() > 0.7 { continue; }
                            if seg_hits(t, a3, b3).is_some() {
                                let top = t[0].z.max(t[1].z).max(t[2].z);
                                walls.push(format!("s{} lift {lift} tag {} n {:+.2},{:+.2},{:+.2} top {:+.2}", s, tags[*i], n.x, n.y, n.z, top - ground0));
                            }
                        }
                    }
                }
                prev = best.map(|(h, _)| (p, h));
            }
            walls.dedup();
            println!("  side {off:+}: {}", prof.join(" "));
            for w in walls.iter().take(12) { println!("     wall {w}"); }
        }
        let ground = |p: Vec2| -> Option<(usize, f32)> {
            let mut best: Option<(usize, f32)> = None;
            for (i, t) in &near {
                let n = (t[1] - t[0]).cross(t[2] - t[0]);
                if n.z <= 0.3 * n.length() { continue; }
                if let Some(h) = height_at(t, p) {
                    if h <= at.z + 6.0 && best.is_none_or(|b| h > b.1) { best = Some((*i, h)); }
                }
            }
            best
        };
        let mut last: Option<(usize, f32)> = None;
        let mut seams = Vec::new();
        for k in -24..=96 {
            let s = k as f32 * 0.25;
            let p = at.truncate() + d * s;
            let g = ground(p);
            if let (Some((li, lh)), Some((gi, gh))) = (last, g) {
                if li != gi {
                    let n = |i: usize| { let t = &tris[i]; (t[1] - t[0]).cross(t[2] - t[0]).normalize() };
                    let ang = n(li).dot(n(gi)).clamp(-1.0, 1.0).acos().to_degrees();
                    let other = height_at(&tris[li], p).map(|h| format!("{:+.3}", gh - h)).unwrap_or("?".into());
                    seams.push(format!("s{s:.2} tag {}>{} dz {:+.3} gap {other} angle {ang:.1}", tags[li], tags[gi], gh - lh));
                }
            }
            last = g;
        }
        println!("  seams on the centre line: {}", seams.join(" | "));
        let mut ceil = Vec::new();
        for (i, t) in &near {
            let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
            if n.z > -0.3 { continue; }
            for k in -6..=24 {
                for off in [-4.0f32, 0.0, 4.0] {
                    let p = at.truncate() + d * k as f32 + side * off;
                    if let Some(h) = height_at(t, p) {
                        if h > ground0 - 1.0 && h < ground0 + 14.0 { ceil.push(format!("s{k} side {off:+} tag {} under {:+.2}", tags[*i], h - ground0)); }
                    }
                }
            }
        }
        for r in &rails {
            for w in r.windows(2) {
                let (a, b) = (w[0], w[1]);
                let ab = b - a;
                let k = ((*at - a).dot(ab) / ab.length_squared().max(1e-9)).clamp(0.0, 1.0);
                let p = a + ab * k;
                if (p - *at).truncate().length() < 24.0 && (p.z - ground0).abs() < 12.0 {
                    println!("  rail piece {:?} -> {:?}, nearest {:.1} away at {:+.2} above ground", a.to_array().map(|x| x.round()), b.to_array().map(|x| x.round()), (p - *at).truncate().length(), p.z - ground0);
                }
            }
        }
        ceil.truncate(10);
        if !ceil.is_empty() { println!("  overhangs: {}", ceil.join(" | ")); }
    }
}
