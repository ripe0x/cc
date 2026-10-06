// builds index.html: engine.js is the single source, inlined here with its export keywords removed
import fs from 'node:fs';
const here = new URL('./', import.meta.url).pathname;
const rd = (f) => fs.readFileSync(here + f, 'utf8');
const engine = rd('engine.js').replace(/^export /gm, '');
const ui = ['page.ui1.js', 'page.ui2.js', 'page.ui3.js', 'page.ui4.js'].map(rd).join('\n');
const html = [
  '<title>Credits Engine Simulator</title>',
  '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600&display=swap">',
  '<style>', rd('page.css').trim(), '</style>',
  rd('page.body.html').trim(),
  '<script>', '(function () {', 'try {', engine, ui, '} catch (e) { document.getElementById("v1").textContent = "script error: " + e.message; throw e; }', '})();', '</script>', '',
].join('\n');
fs.writeFileSync(here + 'index.html', html);
console.log('index.html', html.length, 'bytes');
