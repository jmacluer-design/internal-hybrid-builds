/* Outbreak icon set: original inline SVG, 24x24 grid, 1.7 stroke, round joins. Injected once as a <symbol> sprite; use OB.icon('name'). */
(function () {
  'use strict';
  const OB = window.OB;
  const P = {
    heart: '<path d="M12 20c-5.500-3.400-8-6.800-8-10.200A4.300 4.300 0 0 1 12 7.300 4.300 4.300 0 0 1 20 9.800C20 13.200 17.500 16.600 12 20z"/>',
    food: '<path d="M6.500 3v6a2 2 0 0 0 4 0V3M8.500 3v18"/><path d="M17.500 21V3c-2.400 1.300-3.800 4-3.800 7.300 0 1.800.9 3 2.200 3.300h1.600"/>',
    drop: '<path d="M12 3.500C9.200 7 6.200 10 6.200 13.700a5.800 5.800 0 0 0 11.600 0C17.800 10 14.800 7 12 3.500z"/>',
    moon: '<path d="M19.500 14.200A7.800 7.800 0 0 1 9.800 4.500a8 8 0 1 0 9.700 9.700z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 3v2.200M12 18.800V21M3 12h2.200M18.800 12H21M5.600 5.600l1.600 1.600M16.800 16.800l1.600 1.600M5.600 18.400l1.600-1.600M16.800 7.200l1.600-1.600"/>',
    bleed: '<path d="M12 3.500C9.200 7 6.200 10 6.200 13.700a5.800 5.800 0 0 0 11.600 0C17.800 10 14.800 7 12 3.500z"/><path d="M12 11v5M9.500 13.500h5"/>',
    bio: '<circle cx="12" cy="12.500" r="1.800"/><circle cx="12" cy="6.800" r="2.800"/><circle cx="7" cy="15.600" r="2.800"/><circle cx="17" cy="15.600" r="2.800"/>',
    weight: '<path d="M9 7.500a3 3 0 0 1 6 0"/><path d="M5.800 20h12.400l-1.400-10.500H7.200z"/>',
    compass: '<circle cx="12" cy="12" r="8.500"/><path d="M15.800 8.200l-2.100 5.500-5.500 2.100 2.100-5.500z"/>',
    clock: '<circle cx="12" cy="12" r="8.500"/><path d="M12 7.500V12l3 2"/>',
    skull: '<path d="M12 3.500a7.500 7.500 0 0 0-7.500 7.500c0 2.500 1.200 4 2.800 5v3.500h9.400V16c1.600-1 2.800-2.500 2.800-5A7.500 7.500 0 0 0 12 3.500z"/><circle cx="9" cy="11" r="1.600"/><circle cx="15" cy="11" r="1.600"/><path d="M10.500 18.500v-2M13.500 18.500v-2"/>',
    shield: '<path d="M12 3.200l7 2.800v5.600c0 4.400-3 7.800-7 9.300-4-1.500-7-4.900-7-9.300V6z"/>',
    alert: '<path d="M12 4.200l9 15.600H3z"/><path d="M12 10v4.500M12 17.300v.2"/>',
    home: '<path d="M4 11.200L12 4l8 7.200"/><path d="M6 10v10h12V10"/><path d="M10 20v-5.500h4V20"/>',
    person: '<circle cx="12" cy="7.800" r="3.400"/><path d="M5.200 20c.5-4.200 3.200-6.300 6.800-6.300s6.300 2.100 6.800 6.300"/>',
    people: '<circle cx="9" cy="8" r="3"/><path d="M3 19.500c.4-3.600 2.600-5.500 6-5.500s5.600 1.900 6 5.500"/><circle cx="17" cy="9" r="2.400"/><path d="M16.500 14.200c2.700 0 4.300 1.500 4.700 4.500"/>',
    bolt: '<path d="M13.500 3L5.800 13.200h5.400L10.500 21l7.700-10.200h-5.400z"/>',
    wrench: '<path d="M15 4.500a4.500 4.500 0 0 0-4.300 5.800L4.700 16.300a2.100 2.100 0 0 0 3 3l6-6A4.500 4.500 0 0 0 19.500 9l-2.700 2.700-2.500-.6-.6-2.500L16.400 5.900A4.500 4.500 0 0 0 15 4.500z"/>',
    hammer: '<path d="M4.500 19.500l8-8"/><path d="M9.800 6.200l4-3 6.200 6.200-3 4z"/>',
    crate: '<path d="M4 8l8-4 8 4v8l-8 4-8-4z"/><path d="M4 8l8 4 8-4M12 12v8"/>',
    bed: '<path d="M3.500 18.500v-9M3.500 15h17v3.500M20.500 15v-3a2.500 2.500 0 0 0-2.500-2.500h-6.500V15"/><circle cx="7.300" cy="11.700" r="1.800"/>',
    fire: '<path d="M12 3c1 3.500 5 5.500 5 10a5 5 0 0 1-10 0c0-2 1-3.200 2-4.200 0 1.500.8 2.300 1.600 2.500C10.300 8.200 11.200 5.500 12 3z"/>',
    stove: '<rect x="4" y="4" width="16" height="16" rx="2"/><circle cx="9" cy="9" r="2"/><circle cx="15" cy="9" r="2"/><path d="M7 15.500h10"/>',
    gen: '<rect x="3.500" y="7" width="17" height="11" rx="2"/><path d="M13 9.500L10.500 13H13.500L11 16.500"/><path d="M7 18v2M17 18v2"/>',
    tower: '<path d="M8 4h8l-1 6H9z"/><path d="M9 10l-2 10M15 10l2 10M8 15h8M7.800 20h8.400"/>',
    door: '<rect x="6" y="3.500" width="12" height="17" rx="1.500"/><circle cx="15" cy="12.500" r=".8" fill="currentColor"/>',
    wall: '<rect x="3.500" y="5" width="17" height="14" rx="1"/><path d="M3.500 9.700h17M3.500 14.300h17M9 5v4.700M15 9.700v4.600M9 14.300V19"/>',
    barricade: '<path d="M4 8h16M4 14h16M6 5l-2 14M18 5l2 14M10 5l-1 14M14 5l1 14"/>',
    floor: '<path d="M4 7.500l8-3.500 8 3.500-8 3.500zM4 12l8 3.500 8-3.500M4 16.500l8 3.500 8-3.500"/>',
    lamp: '<path d="M9.500 15.500a5 5 0 1 1 5 0V17h-5z"/><path d="M10 20h4"/>',
    radio: '<path d="M12 12v9M8.500 21h7"/><circle cx="12" cy="9.500" r="1.500"/><path d="M8.800 6.800a5 5 0 0 0 0 5.400M15.200 6.800a5 5 0 0 1 0 5.400M6.300 4.800a8.500 8.500 0 0 0 0 9.400M17.700 4.800a8.500 8.500 0 0 1 0 9.400"/>',
    tank: '<path d="M6 6c0-1.700 2.700-3 6-3s6 1.300 6 3v12c0 1.700-2.700 3-6 3s-6-1.300-6-3z"/><path d="M6 6c0 1.700 2.700 3 6 3s6-1.300 6-3M6 12c0 1.700 2.700 3 6 3s6-1.300 6-3"/>',
    rain: '<path d="M7 14.500a4 4 0 0 1-.4-8A5.500 5.500 0 0 1 17 7.500a3.500 3.500 0 0 1 0 7z"/><path d="M8.500 17.500l-1 2.500M12.500 17.500l-1 2.500M16.500 17.500l-1 2.500"/>',
    cloud: '<path d="M7 18a4.500 4.500 0 0 1-.5-9A6 6 0 0 1 18 10.200 3.900 3.900 0 0 1 17 18z"/>',
    storm: '<path d="M7 14a4 4 0 0 1-.4-8A5.500 5.500 0 0 1 17 7a3.500 3.500 0 0 1 .5 7"/><path d="M12.500 11l-2.500 4h3l-2 4"/>',
    clear: '<circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.600 5.600L7 7M17 17l1.400 1.400M5.600 18.400L7 17M17 7l1.400-1.400"/>',
    cross: '<path d="M9.500 4h5v5.500H20v5h-5.500V20h-5v-5.500H4v-5h5.500z"/>',
    pill: '<rect x="3.500" y="8.500" width="17" height="7" rx="3.500" transform="rotate(-45 12 12)"/><path d="M9.700 9.700l4.600 4.600"/>',
    bandage: '<rect x="3" y="8.500" width="18" height="7" rx="3.500" transform="rotate(-35 12 12)"/><path d="M10.200 10.200l3.600 3.600M13 9.500l1.200 1.200M9.800 13.300L11 14.500"/>',
    gun: '<path d="M4 8.500h14v3.800h-5l-.8 4.700H8.600l.9-4.700H4z"/><path d="M17 8.500V7"/>',
    knife: '<path d="M5 19.500l10-10 4.500-4.500.5 4.800-6 6.200-3 .5z"/><path d="M5 19.500l3.500-3.500"/>',
    bat: '<path d="M4 20l9.500-9.500"/><path d="M12.500 8.500l3-3a2.800 2.800 0 0 1 4 4l-3 3z"/>',
    ammo: '<path d="M9 20v-8c0-2.500 1.200-4.500 3-6.500 1.800 2 3 4 3 6.500v8z"/><path d="M9 17h6"/>',
    fuel: '<path d="M7 7.500V20h10V9l-3-3.500H9z"/><path d="M9 5.500V3.500h3"/><circle cx="12" cy="14.500" r="2"/>',
    can: '<path d="M6.500 5.500c0 1.100 2.500 2 5.500 2s5.500-.9 5.500-2-2.500-2-5.500-2-5.500.9-5.500 2z"/><path d="M6.500 5.500v13c0 1.100 2.500 2 5.500 2s5.500-.9 5.500-2v-13M6.500 11c0 1.100 2.500 2 5.500 2s5.500-.9 5.500-2"/>',
    bottle: '<path d="M10 3h4v3l1.500 3v10.500a1.500 1.500 0 0 1-1.500 1.500h-4a1.500 1.500 0 0 1-1.500-1.500V9L10 6z"/><path d="M8.500 12.500h7"/>',
    gear: '<circle cx="12" cy="12" r="2.800"/><circle cx="12" cy="12" r="6.200"/><path d="M12 3.200v2.600M12 18.200v2.600M3.200 12h2.600M18.200 12h2.600M5.800 5.800l1.800 1.800M16.400 16.400l1.800 1.800M5.800 18.200l1.800-1.800M16.400 7.600l1.800-1.800"/>',
    map: '<path d="M4 6.500l5-2 6 2 5-2v13l-5 2-6-2-5 2z"/><path d="M9 4.500v13M15 6.500v13"/>',
    list: '<path d="M8.500 6.500H20M8.500 12H20M8.500 17.500H20"/><circle cx="4.700" cy="6.500" r=".9" fill="currentColor"/><circle cx="4.700" cy="12" r=".9" fill="currentColor"/><circle cx="4.700" cy="17.500" r=".9" fill="currentColor"/>',
    play: '<path d="M8 5.500v13l11-6.500z" fill="currentColor"/>',
    pause: '<path d="M8.500 5.500v13M15.500 5.500v13" stroke-width="3"/>',
    ff: '<path d="M4.500 6v12l7-6zM12.500 6v12l7-6z" fill="currentColor"/>',
    fff: '<path d="M3 6v12l5.500-6zM9.500 6v12l5.500-6zM16 6v12l5-6z" fill="currentColor"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>',
    chev: '<path d="M9 5.500l6.500 6.500L9 18.500"/>',
    chevd: '<path d="M5.500 9l6.500 6.500L18.500 9"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    minus: '<path d="M5 12h14"/>',
    check: '<path d="M5 12.500l4.500 4.500L19 7"/>',
    lock: '<rect x="5.500" y="10.500" width="13" height="9.500" rx="2"/><path d="M8.500 10.500V8a3.500 3.500 0 0 1 7 0v2.500"/>',
    target: '<circle cx="12" cy="12" r="8"/><circle cx="12" cy="12" r="3.500"/>',
    cross2: '<circle cx="12" cy="12" r="6"/><path d="M12 3v4M12 17v4M3 12h4M17 12h4"/>',
    truck: '<path d="M3 6.500h11v9.500H3zM14 9.500h4l3 3.500v3h-7z"/><circle cx="7.500" cy="17.500" r="1.800"/><circle cx="17" cy="17.500" r="1.800"/>',
    flag: '<path d="M6 21V4M6 5h11l-2.200 3.500L17 12H6"/>',
    star: '<path d="M12 3.500l2.600 5.400 5.900.8-4.300 4.100 1 5.800L12 16.800l-5.200 2.800 1-5.800L3.500 9.700l5.900-.8z"/>',
    trade: '<path d="M5 8h13l-3-3M19 16H6l3 3"/>',
    save: '<path d="M5 4h11l3 3v13H5z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
    bars: '<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M4 9.300h16M4 14.700h16M9.300 4v16M14.700 4v16"/>',
    layers: '<path d="M12 4l8.500 4.500L12 13 3.500 8.500zM3.500 12.500L12 17l8.500-4.500M3.500 16L12 20.500 20.500 16"/>',
    radar: '<circle cx="12" cy="12" r="8.500"/><circle cx="12" cy="12" r="4.500"/><path d="M12 12l5.200-5.200"/>',
    ghost: '<rect x="4" y="4" width="16" height="16" rx="1.500" stroke-dasharray="3.200 2.600"/><path d="M8.500 12h7M12 8.500v7"/>',
    zone: '<rect x="3.500" y="3.500" width="17" height="17" rx="2" stroke-dasharray="3.200 2.600"/><path d="M8.500 15.500v-3.800L12 9.500l3.500 2.200v3.800z"/>',
    cursor: '<path d="M6 4l11.500 7.200-5 1.300-2.700 4.800z"/>',
    swords: '<path d="M5 5l10 10M19 5L9 15M13.500 15.500l3 3M10.500 15.500l-3 3M3.800 17l2.700 2.700M20.200 17l-2.700 2.700"/>',
    zzz: '<path d="M6 6.500h5L6 13h5M13.500 12h4.500l-4.500 6H18.500"/>',
    pot: '<path d="M5 10.500h14v5.500a3 3 0 0 1-3 3H8a3 3 0 0 1-3-3z"/><path d="M3.500 10.500h17M9 7c0-1.200 1-1.200 1-2.500M14 7c0-1.200 1-1.200 1-2.500"/>',
    search: '<circle cx="10.500" cy="10.500" r="5.500"/><path d="M15 15l5 5"/>',
    info: '<circle cx="12" cy="12" r="8.500"/><path d="M12 11v5.500M12 7.800v.2"/>',
    trash: '<path d="M5 7h14M9.500 7V4.500h5V7M7 7l1 13h8l1-13M10.500 11v5.500M13.500 11v5.500"/>',
    eye: '<path d="M2.500 12S6 5.500 12 5.500 21.500 12 21.500 12 18 18.500 12 18.500 2.500 12 2.500 12z"/><circle cx="12" cy="12" r="2.800"/>',
    up: '<path d="M6 14.500l6-6 6 6"/>',
    down: '<path d="M6 9.500l6 6 6-6"/>',
    undo: '<path d="M9 8.500H15a4.500 4.500 0 0 1 0 9H8M9 8.500l3-3M9 8.500l3 3"/>',
    wave: '<path d="M3 12c2-3.500 4-3.500 6 0s4 3.500 6 0 4-3.500 6 0"/>',
    helmet: '<path d="M5 14a7 7 0 0 1 14 0v2H5zM5 16v3h14v-3"/>',
    scope: '<circle cx="12" cy="12" r="7.500"/><path d="M12 2.500v5M12 16.500v5M2.500 12h5M16.500 12h5"/>',
    pin: '<path d="M12 21s6.500-6 6.500-11a6.500 6.500 0 0 0-13 0C5.500 15 12 21 12 21z"/><circle cx="12" cy="10" r="2.300"/>',
    run: '<circle cx="14.500" cy="5" r="2"/><path d="M9 20l2.500-5-2-2 1.500-4.500 4 .5 2.500 3.500M8 11l-3 2M15 17l-2-2.200"/>',
    mask: '<path d="M4 8c3-2 5.500-2.500 8-2.500s5 .5 8 2.500c0 5.500-2.200 9.500-8 11.500C6.200 17.500 4 13.500 4 8z"/><path d="M8 11.200h2M14 11.200h2M9.500 15.500h5"/>',
  };
  OB.iconNames = Object.keys(P);
  const NS = 'http://www.w3.org/2000/svg';
  const sprite = document.createElementNS(NS, 'svg');
  sprite.setAttribute('width', '0'); sprite.setAttribute('height', '0'); sprite.setAttribute('aria-hidden', 'true');
  sprite.style.cssText = 'position:absolute;width:0;height:0;overflow:hidden';
  sprite.innerHTML = '<defs>' + Object.keys(P).map(k =>
    '<symbol id="i-' + k + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' + P[k] + '</symbol>').join('') + '</defs>';
  document.body.prepend(sprite);

  OB.icon = function (name, cls) {
    if (!P[name]) name = 'info';
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('class', 'ic' + (cls ? ' ' + cls : ''));
    svg.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS(NS, 'use');
    use.setAttribute('href', '#i-' + name);
    svg.appendChild(use);
    return svg;
  };

  // icon for an item id / blueprint / work type / job, by best match
  const ITEM_ICON = {
    water_bottle: 'bottle', soda_can: 'can', canned_beans: 'can', canned_veg: 'can', canned_fruit: 'can', bandage: 'bandage', first_aid_kit: 'cross', surgical_kit: 'cross',
    antibiotics: 'pill', painkillers: 'pill', baseball_bat: 'bat', crowbar: 'bat', machete: 'knife', pistol: 'gun', shotgun: 'gun', rifle: 'scope', fuel_can: 'fuel', firewood: 'fire',
    toolbox: 'wrench', jewelry: 'star', radio_set: 'radio', electronics: 'bolt', rice_bag: 'food', cooked_rice: 'pot', stew: 'pot', ration_pack: 'food', energy_bar: 'food',
    dried_meat: 'food', cloth_scrap: 'layers', scrap_wood: 'floor', scrap_metal: 'gear', nails: 'wrench', sandbag: 'weight', wire: 'wave', concrete_bag: 'weight', duct_tape: 'bandage',
  };
  const CAT_ICON = { food: 'food', drink: 'bottle', medical: 'cross', weapon: 'gun', ammo: 'ammo', material: 'gear', fuel: 'fuel', tool: 'wrench', valuable: 'star', ingredient: 'food',
    structure: 'floor', defense: 'shield', furniture: 'bed', production: 'fire', power: 'bolt', storage: 'crate', water: 'drop', utility: 'lamp' };
  OB.itemIcon = id => ITEM_ICON[id] || CAT_ICON[OB.item(id).cat] || 'crate';
  OB.catIcon = cat => CAT_ICON[cat] || 'crate';
  OB.bpIcon = id => ({ floor: 'floor', wall: 'wall', door: 'door', barricade: 'barricade', bed: 'bed', campfire: 'fire', workbench: 'wrench', stove: 'stove', generator: 'gen', watchtower: 'tower',
    crate: 'crate', rain_collector: 'rain', water_tank: 'tank', medical_bed: 'cross', lamp: 'lamp', radio_mast: 'radio' }[id] || 'crate');
  OB.workIcon = w => ({ doctor: 'cross', guard: 'shield', build: 'hammer', cook: 'pot', craft: 'wrench', haul: 'crate', scavenge: 'search' }[w] || 'gear');
  OB.jobIcon = j => ({ goto: 'run', haul: 'crate', deliver: 'crate', unload: 'crate', build: 'hammer', repair: 'hammer', cook: 'pot', craft: 'wrench', tend: 'cross', medicate: 'pill', amputate: 'cross',
    feed: 'food', guard: 'shield', scavenge: 'search', refuel: 'fuel', eat: 'food', drink: 'drop', sleep: 'zzz', rest: 'zzz', binge: 'food', wander: 'run', draft: 'swords', equip: 'gun', idle: 'person', away: 'truck', downed: 'heart' }[j] || 'person');
  OB.weatherIcon = k => (k === 'storm' ? 'storm' : k === 'rain' ? 'rain' : 'clear');
})();
