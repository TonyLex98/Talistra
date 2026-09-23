"""Rebuild the bundled instruction guide from its HTML source.

The guide is authored as an A4 HTML page per section and printed by headless
Chrome, which is the same pipeline the shipped file came from. Run this after
editing talistra_guide.html or tool/instructions_screenshots/, then bump
`instructions_seeded_v*` in lib/services/settings_service.dart so installed
apps pick the new file up.
"""

import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
OUTPUT = HERE.parent.parent / 'assets' / 'instructions' / 'talistra_guide.pdf'
BROWSERS = [
    Path(r'C:/Program Files/Google/Chrome/Application/chrome.exe'),
    Path(r'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe'),
    Path(r'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe'),
    Path(r'C:/Program Files/Microsoft/Edge/Application/msedge.exe'),
]


def main():
    browser = next((path for path in BROWSERS if path.exists()), None)
    if browser is None:
        sys.exit('Chrome or Edge is required to print the guide.')
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            str(browser),
            '--headless=new',
            '--disable-gpu',
            '--no-first-run',
            '--no-pdf-header-footer',
            '--virtual-time-budget=15000',
            f'--print-to-pdf={OUTPUT.resolve()}',
            (HERE / 'talistra_guide.html').resolve().as_uri(),
        ],
        check=True,
    )
    print(f'{OUTPUT} rewritten: {OUTPUT.stat().st_size} bytes')


if __name__ == '__main__':
    main()
