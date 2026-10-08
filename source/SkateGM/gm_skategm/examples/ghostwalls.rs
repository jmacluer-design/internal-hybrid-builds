//! Is the space just behind each world-brush collision triangle really solid,
//! by Source's own rule (the leaf's brushes, point inside all of a brush's planes)?
use gmcl_skategm_win64::world::{self, leaves_in_order};
use glam::Vec3;
use std::collections::HashSet;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let bytes = std::fs::read(&path).unwrap();
    let bsp = vbsp::Bsp::read(&bytes).unwrap();
    let leaves = leaves_in_order(&bytes).unwrap();
    let walk = |head: i32, sorted: bool| {
        let mut out = HashSet::new();
        let mut stack = vec![head];
        while let Some(n) = stack.pop() {
            if n >= 0 { let node = &bsp.nodes[n as usize]; stack.push(node.children[0]); stack.push(node.children[1]); continue; }
            let i = (-1 - n) as usize;
            let (first, count) = if sorted { let l = &bsp.leaves[i]; (l.first_leaf_brush as usize, l.leaf_brush_count as usize) } else { (leaves[i].first, leaves[i].count) };
            for lb in bsp.leaf_brushes.iter().skip(first).take(count) { out.insert(lb.brush as usize); }
        }
        out
    };
    let old = walk(bsp.models[0].head_node, true);
    let new = walk(bsp.models[0].head_node, false);
    let mut ents = HashSet::new();
    for m in bsp.models.iter().skip(1) { ents.extend(walk(m.head_node, false)); }
    println!("{path}");
    println!("  world brushes: old (shuffled leaves) {}, correct {}", old.len(), new.len());
    println!("  old selection wrongly included {} brush-entity brushes and missed {} real world brushes",
        old.intersection(&ents).filter(|b| !new.contains(b)).count(), new.difference(&old).count());

    let leaf_at = |p: Vec3| {
        let mut n = bsp.models[0].head_node;
        while n >= 0 {
            let node = &bsp.nodes[n as usize];
            let pl = &bsp.planes[node.plane_index as usize];
            n = if pl.normal.x * p.x + pl.normal.y * p.y + pl.normal.z * p.z < pl.dist { node.children[1] } else { node.children[0] };
        }
        leaves[(-1 - n) as usize]
    };
    let solid = |p: Vec3| {
        let leaf = leaf_at(p);
        if leaf.contents & 1 != 0 { return true; }
        bsp.leaf_brushes.iter().skip(leaf.first).take(leaf.count).any(|lb| {
            let b = &bsp.brushes[lb.brush as usize];
            b.flags.bits() & (0x1 | 0x2 | 0x8 | 0x10000) != 0
                && bsp.brush_sides.iter().skip(b.brush_side as usize).take(b.num_brush_sides as usize).all(|s| {
                    let pl = &bsp.planes[s.plane as usize];
                    pl.normal.x * p.x + pl.normal.y * p.y + pl.normal.z * p.z <= pl.dist + 0.01
                })
        })
    };
    let w = world::from_bsp(&bytes).unwrap();
    let brush_tris: usize = w.summary.split(" -> ").nth(1).and_then(|s| s.split(' ').next()).and_then(|n| n.parse().ok()).unwrap();
    let (mut checked, mut ghost) = (0, 0);
    for t in w.triangles.iter().take(brush_tris) {
        let n = (t[1] - t[0]).cross(t[2] - t[0]);
        if n.length() < 8.0 { continue; }
        let c = (t[0] + t[1] + t[2]) / 3.0 - n.normalize();
        checked += 1;
        if !solid(c) { ghost += 1; }
    }
    println!("  collision surfaces with nothing solid behind them: {ghost} of {checked}");
}
