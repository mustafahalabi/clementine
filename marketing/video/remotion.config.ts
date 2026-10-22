import {Config} from '@remotion/cli/config';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

// Use an already-installed Chrome Headless Shell when one exists (Playwright's cache), else let Remotion download one.
const cache = path.join(os.homedir(), 'Library/Caches/ms-playwright');
const shell = fs.existsSync(cache)
  ? fs.readdirSync(cache).filter((d) => d.startsWith('chromium_headless_shell')).sort().reverse()
      .map((d) => path.join(cache, d, 'chrome-headless-shell-mac-arm64', 'chrome-headless-shell')).find((p) => fs.existsSync(p))
  : undefined;
if (process.env.REMOTION_BROWSER ?? shell) Config.setBrowserExecutable((process.env.REMOTION_BROWSER ?? shell)!);
Config.setVideoImageFormat('jpeg');
Config.setJpegQuality(95);
Config.setConcurrency(8);
