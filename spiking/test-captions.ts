import { readFileSync } from 'fs';
import { parsePlayer } from './src/parser/player.ts';

const data = JSON.parse(readFileSync('test-player.json', 'utf8'));
const res = parsePlayer(data);
console.log('Tracks parsed:', JSON.stringify(res.captionTracks, null, 2));
