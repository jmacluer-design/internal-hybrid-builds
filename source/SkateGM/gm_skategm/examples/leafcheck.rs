//! Round trip on the map's tree with the leaves in their true order.
use gmcl_skategm_win64::world::leaves_in_order;
fn main() {
    let bytes = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let bsp = vbsp::Bsp::read(&bytes).unwrap();
    let leaves = leaves_in_order(&bytes).unwrap();
    let find = |p: [f32; 3]| {
        let mut n = bsp.models[0].head_node;
        while n >= 0 {
            let node = &bsp.nodes[n as usize];
            let pl = &bsp.planes[node.plane_index as usize];
            let d = pl.normal.x * p[0] + pl.normal.y * p[1] + pl.normal.z * p[2];
            n = if d < pl.dist { node.children[1] } else { node.children[0] };
        }
        (-1 - n) as usize
    };
    // leaves of the world tree only (brush entities have their own subtrees)
    let mut world_leaves = Vec::new();
    let mut stack = vec![bsp.models[0].head_node];
    while let Some(n) = stack.pop() {
        if n >= 0 { let node = &bsp.nodes[n as usize]; stack.push(node.children[0]); stack.push(node.children[1]); }
        else { world_leaves.push((-1 - n) as usize); }
    }
    let (mut ok, mut total) = (0, 0);
    for &i in world_leaves.iter().step_by(37) {
        let l = &leaves[i];
        if l.maxs[0] <= l.mins[0] { continue; }
        let c = [(l.mins[0] + l.maxs[0]) as f32 / 2.0, (l.mins[1] + l.maxs[1]) as f32 / 2.0, (l.mins[2] + l.maxs[2]) as f32 / 2.0];
        total += 1;
        let m = &leaves[find(c)];
        if (0..3).all(|k| c[k] >= m.mins[k] as f32 - 1.0 && c[k] <= m.maxs[k] as f32 + 1.0) { ok += 1; }
    }
    println!("round trip with true leaf order: {ok} of {total} land in a leaf containing the point");
}
