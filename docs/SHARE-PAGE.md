# Share page

A share page is a link viewers can talk to. They watch, read the transcript, ask the video a question, react at a moment and leave a note on a line. Notes come back to the creator as tasks, and where people stop watching feeds the coach. Visual overview: the share page artifact linked from the PR.

All of the logic is in VisionOneKit (`Sources/VisionOneKit/Share/Page/`) so the app, the Agent Desk and the MCP server use the same code.

## The bundle

`SharePageBundle.write` builds one folder per take (`share-page/` in the take folder):

| File | What |
| --- | --- |
| `index.html` | The page (`share-page.html`, shipped as a VisionOneKit resource) with `page.json` inlined, so it also opens straight from disk |
| `page.json` | `SharePageDocument`: title, author, transcript lines in export time, chapters, look, features, call to action, API address |
| `video.mp4` | The exported video |
| `captions.vtt`, `poster.jpg` | Optional |

The page loads nothing from other sites: no fonts, scripts, trackers or cookies. JSON is inlined with `<`, `>` and `&` escaped, so no title or line can break out of its script tag.

`SharePageDocument.make` takes the transcript, the edits' `ExportTimeline` and the Sharer's `SharePack`: sentences that survive the edit are moved to export time, and the title, description and chapters come from the Sharer's draft when there is one.

## Looks

`SharePageLook` has six presets made only from colours in [DESIGN.md](DESIGN.md): Paper, Warm desk, Cool blue, Ring red, Purple and Print. On top of a preset the creator can change the accent, background, transcript font (serif, sans, mono), corners (sharp, soft, round) and where the transcript sits (beside, below, hidden). The page stays light. Tally orange, and anything close to it, is refused as an accent because orange only ever means "recording is live". Accents must stand out from the panels (3:1), and button text switches between white and ink to stay readable (4.5:1).

## Ask the video

`VideoAnswerer` finds the transcript lines that answer a question and the page quotes them with a time to jump to. It runs in the viewer's browser (the page has the same steps in JavaScript; keep the two in step), costs nothing, and can't make anything up: when no line matches, the page says the video doesn't say. Matching drops small words, maps a few question words to what a speaker would say ("cost" finds "price" and "rand"), strips plural and -ing endings, and weights rarer words higher.

## Notes, reactions and insights

These need somewhere to send to, so they only show when `page.json` has an `api` address. Without one the page is read-only: watch, transcript, chapters and ask.

The page sends:

- `POST {api}/events` with `{page, events: [ViewerEvent]}`: `view` when play starts, `progress` every 5 s of playback, `finish`, `reaction` (emoji and time) and `question` (the text asked). Each visit has a random id kept in session storage; no names, accounts or cookies. Sent in batches and with `sendBeacon` when the tab closes.
- `POST {api}/notes` with `{page, note: {name, text, at, quote}}`. The name is optional. Notes go to the creator only.
- `GET {api}/reactions?page=` to draw everyone's reactions on the moments bar.

Vision One pulls the creator's inbox (notes and events) into `viewers.json` in the take folder (`ViewerInbox`, merged without repeats) and then:

- each open note becomes an Agent Desk task under "Needs you" (`ViewerNote.job(for:)`), with `editorAsk` ready for "Ask the Editor to fix";
- `WatchCurve` turns progress into the share still watching at each second, and `biggestDrop` finds the 5 s window where most people leave (ignoring the last 5 s and needing at least 5 views);
- `ViewerCoachHint` names that moment and its sentence ("40% of viewers leave by 0:16") and phrases an ask for a tighter opening or a shorter middle;
- `ViewerSummary` gives views, average watched, finishes, questions asked and reactions.

## The link

`share-page.json` in the take folder (`SharePageRecord`) keeps the slug, host, link, look, features and call to action. `ShareLinkStore.link(for:)` returns the public link once the page is published, or nil. The Post panel shows Copy link and adds the link to posts whenever it isn't nil. A static folder has no link until the creator says where they put it.

## Hosting

Lee picked (27 Oct 2026): a static folder by default, and the creator's own free Cloudflare account for links with notes, reactions and insights. Vision One hosts nothing and runs no servers.

**Without setup**, Publish ("Make page folder") builds the bundle and shows it in Finder. It works on any static host, or opened from disk. The page is read-only: watch, transcript, chapters, ask.

**With Cloudflare connected**, Publish uploads the same bundle and the page gets a link like `https://vision-one-share.<name>.workers.dev/v/<slug>/`.

`ConnectCloudflareSheet` asks for one API token (Workers Scripts Edit, Workers R2 Storage Edit, D1 Edit, Account Settings Read). `CloudflareShareSetup` then:

1. finds the account;
2. makes the R2 bucket `vision-one-share` (reused if it's there);
3. makes the D1 database `vision-one-share` and runs `schema.sql`;
4. uploads `worker.js` with the bucket, the database and a random `CREATOR_KEY` bound;
5. turns on the account's workers.dev address (making one if it has none);
6. checks `/api/health`, retrying while a new address switches on.

The token and the creator key stay in the Keychain. `CloudflareShareAccount` (no secrets) is saved in Application Support. Running setup again updates the Worker.

Free tier, as published in 2026: 10 GB of R2 storage with no download fees, 100,000 Worker requests a day, 5 GB of D1. Cloudflare asks for a card to switch on R2 even on the free tier. Uploads go through the Worker, so a page's video can be up to 95 MB; the publisher picks the best export under that.

### The Worker (`Sources/VisionOneKit/Share/Page/Cloudflare/worker.js`)

| Route | Who | What |
| --- | --- | --- |
| `GET /v/:slug/` and `/v/:slug/:file` | viewers | The bundle from R2, with Range requests for video and a strict CSP on the page |
| `POST /api/events` | viewers | Up to 50 events per post. Unknown kinds, bad visit ids and non-listed emoji are dropped. Capped per page per day |
| `POST /api/notes` | viewers | Text up to 1,000 characters, optional name up to 60. 200 per page per day |
| `GET /api/reactions` | viewers | The last 300 reactions |
| `GET /api/health` | creator | Checks the key |
| `PUT /api/pages/:slug/:file` | creator | Uploads one bundle file (only the five bundle names) |
| `DELETE /api/pages/:slug` | creator | Takes the page and its notes and events down |
| `GET /api/inbox?page&since&after` | creator | Notes from `since`, events after id `after` |

Creator routes need `Authorization: Bearer <CREATOR_KEY>`, compared by hash. No IP addresses are stored and no cookies are set. `share/cloudflare/wrangler.toml` deploys the same Worker by hand with `npx wrangler deploy`.

## In the app

`SharePageSection` sits in the Post panel: the six looks, Customise (accent, background, transcript font, corners, transcript place, what viewers can do, your button), one Publish button and a menu for Cloudflare, Take down and Show folder. With a published Cloudflare page, `ViewersPanel` shows views, average watched, the curve, the coach card, reactions, questions and notes. New notes are filed on the take's Desk task as Plan first asks, so "Yes" runs the Editor on them.
