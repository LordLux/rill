import { createSession } from "./src/innertube/session.ts";
import { get } from "./src/parser/items.ts";
import { fetchBody } from "./src/innertube/session.ts";
import { performSearch } from "./src/innertube/search.ts";

async function main() {
  const session = await createSession({ clientType: "MWEB" });
  const raw = await fetchBody(session, "/browse", { browseId: "UCGmO0S4S-AunjRdmxA6TQYg" });
  console.log(JSON.stringify(raw).substring(0, 100));
}
main().catch(console.error);
