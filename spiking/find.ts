import * as fs from 'fs';
const glob = new Bun.Glob('src/**/*.ts');
for await (const file of glob.scan()) {
  const content = fs.readFileSync(file, 'utf8');
  if (content.includes('function parsePlayer')) console.log(file);
}
