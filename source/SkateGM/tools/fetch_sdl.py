"""Download SDL2 and the SDL controller database into gm_skategm/prebuilt/.

    python tools/fetch_sdl.py

The module reads non-Xbox controllers (PlayStation, Switch Pro, generic pads)
through them; the release zip and the installer ship them next to the
module. Pinned versions, checked by SHA-256.
"""
import hashlib
import io
import os
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'gm_skategm', 'prebuilt')

SDL_TAG = 'release-2.32.10'
SDL_ZIP = 'https://github.com/libsdl-org/SDL/releases/download/%s/SDL2-2.32.10-win32-x64.zip' % SDL_TAG
SDL_ZIP_SHA = '6cf9706eefd0a4a06dc764007934d428afaf029fabdd408a9e646048c91e18fb'
SDL_LICENSE = 'https://raw.githubusercontent.com/libsdl-org/SDL/%s/LICENSE.txt' % SDL_TAG
DB_COMMIT = 'c1d5289a1f713b30a2c121e9fe6529d39360be0f'
DB = 'https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/%s/gamecontrollerdb.txt' % DB_COMMIT
DB_SHA = 'e606134678e6b3fdbdec9081289a1f0ba3e25d53b59b2aa3cdfe69bf491ad18f'
DB_LICENSE = 'https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/%s/LICENSE' % DB_COMMIT

# what ships next to the module (lua/bin), and the licences that go with it
FILES = ['skategm_sdl2.dll', 'skategm_gamecontrollerdb.txt']
LICENSES = ['SDL2-LICENSE.txt', 'SDL2-README.txt', 'SDL_GameControllerDB-LICENSE.txt']


def get(url, sha=None):
    data = urllib.request.urlopen(url, timeout=60).read()
    if sha and hashlib.sha256(data).hexdigest() != sha:
        raise SystemExit('%s: checksum mismatch' % url)
    return data


def write(name, data):
    with open(os.path.join(OUT, name), 'wb') as f:
        f.write(data)


def main():
    os.makedirs(OUT, exist_ok=True)
    z = zipfile.ZipFile(io.BytesIO(get(SDL_ZIP, SDL_ZIP_SHA)))
    write('skategm_sdl2.dll', z.read('SDL2.dll'))
    write('SDL2-README.txt', z.read('README-SDL.txt'))
    write('SDL2-LICENSE.txt', get(SDL_LICENSE))
    write('skategm_gamecontrollerdb.txt', get(DB, DB_SHA))
    write('SDL_GameControllerDB-LICENSE.txt', get(DB_LICENSE))
    print('SDL2 %s and the controller database (%s) in %s' % (SDL_TAG, DB_COMMIT[:8], OUT))


if __name__ == '__main__':
    main()
