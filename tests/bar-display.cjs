const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const m = {};
vm.createContext(m);
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, '../BarDisplay.js'), 'utf8'), m);
for (const destination of ['Home', ' HOME ', '1 Stonebridge Place, Aspley QLD 4034, Australia',
  'One Stone Bridge Place Astley', '1 Stonebridge Pl', '1 Stonebridge Pl, Aspley']) {
  assert.equal(m.isHome(destination), true, destination);
}
for (const destination of ['Work', 'Home Depot', '11 Stonebridge Place Aspley',
  '1 Stonebridge Place Sydney', '2 Stonebridge Pl', null]) {
  assert.equal(m.isHome(destination), false, destination);
}
const r = {connected:true, driving:true, destination:'Home', eta:2380};
assert.equal(m.homeEta(r,1000), '23m');
assert.equal(m.homeEta(r,1060), '22m');
for (const override of [{eta:null}, {eta:999}, {eta:NaN}, {connected:false},
  {driving:false}, {destination:'Work'}]) assert.equal(m.homeEta({...r,...override},1000),'');
console.log('Home destination matching, countdown and unavailable ETA checks passed');
