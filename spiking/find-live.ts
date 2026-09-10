import { querySearch } from './src/innertube/search.ts';
import { createSession } from './src/innertube/session.ts';

async function main() {
  const session = await createSession({ clientType: 'WEB' });
  const res = await querySearch({ session }, 'live news');
  const lives = res.items.filter(i => i.isLive);
  console.log('Live streams found:');
  lives.slice(0, 5).forEach(l => console.log(l.id, l.title));
}
main().catch(console.error);
