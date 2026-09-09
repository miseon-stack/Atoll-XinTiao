#!/usr/bin/env node
// Assemble a local, ad-hoc-signed beta. Never installs, launches, uploads or publishes.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync, spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
if (args.length !== 6) {
  console.error('Usage: node scripts/package-beta.mjs APP SOURCE_TAR SOURCE_PACKAGES OUTPUT_DIR LABEL BASE_COMMIT');
  process.exit(64);
}
const [appArg, archiveArg, packagesArg, outputArg, label, baseCommit] = args;
if (!/^\d+\.\d+\.\d+-beta\.\d+$/.test(label) || !/^[a-f0-9]{40}$/.test(baseCommit)) throw Error('Invalid release label or source commit.');
const inputApp = fs.realpathSync(appArg);
const archive = fs.realpathSync(archiveArg);
const packages = fs.realpathSync(packagesArg);
const output = path.resolve(outputArg);
if (!inputApp.endsWith('/Work Tempo.app') || !archive.endsWith('.tar')) throw Error('Expected a separately built Work Tempo.app and a frozen source tar.');
// An exclusive new directory prevents overwriting earlier packages or user files.
fs.mkdirSync(output);
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'work-tempo-package-')));
const volume = path.join(scratch, 'volume');
fs.mkdirSync(volume);
const app = path.join(volume, 'Work Tempo.app');
const run = (command, argv, options = {}) => execFileSync(command, argv, {encoding:'utf8', maxBuffer:16*1024*1024, ...options});
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const plist = file => JSON.parse(run('/usr/bin/plutil', ['-convert', 'json', '-o', '-', file]));
const copy = (from, to) => run('/usr/bin/ditto', ['--norsrc', '--noextattr', '--noqtn', from, to]);
function walk(directory) {
  return fs.readdirSync(directory, {withFileTypes:true}).flatMap(entry => {
    const full = path.join(directory, entry.name);
    return entry.isDirectory() ? [full, ...walk(full)] : [full];
  });
}
const magics = new Set(['cffaedfe','cefaedfe','feedfacf','feedface','cafebabe','bebafeca','cafebabf','bfbafeca']);
function isMachO(file) {
  if (!fs.lstatSync(file).isFile()) return false;
  const handle = fs.openSync(file, 'r');
  const bytes = Buffer.alloc(4);
  try { fs.readSync(handle, bytes, 0, 4, 0); } finally { fs.closeSync(handle); }
  return magics.has(bytes.toString('hex'));
}

copy(inputApp, app);
const info = plist(path.join(app, 'Contents/Info.plist'));
if (info.CFBundleName !== 'Work Tempo' || info.CFBundleIconName !== 'AppIcon') throw Error('Refusing a development or misbranded application.');
if (info.CFBundleIdentifier !== 'com.Ebullioscopic.Atoll') throw Error('Unexpected Release identity; evaluate migration before changing it.');
if (!label.startsWith(info.CFBundleShortVersionString + '-beta.')) throw Error('Label and application version do not match.');
const executable = path.join(app, 'Contents/MacOS', info.CFBundleExecutable);
if (run('/usr/bin/lipo', ['-archs', executable]).trim() !== 'arm64') throw Error('This packaging profile supports arm64 only.');
if (fs.existsSync(path.join(app, 'Contents/MacOS/Work Tempo.debug.dylib'))) throw Error('Debug application is not distributable.');

const licenses = path.join(app, 'Contents/Resources/Licenses');
fs.mkdirSync(licenses, {recursive:true});
for (const name of ['LICENSE','NOTICE','COPYRIGHT_ASSETS','TRADEMARKS']) copy(path.join(root,name), path.join(licenses,name));
for (const entry of fs.readdirSync(path.join(packages,'checkouts'), {withFileTypes:true})) {
  if (!entry.isDirectory()) continue;
  const directory = path.join(packages, 'checkouts', entry.name);
  for (const file of fs.readdirSync(directory)) {
    if (/^(license|copying|notice)(\..*)?$/i.test(file) && fs.statSync(path.join(directory,file)).isFile()) {
      copy(path.join(directory,file), path.join(licenses,entry.name,file));
    }
  }
}

