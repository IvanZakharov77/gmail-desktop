// Packages "Gmail Desktop.app" (universal: Apple silicon + Intel), locks down
// Electron's runtime switches, signs ad hoc and zips it for sharing.
import { packager } from '@electron/packager';
import { flipFuses, FuseVersion, FuseV1Options } from '@electron/fuses';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const root = path.dirname(new URL(import.meta.url).pathname);
const [outDir] = await packager({
  dir: root,
  name: 'Gmail Desktop',
  executableName: 'Gmail Desktop',
  appBundleId: 'com.ivanzakharov.gmail-desktop',
  appCategoryType: 'public.app-category.productivity',
  appVersion: '2.0.0',
  icon: path.join(root, '..', 'Resources', 'AppIcon.icns'),
  platform: 'darwin',
  arch: 'universal',
  // Build outside the iCloud-synced Desktop, which adds file attributes that break signing.
  out: path.join(os.homedir(), 'Library', 'Caches', 'gmail-desktop-build'),
  overwrite: true,
  asar: true,
  prune: true,
  protocols: [{ name: 'Email Address', schemes: ['mailto'] }],
  ignore: [/^\/build\.mjs$/],
  extendInfo: { LSMinimumSystemVersion: '12.0' },
});

const app = path.join(outDir, 'Gmail Desktop.app');
await flipFuses(path.join(app, 'Contents', 'MacOS', 'Gmail Desktop'), {
  version: FuseVersion.V1,
  [FuseV1Options.RunAsNode]: false,
  [FuseV1Options.EnableCookieEncryption]: true,
  [FuseV1Options.EnableNodeOptionsEnvironmentVariable]: false,
  [FuseV1Options.EnableNodeCliInspectArguments]: false,
  [FuseV1Options.EnableEmbeddedAsarIntegrityValidation]: true,
  [FuseV1Options.OnlyLoadAppFromAsar]: true,
  [FuseV1Options.GrantFileProtocolExtraPrivileges]: false,
});

execFileSync('xattr', ['-cr', app]);
execFileSync('codesign', ['--force', '--deep', '--sign', '-', app], { stdio: 'inherit' });

const zip = path.join(root, '..', 'Gmail Desktop (Chrome).zip');
fs.rmSync(zip, { force: true });
execFileSync('ditto', ['-c', '-k', '--keepParent', app, zip], { stdio: 'inherit' });
execFileSync('codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });

if (process.argv.includes('--install')) {
  const target = '/Applications/Gmail Desktop (Chrome).app';
  fs.rmSync(target, { recursive: true, force: true });
  execFileSync('ditto', [app, target], { stdio: 'inherit' });
  console.log(`Installed ${target}`);
}
console.log(`Built ${app}\nZipped ${zip}`);
