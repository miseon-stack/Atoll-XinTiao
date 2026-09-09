#!/usr/bin/env node
// Read-only image validation and isolated test-mode boot; never touches /Applications.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync, spawn, spawnSync} from 'node:child_process';

const [directoryArg] = process.argv.slice(2);
if (!directoryArg || process.argv.length !== 3) throw Error('Usage: node scripts/verify-beta.mjs PACKAGE_DIRECTORY');
const directory = fs.realpathSync(directoryArg);
const manifest = JSON.parse(fs.readFileSync(path.join(directory,'release-manifest.json'),'utf8'));
const sha = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const run = (cmd,args,options={}) => execFileSync(cmd,args,{encoding:'utf8',maxBuffer:8*1024*1024,...options});
for (const entry of manifest.files) {
  if (path.basename(entry.name) !== entry.name) throw Error('Unexpected manifest path.');
  const file = path.join(directory,entry.name);
  if (fs.statSync(file).size !== entry.bytes || sha(file) !== entry.sha256) throw Error(`Checksum mismatch: ${entry.name}`);
}
const dmgEntry = manifest.files.find(file => file.name.endsWith('.dmg'));
if (!dmgEntry) throw Error('Missing DMG.');
const dmg = path.join(directory,dmgEntry.name);
const scratch = fs.mkdtempSync('/private/tmp/work-tempo-image-check-');
const mount = path.join(scratch,'mount');
const installed = path.join(scratch,'copied-app','Work Tempo.app');
fs.mkdirSync(mount);
run('/usr/bin/hdiutil',['verify',dmg]);
let attached = false;
try {
  run('/usr/bin/hdiutil',['attach','-readonly','-nobrowse','-mountpoint',mount,dmg]);
  attached = true;
  if (fs.readlinkSync(path.join(mount,'Applications')) !== '/Applications') throw Error('Invalid Applications shortcut.');
  const mountedApp = path.join(mount,'Work Tempo.app');
  run('/usr/bin/codesign',['--verify','--deep','--strict',mountedApp]);
  run('/usr/bin/ditto',[mountedApp,installed]);
} finally {
  if (attached) run('/usr/bin/hdiutil',['detach',mount]);
}
run('/usr/bin/codesign',['--verify','--deep','--strict',installed]);
const info = JSON.parse(run('/usr/bin/plutil',['-convert','json','-o','-',path.join(installed,'Contents/Info.plist')]));
if (info.CFBundleVersion !== manifest.build || info.CFBundleShortVersionString !== manifest.version) throw Error('Packaged version mismatch.');
const appExecutable = path.join(installed,'Contents/MacOS',info.CFBundleExecutable);
const startupChecks = [];
// This flag skips real monitors, hotkeys, network updaters and persistent feature services.
// A surviving process proves loader/startup viability only, NOT product UI or file-permission acceptance.
for (let attempt=1; attempt<=2; attempt++) {
  const child = spawn(appExecutable,[],{env:{...process.env,ATOLL_UNIT_TESTING:'1'},stdio:['ignore','pipe','pipe']});
  let captured = '';
  child.stdout.on('data',chunk => {captured += chunk;});
  child.stderr.on('data',chunk => {captured += chunk;});
  let spawnError;
  child.on('error',error => {spawnError=error;});
  const exited = new Promise(resolve => child.once('close',(code,signal)=>resolve({code,signal})));
  await new Promise(resolve => setTimeout(resolve,5000));
  const survived = !spawnError && child.exitCode === null && child.signalCode === null;
  if (survived) child.kill('SIGTERM');
  const exit = await Promise.race([exited,new Promise(resolve => setTimeout(()=>resolve(null),3000))]);
  if (!exit && survived) { child.kill('SIGKILL'); await exited; }
  fs.writeFileSync(path.join(scratch,`startup-${attempt}.log`),captured);
  startupChecks.push({attempt,survivedFiveSeconds:survived,exit});
  if (!survived) throw Error(`Test-mode startup ${attempt} failed; diagnostic log: ${scratch}`);
}
const policy = spawnSync('/usr/sbin/spctl',['--status'],{encoding:'utf8'});
const policyText = (policy.stdout+policy.stderr).trim();
const ticket = spawnSync('/usr/bin/xcrun',['stapler','validate',installed],{encoding:'utf8'});
const report = {
  product:manifest.product,label:manifest.label,build:manifest.build,dmgSHA256:dmgEntry.sha256,
  checksumVerified:true,readOnlyMountVerified:true,copyOutAndEjectVerified:true,signatureVerified:true,
  architecture:run('/usr/bin/lipo',['-archs',appExecutable]).trim(),
  system:run('/usr/bin/sw_vers',['-productVersion']).trim(),startupChecks,
  startupMode:'ATOLL_UNIT_TESTING=1; no actual feature UI or hotkey/permission acceptance',
  notarizationTicketPresent:ticket.status === 0,gatekeeperPolicy:policyText,
  gatekeeperDistributionAcceptance:'NOT VERIFIED — requires a different normally protected Mac and an actual download',
  cleanMacAcceptance:'PENDING',createdAt:new Date().toISOString()
};
fs.writeFileSync(path.join(directory,'local-validation.json'),JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify({report,scratch},null,2));
