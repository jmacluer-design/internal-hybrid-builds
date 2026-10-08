//! How skateable is a map's collision? Loads the map as the module does, gives
//! its props their shapes as the add-on does in the game (from the map's packed
//! .phy / .mdl files), builds the region the engine gets around a spot, and
//! rolls test paths over it counting lips (sudden rises of 0.6-12 units: what
//! gives runouts) and kinks (sudden concave changes of slope: impacts).
//!   skatecheck <map.bsp> <pak dir> [x y z]
use glam::Vec3;
use gmcl_skategm_win64::{cleanup::Heights, coords, phy, scene::Scene, world};

fn box_hull(lo: Vec3, hi: Vec3) -> Vec<Vec3> {
    let c = |i: usize| Vec3::new(if i & 1 == 0 { lo.x } else { hi.x }, if i & 2 == 0 { lo.y } else { hi.y }, if i & 4 == 0 { lo.z } else { hi.z });
    let faces = [[0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5]];
    let mut out = Vec::new();
    for f in faces {
        out.extend([c(f[0]), c(f[1]), c(f[2]), c(f[0]), c(f[2]), c(f[3])]);
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bytes = std::fs::read(&args[1]).unwrap();
    let pak = std::path::PathBuf::from(&args[2]);
    let centre = if args.len() >= 6 { Vec3::new(args[3].parse().unwrap(), args[4].parse().unwrap(), args[5].parse().unwrap()) } else { Vec3::new(-3000., -500., 450.) };
    let smooth: u32 = std::env::var("SK8_SMOOTH").ok().and_then(|v| v.parse().ok()).unwrap_or(1);
    let t = std::time::Instant::now();
    let w = world::from_bsp_with(&bytes, smooth).unwrap();
    let map_ms = t.elapsed().as_millis();
    let mut scene = Scene::new(w);
    scene.background_layer = false;
    // shapes, as the add-on reads them in the game
    let (mut phys, mut boxes, mut none, mut tiny, mut stock) = (0, 0, 0, 0, 0);
    for name in scene.wanted() {
        let (mdl, want_box) = match name.strip_suffix("#bbox") { Some(m) => (m.to_string(), true), None => (name.clone(), false) };
        let file = |ext: &str| std::fs::read(pak.join(mdl.to_lowercase().replace(".mdl", ext))).ok();
        let Some(mdl_bytes) = file(".mdl") else { stock += 1; scene.define(name, vec![]); continue };
        let mut hulls: Vec<Vec<Vec3>> = Vec::new();
        if want_box {
            if let Some((lo, hi)) = phy::mdl_hull(&mdl_bytes) { hulls.push(box_hull(lo, hi)); boxes += 1; }
        } else if let Some(p) = file(".phy") {
            if let Ok(h) = phy::hulls(&p) {
                hulls = h.into_iter().map(|piece| piece.into_iter().flatten().collect()).collect();
                phys += 1;
            }
        }
        if hulls.is_empty() { none += 1; }
        // tiny clutter left out (the add-on's default)
        let (lo, hi) = hulls.iter().flatten().fold((Vec3::splat(f32::MAX), Vec3::splat(f32::MIN)), |(a, b), p| (a.min(*p), b.max(*p)));
        if !hulls.is_empty() && (hi.x - lo.x).max(hi.y - lo.y) <= 24.0 && hi.z - lo.z <= 12.0 { tiny += 1; hulls.clear(); }
        scene.define(name, hulls);
    }
    let t2 = std::time::Instant::now();
    let (tris, _, st, tags) = scene.build_tagged(centre);
    let build_ms = t2.elapsed().as_millis();
    let tris: Vec<[Vec3; 3]> = tris.iter().map(|t| t.map(|v| Vec3::from_array(coords::from_skate(v)))).collect();
    // roll test paths over what's rideable around the centre
    // only what a board can roll on: upward-facing surfaces (not undersides)
    let tris: Vec<[Vec3; 3]> = tris.into_iter().zip(tags.iter()).filter(|(t, _)| (t[1] - t[0]).cross(t[2] - t[0]).z > 1e-4).map(|(t, _)| t).collect();
    let tags: Vec<u8> = { let all = scene.build_tagged(centre).3; let all_t = scene.build_tagged(centre).0;
        all_t.iter().zip(all).filter(|(t, _)| { let t = t.map(|v| Vec3::from_array(coords::from_skate(v))); (t[1] - t[0]).cross(t[2] - t[0]).z > 1e-4 }).map(|(_, g)| g).collect() };
    let heights = Heights::new(&tris);
    // the same without our additions (ledge ramps, curves, bridges): to tell
    // whether a lip is onto one of those or is the map's own
    let only = |keep: &dyn Fn(u8) -> bool| -> Vec<[Vec3; 3]> { tris.iter().zip(&tags).filter(|(_, g)| keep(**g)).map(|(t, _)| *t).collect() };
    let base = only(&|g| g != world::TAG_STEP_RAMP && g != world::TAG_CURVE);
    let ramps_t = only(&|g| g == world::TAG_STEP_RAMP);
    let curves_t = only(&|g| g == world::TAG_CURVE);
    let (base_h, ramp_h, curve_h) = (Heights::new(&base), Heights::new(&ramps_t), Heights::new(&curves_t));
    // what surface is at (x, y, z): 0 the map's, 1 a ledge ramp, 2 a curve
    let kind = |x: f32, y: f32, z: f32| {
        if base_h.below(x, y, z + 0.01).is_some_and(|(zb, _)| (zb - z).abs() < 0.05) { 0 }
        else if ramp_h.below(x, y, z + 0.01).is_some_and(|(zb, _)| (zb - z).abs() < 0.05) { 1 }
        else if curve_h.below(x, y, z + 0.01).is_some_and(|(zb, _)| (zb - z).abs() < 0.05) { 2 } else { 0 }
    };
    let mut table = [[0usize; 3]; 3]; // [from][onto]
    // What each problem is: [from an addition, micro-lip, missed curb, real]
    // for lips; [from an addition, missed crease, real] for kinks.
    let classify_lip = |from_kind: usize, onto_kind: usize, excess: f32, nz_onto: f32| -> usize {
        if from_kind != 0 || onto_kind != 0 { 0 }
        else if excess < 2.0 { 1 }
        else if excess <= 8.0 && nz_onto > 0.85 { 2 }
        else { 3 }
    };
    let classify_kink = |from_kind: usize, onto_kind: usize, nz_onto: f32| -> usize {
        if from_kind != 0 || onto_kind != 0 { 0 } else if nz_onto > 0.5 { 1 } else { 2 }
    };
    let (mut lip_class, mut kink_class) = ([0usize; 4], [0usize; 3]);
    let (mut up_lip_class, mut up_kink_class) = ([0usize; 4], [0usize; 3]);
    let mut shown = 0;
    let (mut ramp_how, mut ramp_rise) = ([0usize; 4], [0f32; 4]);
    let mut onto_added = 0usize;
    let mut kinks_added = 0usize;
    let tops: Vec<&[Vec3; 3]> = tris.iter().filter(|t| {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        let c = (t[0] + t[1] + t[2]) / 3.0;
        n.z > 0.85 && (c - centre).truncate().length() < 1500.0 && (t[1] - t[0]).cross(t[2] - t[0]).length() > 20.0
    }).collect();
    let mut seed: u64 = 12345;
    let mut rnd = || { seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407); ((seed >> 33) as f32) / (1u64 << 31) as f32 };
    let (mut length, mut lips, mut kinks, mut big_lips) = (0.0f32, 0usize, 0usize, 0usize);
    for _ in 0..4000 {
        let t = tops[(rnd() * tops.len() as f32) as usize % tops.len()];
        let (u, v) = (rnd(), rnd());
        let (u, v) = if u + v > 1.0 { (1.0 - u, 1.0 - v) } else { (u, v) };
        let mut p = t[0] + (t[1] - t[0]) * u + (t[2] - t[0]) * v;
        let a = rnd() * std::f32::consts::TAU;
        let dir = Vec3::new(a.cos(), a.sin(), 0.0);
        let mut last_slope: Option<f32> = None;
        let mut nzp = 1.0f32;
        for _ in 0..400 {
            let q = p + dir * 0.5;
            let Some((z, nzq)) = heights.below(q.x, q.y, p.z + 12.5) else { break };
            let dz = z - p.z;
            if dz < -12.0 { break; } // a drop off an edge: not what we measure
            let added_here = base_h.below(q.x, q.y, p.z + 12.5).map_or(true, |(zb, _)| (zb - z).abs() > 0.05);
            // a lip is a rise beyond what the surface's own slope explains
            // (climbing a steep quarter pipe rises fast, and that's fine)
            let slope_rise = |nz: f32| 0.5 * (nz.clamp(0.05, 1.0).acos()).tan().min(6.0);
            let explained = slope_rise(nzp).max(slope_rise(nzq));
            if dz < -1.0 { last_slope = None; } // a drop: landing after it isn't a kink
            if dz - explained > 0.5 {
                lips += 1;
                lip_class[classify_lip(kind(p.x, p.y, p.z), kind(q.x, q.y, z), dz - explained, nzq)] += 1;
                table[kind(p.x, p.y, p.z)][kind(q.x, q.y, z)] += 1;
                if kind(q.x, q.y, z) == 1 {
                    // onto a ledge ramp: from its front, its side, or its top?
                    let hit = ramps_t.iter().find(|t| {
                        let n = (t[1] - t[0]).cross(t[2] - t[0]);
                        if n.z.abs() < 1e-6 { return false; }
                        let zz = t[0].z - (n.x * (q.x - t[0].x) + n.y * (q.y - t[0].y)) / n.z;
                        let e = |a: Vec3, b: Vec3| ((b - a).cross(Vec3::new(q.x, q.y, zz) - a)).dot(n) >= -1e-3;
                        (zz - z).abs() < 0.05 && e(t[0], t[1]) && e(t[1], t[2]) && e(t[2], t[0])
                    });
                    if let Some(t) = hit {
                        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
                        let down = Vec3::new(n.x, n.y, 0.0).normalize_or_zero();
                        let c = dir.dot(-down); // 1 = straight up the ramp from its foot
                        let bucket = if down == Vec3::ZERO { 3 } else if c > 0.7 { 0 } else if c < -0.7 { 2 } else { 1 };
                        ramp_how[bucket] += 1;
                        if bucket == 1 && std::env::var("SK8_FOOT").is_ok() && shown < 6 {
                            shown += 1;
                            eprintln!("FOOT lip {:.2} at ({:.1} {:.1}): from z {:.2} onto ramp z {:.2}; ramp triangle z {:.2} {:.2} {:.2}, up {:.3}; floor under q (map only): {:?}",
                                dz, q.x, q.y, p.z, z, t[0].z, t[1].z, t[2].z, n.z, base_h.below(q.x, q.y, z + 0.01).map(|(a, b)| (a, b)));
                        }
                        ramp_rise[bucket] += dz;
                    }
                }
                if std::env::var("SK8_SHOW").is_ok() && (kind(p.x, p.y, p.z) != 0 || kind(q.x, q.y, z) != 0) && shown < 8 {
                    shown += 1;
                    // every surface in the column at q, top down
                    let mut col: Vec<(f32, &str, f32)> = Vec::new();
                    for (set, name) in [(&base, "map"), (&ramps_t, "ramp"), (&curves_t, "curve")] {
                        for t in set.iter() {
                            let (lo, hi) = (t[0].min(t[1]).min(t[2]), t[0].max(t[1]).max(t[2]));
                            if q.x < lo.x || q.x > hi.x || q.y < lo.y || q.y > hi.y { continue; }
                            let n = (t[1] - t[0]).cross(t[2] - t[0]);
                            if n.z.abs() < 1e-6 { continue; }
                            let zz = t[0].z - (n.x * (q.x - t[0].x) + n.y * (q.y - t[0].y)) / n.z;
                            let bary = |a: Vec3, b: Vec3| ((b - a).cross(Vec3::new(q.x, q.y, zz) - a)).dot(n) >= -1e-3;
                            if bary(t[0], t[1]) && bary(t[1], t[2]) && bary(t[2], t[0]) && (zz - p.z).abs() < 14.0 {
                                col.push((zz, name, n.normalize().z));
                            }
                        }
                    }
                    col.sort_by(|a, b| b.0.total_cmp(&a.0));
                    col.dedup_by(|a, b| (a.0 - b.0).abs() < 0.02 && a.1 == b.1);
                    eprintln!("LIP {}->{} rise {:.2} (slope explains {:.2}) at", ["map", "ramp", "curve"][kind(p.x, p.y, p.z)], ["map", "ramp", "curve"][kind(q.x, q.y, z)], dz, explained);
                    eprintln!("   at ({:.1} {:.1}) from z {:.2} to {:.2} (heading {:.2} {:.2}); column: {:?}", q.x, q.y, p.z, z, dir.x, dir.y,
                        col.iter().map(|(z, n, nz)| format!("{n} {z:.2} (up {nz:.2})")).collect::<Vec<_>>());
                }
                if added_here { onto_added += 1; }
                if dz > 2.0 { big_lips += 1; }
                last_slope = None;
            } else if dz >= -1.0 {
                let slope = (dz / 0.5).atan().to_degrees();
                if let Some(l) = last_slope { if slope - l > 20.0 {
                    kinks += 1;
                    kink_class[classify_kink(kind(p.x, p.y, p.z), kind(q.x, q.y, z), nzq)] += 1;
                    if added_here { kinks_added += 1; }
                    let (kp, kq) = (kind(p.x, p.y, p.z), kind(q.x, q.y, z));
                    if std::env::var("SK8_KINKS").is_ok() && (kp != 0 || kq != 0) && shown < 10 {
                        shown += 1;
                        eprintln!("KINK {}->{} slope {:.0} -> {:.0} deg at ({:.1} {:.1} {:.1}) heading ({:.2} {:.2}), surface up {:.2} -> {:.2}",
                            ["map", "ramp", "curve"][kp], ["map", "ramp", "curve"][kq], l, slope, q.x, q.y, z, dir.x, dir.y, nzp, nzq);
                    }
                } }
                last_slope = Some(slope);
            }
            length += 0.5;
            p = Vec3::new(q.x, q.y, z);
            nzp = nzq;
        }
    }
    // Uphill runs: what ramp transitions are for. Pick a slope, back off 24
    // units downhill onto whatever's there, ride straight up it for 80 units.
    let slopes: Vec<&[Vec3; 3]> = tris.iter().filter(|t| {
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize_or_zero();
        let c = (t[0] + t[1] + t[2]) / 3.0;
        n.z > 0.5 && n.z < 0.985 && (c - centre).truncate().length() < 1500.0 && (t[1] - t[0]).cross(t[2] - t[0]).length() > 40.0
    }).collect();
    let (mut up_runs, mut up_lips, mut up_kinks, mut up_stopped) = (0usize, 0usize, 0usize, 0usize);
    for _ in 0..3000 {
        if slopes.is_empty() { break; }
        let t = slopes[(rnd() * slopes.len() as f32) as usize % slopes.len()];
        let n = (t[1] - t[0]).cross(t[2] - t[0]).normalize();
        let uphill = -Vec3::new(n.x, n.y, 0.0).normalize();
        let c = (t[0] + t[1] + t[2]) / 3.0;
        let start = c - uphill * 24.0;
        let Some((z0, _)) = heights.below(start.x, start.y, c.z + 1.0) else { continue };
        let mut p = Vec3::new(start.x, start.y, z0);
        let (mut last, mut nzp) = (None::<f32>, 1.0f32);
        let (mut lips_here, mut kinks_here) = (0, 0);
        up_runs += 1;
        for _ in 0..160 {
            let q = p + uphill * 0.5;
            let Some((z, nzq)) = heights.below(q.x, q.y, p.z + 12.5) else { break };
            let dz = z - p.z;
            if dz < -1.0 { last = None; p = Vec3::new(q.x, q.y, z); nzp = nzq; continue; }
            let slope_rise = |nz: f32| 0.5 * (nz.clamp(0.05, 1.0).acos()).tan().min(6.0);
            let excess = dz - slope_rise(nzp).max(slope_rise(nzq));
            if excess > 0.5 { lips_here += 1; up_lip_class[classify_lip(kind(p.x, p.y, p.z), kind(q.x, q.y, z), excess, nzq)] += 1; }
            let slope = (dz / 0.5).atan().to_degrees();
            if slope > 75.0 { up_stopped += 1; break; } // a wall: the run ends
            if let Some(l) = last { if slope - l > 12.0 {
                kinks_here += 1;
                let c = classify_kink(kind(p.x, p.y, p.z), kind(q.x, q.y, z), nzq);
                up_kink_class[c] += 1;
                if c == 1 && std::env::var("SK8_MISSED").is_ok() && shown < 8 {
                    shown += 1;
                    // the surfaces under p and q: what they're made of, and their normals
                    let under = |x: f32, y: f32, zz: f32| -> String {
                        for (t, g) in tris.iter().zip(tags.iter()) {
                            let n = (t[1] - t[0]).cross(t[2] - t[0]);
                            if n.z.abs() < 1e-6 { continue; }
                            let z0 = t[0].z - (n.x * (x - t[0].x) + n.y * (y - t[0].y)) / n.z;
                            let e = |a: Vec3, b: Vec3| ((b - a).cross(Vec3::new(x, y, z0) - a)).dot(n) >= -1e-3;
                            if (z0 - zz).abs() < 0.05 && e(t[0], t[1]) && e(t[1], t[2]) && e(t[2], t[0]) {
                                let nn = n.normalize();
                                let area = n.length() * 0.5;
                                return format!("tag {g} up {:.3} area {:.0}", nn.z, area);
                            }
                        }
                        "?".into()
                    };
                    if shown == 1 {
                        if let Ok(path) = std::env::var("SK8_DUMP") {
                            let mut text = String::new();
                            for (t, g) in tris.iter().zip(tags.iter()) {
                                let c = (t[0] + t[1] + t[2]) / 3.0;
                                let near = t.iter().any(|v| (*v - q).length() < 40.0) || (c - q).length() < 40.0;
                                if near { text += &format!("{g} {} {} {} {} {} {} {} {} {}\n", t[0].x, t[0].y, t[0].z, t[1].x, t[1].y, t[1].z, t[2].x, t[2].y, t[2].z); }
                            }
                            std::fs::write(&path, text).unwrap();
                            eprintln!("DUMPED the collision around ({:.1} {:.1} {:.1}) to {path}", q.x, q.y, z);
                        }
                    }
                    let near_curve = curves_t.iter().map(|t| { let c = (t[0] + t[1] + t[2]) / 3.0; (c - q).length() }).fold(f32::MAX, f32::min);
                    let rise = z - p.z;
                    eprintln!("MISSED kink {:.0} -> {:.0} deg (rise {:.2} in 0.5) at ({:.1} {:.1} {:.1}): before [{}] after [{}]; nearest curve {:.1} units", l, slope, rise, q.x, q.y, z, under(p.x, p.y, p.z), under(q.x, q.y, z), near_curve);
                }
            } }
            last = Some(slope);
            p = Vec3::new(q.x, q.y, z);
            nzp = nzq;
        }
        up_lips += lips_here;
        up_kinks += kinks_here;
    }
    let per = |n: usize| n as f32 / length * 10_000.0;
    println!("smooth {smooth}: map {map_ms} ms, region {build_ms} ms: {} triangles (budget 150000), {} rails; props: {phys} physics, {boxes} box, {none} no shape, {tiny} tiny, {stock} stock (not in the map)",
        st.triangles, st.rails);
    println!("  per 10,000 units ridden: lips {:.1} (over 2 units: {:.1}), kinks {:.1}", per(lips), per(big_lips), per(kinks));
    println!("  of which onto our own additions: lips {:.1}, kinks {:.1}", per(onto_added), per(kinks_added));
    println!("  uphill runs: {up_runs}; per 100 runs: lips {:.1}, kinks (12 deg) {:.1}, into a wall {:.1}",
        up_lips as f32 * 100.0 / up_runs.max(1) as f32, up_kinks as f32 * 100.0 / up_runs.max(1) as f32, up_stopped as f32 * 100.0 / up_runs.max(1) as f32);
    for (i, what) in ["from its foot (heading up it)", "from its side", "from its top (heading down it)", "a flat bridge"].iter().enumerate() {
        if ramp_how[i] > 0 { println!("  lips onto ledge ramps {what}: {} (average rise {:.1})", ramp_how[i], ramp_rise[i] / ramp_how[i] as f32); }
    }
    let per_run = |n: usize| n as f32 * 100.0 / up_runs.max(1) as f32;
    println!("  ARTEFACTS random (per 10,000 units): from additions {:.1}, micro-lips {:.1}, missed curbs {:.1}, missed-crease kinks {:.1}, addition kinks {:.1} | real: tall lips {:.1}, wall kinks {:.1}",
        per(lip_class[0]), per(lip_class[1]), per(lip_class[2]), per(kink_class[1]), per(kink_class[0]), per(lip_class[3]), per(kink_class[2]));
    println!("  ARTEFACTS uphill (per 100 runs): from additions {:.1}, micro-lips {:.1}, missed curbs {:.1}, missed-crease kinks {:.1}, addition kinks {:.1} | real: tall lips {:.1}, wall kinks {:.1}",
        per_run(up_lip_class[0]), per_run(up_lip_class[1]), per_run(up_lip_class[2]), per_run(up_kink_class[1]), per_run(up_kink_class[0]), per_run(up_lip_class[3]), per_run(up_kink_class[2]));
    let names = ["map", "ledge ramp", "curve"];
    for f in 0..3 { for o in 0..3 { if table[f][o] > 0 { println!("  lips from {} onto {}: {:.1}", names[f], names[o], per(table[f][o])); } } }
}
