#!/usr/bin/env python3
"""Render original directory screenshots and a silent 30s vertical walkthrough.

Optional: Playwright + Chromium and FFmpeg. No creator/game footage is downloaded.
This renders the project's own generated HTML in memory; it does not navigate to
external sites, record private browser state or reuse creator gameplay clips.
"""
import argparse, json, re, shutil, subprocess
from pathlib import Path
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/promo')
    parser.add_argument('--chromium',help='Optional installed browser executable')
    args=parser.parse_args();out=args.output;out.mkdir(parents=True,exist_ok=True)
    stats=json.loads((ROOT/'_site/build-info.json').read_text());n=stats['total']
    css=(ROOT/'site/style.css').read_text();js=(ROOT/'site/app.js').read_text()
    def render(page,path='index.html',run_js=True):
        text=(ROOT/'_site'/path).read_text()
        # Inline the owned assets for a deterministic, offline rendering context.
        text=re.sub(r'<meta http-equiv="Content-Security-Policy"[^>]+>','',text)
        text=re.sub(r'<link\b[^>]+>','',text)
        text=re.sub(r'<script.*?</script>','',text,flags=re.S)
        page.set_content(text);page.add_style_tag(content=css)
        if run_js:page.add_script_tag(content=js)
    def title(page,headline,sub):
        page.set_content('<html><head><meta charset="utf-8"></head><body><div class="cover"><div class="brandmark">M×</div><p class="eyebrow">AWESOME GAME MASHUPS</p><h1>'+headline+'</h1><p class="lede">'+sub+'</p><p class="address">github.com/bailo167/<br><strong>awesome-game-mashups</strong></p><p class="small">Directory walkthrough / website preview<br>Original catalogue UI — not gameplay footage</p></div></body></html>')
        page.add_style_tag(content=css+'body{padding:55px 34px}.cover{min-height:835px;display:flex;flex-direction:column;justify-content:center}.cover h1{font-size:62px;letter-spacing:-.05em;line-height:1.04;margin:20px 0 26px}.cover .brandmark{margin-bottom:30px}.cover .lede{font-size:23px}.address{margin-top:55px;font-size:22px;color:var(--accent)}.small{font-size:13px;color:var(--muted);margin-top:auto;padding-top:40px}')
    with sync_playwright() as p:
        opts={'headless':True}
        if args.chromium:opts['executable_path']=args.chromium
        browser=p.chromium.launch(**opts);page=browser.new_page(viewport={'width':540,'height':960},device_scale_factor=2)
        # Block any unexpected network request; all material is local catalogue UI.
        page.route('**/*',lambda route:route.abort())
        title(page,'Games inside<br><em>other games.</em>',f'{n} catalogue entries.<br>Releases. Source code. Demos.<br>Clear labels for what is available.')
        page.screenshot(path=str(out/'01.png'))
        render(page);page.locator('#featured').scroll_into_view_if_needed();page.screenshot(path=str(out/'02.png'))
        render(page);page.locator('#search').fill('skate');page.locator('#browse').scroll_into_view_if_needed();page.screenshot(path=str(out/'03.png'))
        page.locator('#reset').click();page.locator('#demo').check();page.locator('#browse').scroll_into_view_if_needed();page.screenshot(path=str(out/'04.png'))
        render(page,'projects/killcraft/index.html',False);page.screenshot(path=str(out/'05.png'))
        title(page,'Find it.<br>Watch it.<br><em>Go to the source.</em>','Made a mashup?<br>Send the project and demo link.<br>Corrections are welcome.');page.screenshot(path=str(out/'06.png'))
        social=browser.new_page(viewport={'width':1280,'height':640},device_scale_factor=1)
        social.route('**/*',lambda route:route.abort())
        social.set_content(f'<html><head><meta charset="utf-8"></head><body><div class="cover"><p class="eyebrow">AWESOME GAME MASHUPS</p><h1>Games where<br>they don’t <em>belong.</em></h1><p class="lede">A source-backed directory of cross-game projects.</p><div class="tags">Releases &nbsp; / &nbsp; Source code &nbsp; / &nbsp; Creator demos &nbsp; / &nbsp; WIPs</div><p class="url">github.com/bailo167/awesome-game-mashups</p></div><aside><div class="brandmark">M×</div><b>{n}</b><span>CATALOGUE ENTRIES</span><small>Availability clearly labelled.<br>Not all entries are verified releases.</small></aside></body></html>')
        social.add_style_tag(content=css+'body{display:flex;padding:62px 64px;gap:60px}.cover{flex:1}h1{font-size:69px;letter-spacing:-.055em;margin:20px 0 25px}.lede{font-size:21px}.tags{font-size:17px;color:var(--teal);padding:16px 0}.url{font-size:18px;margin-top:29px;color:var(--accent)}aside{width:240px;display:flex;flex-direction:column;align-items:center;border-left:1px solid var(--line);padding-left:44px}aside>b{font-size:120px;line-height:1.4;color:var(--accent);letter-spacing:-.07em}aside>span{font-size:12px;font-weight:bold;letter-spacing:.1em}aside>small{text-align:center;font-size:12px;color:var(--muted);margin-top:30px}.brandmark{width:68px;height:68px;font-size:35px}')
        social.screenshot(path=str(out/'social-preview.png'));browser.close()
    concat=''.join("file '"+str((out/f'{i:02}.png').resolve()).replace("'","'\\''")+"'\nduration 5\n" for i in range(1,7))
    concat+="file '"+str((out/'06.png').resolve()).replace("'","'\\''")+"'\n"
    (out/'frames.txt').write_text(concat)
    if not shutil.which('ffmpeg'):raise SystemExit('Screenshots saved. FFmpeg is required to assemble the video.')
    subprocess.run(['ffmpeg','-y','-hide_banner','-loglevel','error','-f','concat','-safe','0','-i',str(out/'frames.txt'),'-t','30','-vf','fps=30,format=yuv420p','-c:v','libx264','-preset','veryfast','-crf','22','-movflags','+faststart',str(out/'directory-walkthrough.mp4')],check=True)
    print(out)
if __name__=='__main__':main()
