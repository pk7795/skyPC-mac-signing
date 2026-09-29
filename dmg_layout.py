#!/usr/bin/env python3
"""Verify Finder-created DMG layout and background acceptance.

Finder writes the authoritative alias and bookmark records on the writable
image. This verifier reads the resulting metadata without modifying it.
"""
import argparse
import math
from pathlib import Path
import re
import subprocess

from ds_store import DSStore
import ds_store.store as ds_store_store
from mac_alias import Alias


VOLUME_NAME = 'SkyPC'
BACKGROUND_RELATIVE_PATH = '.background/background.tiff'

# Finder may split a bookmark across pBBk/pBB0 records. The pinned ds_store
# codec assumes pBBk is always a complete bookmark and rejects Finder's split
# form before callers can inspect it, so read these records as raw blobs.
ds_store_store.codecs.pop(b'pBBk', None)


def verify_image(background: Path, width: int, height: int) -> None:
    result = subprocess.run(
        ['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', '-g', 'dpiWidth', '-g', 'dpiHeight', str(background)],
        text=True, capture_output=True, check=True,
    )
    properties = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.strip().partition(': ')
        if separator and key in ('pixelWidth', 'pixelHeight', 'dpiWidth', 'dpiHeight'):
            properties[key] = float(value)
    for pixels, dpi, expected in (('pixelWidth', 'dpiWidth', width), ('pixelHeight', 'dpiHeight', height)):
        if properties.get(pixels, 0) <= 0 or properties.get(dpi, 0) <= 0:
            raise ValueError('Missing or invalid background image dimensions/DPI')
        logical_size = properties[pixels] * 72 / properties[dpi]
        if not math.isclose(logical_size, expected, rel_tol=0, abs_tol=0.05):
            raise ValueError(f'Background logical size {logical_size:g} does not match canvas {expected}')


def verify(mount: Path, width: int, height: int, volume_name: str = VOLUME_NAME) -> None:
    with DSStore.open(str(mount / '.DS_Store'), 'r') as store:
        records = list(store.find('.'))
        bookmarks = [record for record in records if record.code in (b'pBBk', b'pBB0')]
        if not bookmarks or not all(isinstance(record.value, (bytes, bytearray)) and record.value for record in bookmarks):
            raise ValueError('Finder did not confirm the background with a bookmark record')

        options = store['.']['icvp']
        if options['backgroundType'] != 2 or options['iconSize'] != 96:
            raise ValueError('Missing picture background or incorrect icon size')
        alias = Alias.from_bytes(options['backgroundImageAlias'])
        relative_path = alias.target.posix_path.lstrip('/')
        if relative_path != BACKGROUND_RELATIVE_PATH:
            raise ValueError('Background alias is not relative to the image volume')
        if alias.volume.name != volume_name:
            raise ValueError('Background alias belongs to a different volume')
        background = mount / relative_path
        if not background.is_file():
            raise ValueError('Background target is missing')
        if alias.target.cnid != background.stat().st_ino:
            raise ValueError('Background alias does not identify the packaged file')
        verify_image(background, width, height)

        window = store['.']['bwsp']
        bounds = re.fullmatch(r'\{\{(-?\d+), (-?\d+)\}, \{(\d+), (\d+)\}\}', window['WindowBounds'])
        if not bounds or (int(bounds.group(3)), int(bounds.group(4))) != (width, height):
            raise ValueError('Window dimensions mismatch')
        if window['ShowToolbar'] or window['ShowStatusBar'] or window['ShowSidebar']:
            raise ValueError('Window chrome must not obscure the background')
        if store['SkyPC.app']['Iloc'] != (round(width * 0.27), round(height * 0.48)):
            raise ValueError('SkyPC position mismatch')
        if store['Applications']['Iloc'] != (round(width * 0.73), round(height * 0.48)):
            raise ValueError('Applications position mismatch')
    print(f'PASS: Finder-confirmed background bookmark, layout {width}x{height}, matching image logical size and icon positions')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('verify',))
    parser.add_argument('mount', type=Path)
    parser.add_argument('width', type=int)
    parser.add_argument('height', type=int)
    parser.add_argument('--volume-name', default=VOLUME_NAME)
    args = parser.parse_args()
    if not (600 <= args.width <= 900 and 300 <= args.height <= 700):
        parser.error('Unsupported installer dimensions')
    verify(args.mount, args.width, args.height, args.volume_name)


if __name__ == '__main__':
    main()
