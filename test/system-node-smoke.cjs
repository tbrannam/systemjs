// Loads the published Node.js build on the oldest supported runtimes, where
// the ES module test suite cannot run.
const path = require('path');
const { pathToFileURL } = require('url');
const { System } = require('../dist/system-node.cjs');

System.import(pathToFileURL(path.resolve(__dirname, 'fixtures/register-modules/_a.js')).href)
  .then(m => console.log(`system-node.cjs on Node.js ${process.version}: imported ${Object.keys(m).join(', ')}`))
  .catch(err => {
    console.error(err);
    process.exit(1);
  });
