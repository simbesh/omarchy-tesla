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

const charging = {connected:true, charging:'Charging', charger_power:7};
assert.equal(m.secondaryStatus(charging,1000), '⚡ 7kW');
assert.equal(m.secondaryStatus({...charging,charger_power:7.25},1000), '⚡ 7.3kW');
assert.equal(m.secondaryStatus({...charging,charger_power:0},1000), '⚡ 0kW');
for (const power of [null, undefined, NaN, -1])
  assert.equal(m.secondaryStatus({...charging,charger_power:power},1000), '⚡');
assert.equal(m.secondaryStatus({...charging,connected:false},1000), '');
assert.equal(m.secondaryStatus({...charging,charging:'Complete'},1000), '');
assert.equal(m.secondaryStatus(r,1000), '23m');
assert.equal(m.secondaryStatus({...r,...charging},1000), '⚡ 7kW');
console.log('Charging rate, missing power, disconnection and ETA fallback checks passed');
