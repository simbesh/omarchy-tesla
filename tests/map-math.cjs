const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const m = {};
vm.createContext(m);
vm.runInContext(fs.readFileSync(require('node:path').join(__dirname, '../MapMath.js'), 'utf8'), m);
const near = (a,b) => assert.ok(Math.abs(a-b)<1e-6, `${a} != ${b}`);
for (const [lat,lon] of [[0,0],[-27,153],[85,-179],[-85,179]]) {
  const p=m.world(lat,lon,16), c=m.coordinate(p.x,p.y,16);
  near(c.lat,lat); near(c.lon,lon);
}
const before=m.world(-27,153,16);
const pan=m.pan(-27,153,16,100,-50), after=m.world(pan.lat,pan.lon,16);
near(after.x,before.x-100); near(after.y,before.y+50);
const zoom=m.zoomAt(-27,153,16,17,80,-60), center=m.world(zoom.lat,zoom.lon,17);
near(center.x+80,(before.x+80)*2); near(center.y-60,(before.y-60)*2);
assert.ok(Math.abs(m.deltaX(1,256*8-1,3)-2)<1e-6);
const pole=m.coordinate(0,-100,16); assert.ok(pole.lat<=85.05113);
console.log('Map projection, pan direction, cursor-anchored zoom, dateline and polar bounds passed');
