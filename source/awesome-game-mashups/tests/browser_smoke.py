"""HTTP browser checks in a disposable read-only CI job."""
import functools,http.server,json,threading
from pathlib import Path
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass

def main():
    out=ROOT/'build/browser';out.mkdir(parents=True,exist_ok=True)
    handler=functools.partial(Quiet,directory=str(ROOT/'_site'))
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    base=f'http://127.0.0.1:{server.server_port}'
    data=json.loads((ROOT/'data/projects.json').read_text());report={'mode':'HTTP browser smoke tests','entries':len(data)}
    try:
        with sync_playwright() as p:
            browser=p.chromium.launch(headless=True)
            page=browser.new_page(viewport={'width':1440,'height':1000})
            errors=[];external=[]
            page.on('pageerror',lambda e:errors.append(str(e)))
            page.on('request',lambda r:external.append(r.url) if not r.url.startswith(base) else None)
            page.goto(base);page.screenshot(path=str(out/'desktop.png'))
            assert page.locator('#catalogue .project-card:visible').count()==len(data)
            page.locator('#search').fill('killcraft')
            assert page.locator('#catalogue .project-card:visible').count()==1
            assert 'q=killcraft' in page.url
            page.reload();assert page.locator('#search').input_value()=='killcraft'
            assert page.locator('#catalogue .project-card:visible').count()==1
            page.locator('#reset').click();page.locator('#status').select_option('watchlist')
            assert page.locator('#catalogue .project-card:visible').count()==sum(x['category']=='watchlist' for x in data)
            page.locator('#reset').click();page.locator('#demo').check()
            expected=sum(bool(x.get('media') or ('video-only' in x['status'] and x.get('creator_post'))) for x in data)
            assert page.locator('#catalogue .project-card:visible').count()==expected
            page.locator('#search').fill('zz-no-such-project-zz');assert page.locator('#no-results').is_visible()
            page.goto(base+'/projects/killcraft/');assert page.locator('h1').inner_text()=='Killcraft'
            assert page.locator('a:has-text("Source")').count()>0
            mobile=browser.new_page(viewport={'width':390,'height':844},device_scale_factor=2,is_mobile=True,has_touch=True)
            mobile.goto(base);mobile.screenshot(path=str(out/'mobile.png'))
            assert not mobile.evaluate('document.documentElement.scrollWidth > innerWidth')
            mobile.locator('#browse').scroll_into_view_if_needed();mobile.screenshot(path=str(out/'mobile-filter.png'))
            nojs=browser.new_page(java_script_enabled=False);nojs.goto(base)
            assert nojs.locator('#catalogue .project-card').count()==len(data)
            assert not nojs.locator('#filters').is_visible()
            assert not errors and not external,(errors,external)
            report.update(result='PASS',javascript_errors=errors,external_requests=external,demo_entries=expected);browser.close()
    except Exception as e:
        report.update(result='FAIL',error=str(e));raise
    finally:
        (out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));server.shutdown()
if __name__=='__main__': main()
