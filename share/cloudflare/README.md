# Vision One share server

The Worker Vision One puts on your own Cloudflare account to host share pages. Vision One sets it up for you when you connect Cloudflare (Post panel, Share page, Connect Cloudflare), so you don't need this folder for that.

To deploy it by hand:

```sh
npx wrangler r2 bucket create vision-one-share
npx wrangler d1 create vision-one-share        # put the id in wrangler.toml
npx wrangler d1 execute vision-one-share --remote --file ../../Sources/VisionOneKit/Share/Page/Cloudflare/schema.sql
npx wrangler secret put CREATOR_KEY
npx wrangler deploy
```

How it works: [docs/SHARE-PAGE.md](../../docs/SHARE-PAGE.md).
