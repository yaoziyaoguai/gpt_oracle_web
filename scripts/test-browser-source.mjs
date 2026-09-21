import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const wrapper=process.argv[2];
const testRoot=mkdtempSync(path.join(tmpdir(),'oracle-source-test-'));
try {
  const configRoot=path.join(testRoot,'config');
  const config=path.join(configRoot,'oracle-web','chrome-user-data-dir');
  mkdirSync(path.dirname(config),{recursive:true});
  const source=path.join(testRoot,'source with spaces');
  const override=path.join(testRoot,'override');
  for(const dir of [source,override]){
    mkdirSync(path.join(dir,'Default'),{recursive:true});
    writeFileSync(path.join(dir,'Local State'),'{}');
    writeFileSync(path.join(dir,'Default','Cookies'),'test-placeholder');
  }
  const env={...process.env,XDG_CONFIG_HOME:configRoot,ORACLE_WEB_ORACLE_BIN:'/usr/bin/true'};
  delete env.ORACLE_WEB_CHROME_USER_DATA_DIR;
  delete env.ORACLE_WEB_CHROME_PROFILE;
  const doctor=(extra={})=>spawnSync('bash',[wrapper,'--doctor'],{env:{...env,...extra},encoding:'utf8'});
  writeFileSync(config,source+'\n');
  let result=doctor();
  assert.equal(result.status,0,result.stderr);
  assert.ok(result.stdout.includes('chromeUserDataDir='+source+'\n'));
  result=doctor({ORACLE_WEB_CHROME_USER_DATA_DIR:override});
  assert.equal(result.status,0,result.stderr);
  assert.ok(result.stdout.includes('chromeUserDataDir='+override+'\n'));
  for(const invalid of ['', 'relative/path',source+'\n/second-source']){
    writeFileSync(config,invalid);
    assert.equal(doctor().status,78,'Malformed config silently selected another source');
  }
  writeFileSync(config,path.join(testRoot,'missing'));
  assert.equal(doctor().status,78,'Missing source silently fell back to daily Chrome');
  rmSync(config);
  assert.equal(doctor({ORACLE_WEB_CHROME_USER_DATA_DIR:override}).status,0);
  console.log('Persistent browser source config tests passed');
} finally {
  rmSync(testRoot,{recursive:true,force:true});
}