// Inspect the payload only. No user's Application Support, Preferences or Keychain is read.
const forbidden = /^(?:\.env(?:\..*)?|\.git|\.DS_Store|.*\.(?:p12|pfx|pem|key|mobileprovision)|launcher-config(?:\.backup)?\.json|launcher-ui-preferences(?:\.backup)?\.json|configuration-v1\.json|HANDOFF\.md|DECISIONS\.md|AGENTS\.md)$/i;
for (const file of walk(app)) {
  if (forbidden.test(path.basename(file))) throw Error(`Forbidden payload: ${path.relative(app,file)}`);
  if (fs.lstatSync(file).isSymbolicLink()) {
    const resolved = fs.realpathSync(file);
    if (!resolved.startsWith(app + path.sep)) throw Error('Application contains an external symlink.');
  }
}
const binaries = walk(app).filter(isMachO);
for (const binary of binaries) {
  if (!run('/usr/bin/lipo',['-archs',binary]).trim().split(/\s+/).includes('arm64')) throw Error('A nested binary is missing arm64.');
  // Universal frameworks print an unindented heading for each architecture.
  const dependencies = run('/usr/bin/otool',['-L',binary]).split('\n').filter(line => /^\s+\S/.test(line))
    .map(line => line.trim().split(' (')[0]).filter(Boolean);
  for (const dependency of dependencies) {
    if (!/^(?:@rpath\/|@loader_path\/|@executable_path\/|\/System\/Library\/|\/usr\/lib\/)/.test(dependency)) {
      throw Error(`Non-portable dependency in ${path.relative(app,binary)}: ${dependency}`);
    }
  }
  run('/usr/bin/codesign',['--force','--sign','-','--preserve-metadata=identifier,entitlements',binary]);
}
const bundles = walk(app).filter(file => fs.lstatSync(file).isDirectory() && /\.(framework|xpc|app)$/.test(file))
  .sort((a,b) => b.split(path.sep).length-a.split(path.sep).length);
for (const bundle of bundles) run('/usr/bin/codesign',['--force','--sign','-','--preserve-metadata=identifier,entitlements',bundle]);
const entitlementFile = path.join(scratch,'beta.entitlements');
const entitlements = fs.readFileSync(path.join(root,'DynamicIsland/DynamicIsland.entitlements'),'utf8')
  .replaceAll('$(PRODUCT_BUNDLE_IDENTIFIER)',info.CFBundleIdentifier);
fs.writeFileSync(entitlementFile, entitlements);
run('/usr/bin/codesign',['--force','--sign','-','--options','runtime','--entitlements',entitlementFile,app]);
run('/usr/bin/codesign',['--verify','--deep','--strict',app]);
fs.symlinkSync('/Applications',path.join(volume,'Applications'));
copy(path.join(root,'docs/beta-installation.md'),path.join(volume,'安装与试用说明.txt'));
copy(path.join(root,'docs/beta-installation.md'),path.join(output,'安装与试用说明.md'));

// Include the exact frozen application sources alongside the binary, not the live worktree.
const sourceDirectory = path.join(scratch,`WorkTempo-${label}-source`);
fs.mkdirSync(sourceDirectory);
run('/usr/bin/tar',['-xf',archive,'-C',sourceDirectory]);
for (const name of ['scripts/package-beta.mjs','docs/beta-installation.md','docs/beta-release-runbook.md']) {
  copy(path.join(root,name),path.join(sourceDirectory,name));
}
const manifest = {
  product:'Work Tempo', label, version:info.CFBundleShortVersionString, build:info.CFBundleVersion,
  architecture:'arm64', minimumOS:info.LSMinimumSystemVersion,
  bundleIdentifier:info.CFBundleIdentifier, signature:'ad-hoc', notarized:false,
  publicReleaseApprovedAfterCleanMacTest:false, sourceBaseCommit:baseCommit,
  sourceSnapshotSHA256:sha(archive), sourceContainsUncommittedEntranceFix:true,
  dependencyPins:JSON.parse(fs.readFileSync(path.join(sourceDirectory,'DynamicIsland.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'),'utf8')).pins,
  builtWith:run('/usr/bin/xcodebuild',['-version']).trim(), createdAt:new Date().toISOString()
};
fs.writeFileSync(path.join(sourceDirectory,'BETA_BUILD.json'),JSON.stringify(manifest,null,2)+'\n');
const sourceZip = path.join(output,`WorkTempo-${label}-source.zip`);
run('/usr/bin/ditto',['-c','-k','--keepParent','--norsrc','--noextattr','--noqtn',sourceDirectory,sourceZip]);
const dmg = path.join(output,`WorkTempo-${label}-arm64.dmg`);
run('/usr/bin/hdiutil',['create','-volname','Work Tempo Beta','-srcfolder',volume,'-format','UDZO','-fs','HFS+',dmg]);
run('/usr/bin/hdiutil',['verify',dmg]);
manifest.files = [dmg,sourceZip].map(file => ({name:path.basename(file),bytes:fs.statSync(file).size,sha256:sha(file)}));
fs.writeFileSync(path.join(output,'release-manifest.json'),JSON.stringify(manifest,null,2)+'\n');
const checksumFiles = [dmg,sourceZip,path.join(output,'release-manifest.json'),path.join(output,'安装与试用说明.md')];
fs.writeFileSync(path.join(output,'SHA256SUMS.txt'),checksumFiles.map(file => `${sha(file)}  ${path.basename(file)}`).join('\n')+'\n');
const assessment = spawnSync('/usr/sbin/spctl',['--assess','--type','execute','--verbose=2',app],{encoding:'utf8'});
console.log(JSON.stringify({output,dmg,scratch,signatureVerified:true,gatekeeperStatus:assessment.status,gatekeeper:(assessment.stderr||assessment.stdout).trim(),files:manifest.files},null,2));
