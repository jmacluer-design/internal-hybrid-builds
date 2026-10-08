#!/usr/bin/env python3
"""Losslessly migrate legacy README fields into JSON. Idempotent; use full Git history."""
from __future__ import annotations
import argparse,copy,difflib,json,re,subprocess,unicodedata
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
URL_FIELDS=('source','release','media','creator_post','project_page','verification','latest_update','discussion','creator_url')
REVIEW_UPDATES={
'killcraft':{'platforms':['Windows'],'requirements':'The creator documents ULTRAKILL on Steam, BepInEx 5 x64 and an owned Minecraft Java Edition Microsoft account. First launch uses the bundled Prism setup to obtain Minecraft and Java; Skyrim is not required. ULTRAKILL movement and guns are replaced while Minecraft mode is enabled; F9 restores native mode.','review_note':'README documentation reviewed on 2026-10-05 (blob c4acfb61ca9802097c95a88fa3396e17f849a478). This confirms what the creator documents, not an independent play-test or binary safety check.'},
'skategm':{'platforms':['Windows'],'requirements':'Garry’s Mod on the x86-64 branch, a controller, and the user’s own Xbox 360 Skate 3 dump are required. The creator recommends disabling Steam Input if the controller does not respond. Each player who skates installs the mod locally.','review_note':'Requirements and implementation description reviewed in the creator README on 2026-10-05 (blob abafdc9c5132f6f380c803144908d497a0eedc5a). No independent play-test or binary safety check was performed.'},
'owcraft':{'platforms':['Windows'],'requirements':'Outer Wilds on Steam with its Mod Manager, an owned Minecraft Java Edition copy, Minecraft 26.3, Fabric Loader 0.19.5 or newer and the corresponding Fabric API. The creator describes testing on one Windows PC; broader compatibility is not established.','review_note':'README introduction and installation documentation reviewed on 2026-10-05 (blob b77929a99cb984ce1291b69960e71637deb739da). Creator testing is attributed to the creator, not recorded as a catalogue play-test.'}}
def normal(value): return re.sub(r'[^a-z0-9]','',unicodedata.normalize('NFKD',value).lower())
def addition_dates(root):
    found={}
    try:
        log=subprocess.check_output(['git','log','--reverse','--format=%H %cs','--','data/projects.json'],cwd=root,text=True,stderr=subprocess.DEVNULL)
        for row in log.splitlines():
            sha,date=row.split()
            data=json.loads(subprocess.check_output(['git','show',f'{sha}:data/projects.json'],cwd=root,text=True,stderr=subprocess.DEVNULL))
            for p in data: found.setdefault(p['name'],date)
    except (subprocess.CalledProcessError,ValueError,KeyError): pass
    return found

def migrate(projects,readme,dates):
    if all(p.get('id') for p in projects): return projects
    rows=re.findall(r'^\| \[([^\]]+)\]\(#project-([^)]+)\) \| (.*?) \| (.*?) \|$',readme.split('## Project details')[0],re.M)
    if len(rows)!=len(projects): raise ValueError(f'Legacy overview has {len(rows)} rows but JSON has {len(projects)} records')
    anchors=list(re.finditer(r'<a (?:name|id)="project-([^"]+)"></a>',readme));blocks={}
    for i,m in enumerate(anchors):
        block=readme[m.end():anchors[i+1].start() if i+1<len(anchors) else len(readme)]
        blocks[m[1]]=re.split(r'\n#{2,3} ',block)[0].strip()
    result=[];used=set()
    for original in projects:
        p=copy.deepcopy(original);name=normal(p['name'])
        def rank(row):
            label,ident,*_=row;n=normal(label);score=difflib.SequenceMatcher(None,name,n).ratio()
            if name==n: score+=10
            elif name.startswith(n) or n.startswith(name): score+=3
            if p.get('source') and p['source'] in blocks.get(ident,''): score+=2
            return score
        row=max(rows,key=rank);label,ident,summary,_=row
        if ident in used or ident not in blocks or rank(row)<0.60: raise ValueError(f'Ambiguous/missing legacy mapping: {p["name"]} -> {ident}')
        used.add(ident);block=blocks[ident]
        ls=[{'label':label,'url':url} for label,url in re.findall(r'^- \[([^\]]+)\]\((https?://[^\s)]+)\)',block,re.M)]
        body=[]
        for line in block.splitlines():
            if line.startswith(('#### ','**Guest','**Host','**Creator:','**Status:','**Approach:','**Why adjacent:','**Claim:','- [','[Back to','---')): continue
            body.append(line)
        description=re.sub(r'\n{3,}','\n\n','\n'.join(body)).strip()
        approach=re.search(r'^\*\*Approach:\*\* (.+)$',block,re.M);why=re.search(r'^\*\*Why adjacent:\*\* (.+)$',block,re.M)
        p.update(id=ident,summary=summary,description=description or p.get('notes',''),approach=approach[1].strip() if approach else None,added_at=dates.get(p['name']),reviewed_at=None,review_basis='legacy-record',platforms=[],requirements=None,playtest=None)
        if why: p['scope_note']=why[1].strip()
        creator_line=re.search(r'^\*\*Creator:\*\* (.+)$',block,re.M)
        creator_link=re.search(r'\]\((https?://[^)]+)\)',creator_line[1]) if creator_line else None
        if creator_link: p['creator_url']=creator_link[1]
        if not p.get('media'):
            demos=[l for l in ls if re.search(r'video|demo|trailer|showcase|gameplay',l['label'],re.I)]
            if demos: p['media']=demos[0]['url']
        known={p.get(k) for k in URL_FIELDS}
        p['extra_links']=[l for l in ls if l['url'] not in known]
        p['review_note']='Imported from the existing catalogue; a dated source review and local play-test are not asserted.'
        assert all(p[k]==v for k,v in original.items()),p['name']
        if ident in REVIEW_UPDATES:
            p.update(REVIEW_UPDATES[ident]);p.update(reviewed_at='2026-10-05',review_basis='primary-source-review')
        result.append(p)
    assert len(used)==len(projects)
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--root',type=Path,default=ROOT);args=parser.parse_args();root=args.root
    path=root/'data/projects.json';old=json.loads(path.read_text());new=migrate(old,(root/'README.md').read_text(),addition_dates(root))
    if new!=old:
        path.write_text(json.dumps(new,ensure_ascii=False,indent=2)+'\n');print(f'Migrated {len(new)} records; preserved all legacy JSON fields and detail anchors.')
    else: print('Catalogue already migrated; no changes.')
if __name__=='__main__': main()
