# Pitaka Budget

A shared household budget app for two phones. Log expenses and income in pesos, set monthly budgets per category, and see entries from both phones in one ledger. Works offline and syncs when back online.

- App: static files hosted on GitHub Pages
- Sync: one Supabase function (`pitaka_sync`) guarded by a household key

## Files

| File | What it is |
|---|---|
| `index.html` | The app |
| `config.js` | Your Supabase URL and publishable key |
| `supabase-setup.sql` | Creates the tables, security rules and sync function |
| `sw.js` | Offline support. Bump `VERSION` when you change files |
| `manifest.webmanifest`, `icons/` | Home screen install |

## Setup

### 1. Supabase
1. Sign in at supabase.com and create a new project (region: Singapore). Save the database password somewhere safe.
2. Open **SQL Editor > New query**, paste all of `supabase-setup.sql`, and click **Run**.
3. Copy the **Project URL** and the **publishable key** into `config.js`.

### 2. GitHub Pages
1. Create a repository, e.g. `pitaka`, and upload every file in this folder.
2. Go to **Settings > Pages**, set Source to **Deploy from a branch**, branch `main`, folder `/ (root)`, and save.
3. After a minute the app is live at `https://<your-username>.github.io/pitaka/`.

### 3. Phones
1. Open the link, enter your name and the household key, then install it (Chrome: Install app; Safari: Share > Add to Home Screen).
2. In the app, open **⋯ > Invite your partner > Share** and send the link.

## Security notes
- The publishable key in `config.js` is meant to be public.
- The tables can't be read or written from the browser directly. Every request goes through `pitaka_sync`, which checks the household key. Only the key's hash is stored, in the database and in `supabase-setup.sql`.
- Never commit the household key itself or the Supabase **secret** key to this repository.
- To change the household key, insert a new hash (see the comment at the end of `supabase-setup.sql`), enter the new key on both phones, then delete the old row from `pitaka_households`.
