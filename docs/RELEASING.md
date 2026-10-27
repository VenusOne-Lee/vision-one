# Releasing Vision One

A release is one click in GitHub: **Actions → Release → Run workflow**, type the version (like `0.1.0`), run it on `main`. About 15 minutes later people can install it three ways, and everyone already on Vision One gets it through Sparkle.

| How people get it | Where it comes from |
| --- | --- |
| Download the DMG | The GitHub release: `Vision-One-0.1.0.dmg` |
| `brew install --cask venusone-lee/tap/vision-one` | `Casks/vision-one.rb` in `VenusOne-Lee/homebrew-tap` |
| Update inside the app | `appcast.xml` on the latest GitHub release |

## What the workflow does

`.github/workflows/release.yml`, using the scripts in `scripts/release/`:

1. **Version.** `MARKETING_VERSION` is what you typed. `CURRENT_PROJECT_VERSION` (the build number Sparkle compares) is the number of commits on `main`, so it only goes up.
2. **Build** (`build-app.sh`). XcodeGen, then a Release archive for Apple Silicon signed with your **Developer ID Application** certificate, hardened runtime and a secure timestamp. Exporting with `method: developer-id` signs Sparkle's helper apps too.
3. **Notarise the app** (`notarize.sh`). Zipped, sent to Apple with `notarytool`, ticket stapled.
4. **DMG** (`make-dmg.sh`). The app and an Applications shortcut, compressed, signed.
5. **Notarise the DMG.** Same again, so the download opens without a Gatekeeper warning even offline.
6. **Release.** A draft GitHub release with notes generated from merged PRs, the DMG and `appcast.xml` (`make-appcast.sh`, signed with your Sparkle key) attached, then published as latest.
7. **Homebrew.** `update-cask.sh` fills in `packaging/homebrew/vision-one.rb` and pushes it to the tap.

Pull requests that change these files run a **dry run**: same build and DMG, ad hoc signed, a throwaway Sparkle key, nothing published. The DMG is attached to the run as an artifact.

## One-time setup

You need the Apple Developer Program (US$99 a year). Everything below goes in **Settings → Secrets and variables → Actions** on `VenusOne-Lee/vision-one`.

### 1. Developer ID certificate → `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `APPLE_TEAM_ID`

1. Xcode → Settings → Accounts → your team → **Manage Certificates** → **+** → **Developer ID Application**.
2. Keychain Access → My Certificates → right-click **Developer ID Application: … (TEAMID)** → Export → `.p12`, with a password.
3. `base64 -i DeveloperID.p12 | pbcopy` and paste as the secret **`DEVELOPER_ID_P12`**. The password goes in **`DEVELOPER_ID_P12_PASSWORD`**.
4. The 10-character team ID (in brackets on the certificate, or at developer.apple.com/account) goes in **`APPLE_TEAM_ID`**.

### 2. Notary key → `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`

1. App Store Connect → Users and Access → Integrations → **App Store Connect API** → Team Keys → **+**, name it "Vision One notary", access **Developer**.
2. Download the `AuthKey_XXXXXX.p8` (you only get one chance). Paste its whole text as **`NOTARY_KEY_P8`**.
3. The Key ID goes in **`NOTARY_KEY_ID`**, the Issuer ID at the top of the page in **`NOTARY_ISSUER_ID`**.

### 3. Sparkle keys → `SPARKLE_PRIVATE_KEY` secret, `SPARKLE_PUBLIC_KEY` variable

Sparkle checks every update against this key, so keep the private half safe: losing it means existing installs can't update.

```sh
# Sparkle's tools come with the package. After one Xcode build:
find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/generate_keys' | head -1
# Run it. It saves the private key in your login keychain and prints the public key.
.../generate_keys
.../generate_keys -x sparkle-private-key.txt   # export the private key
```

- The printed public key goes in the **variable** (Variables tab, not Secrets) **`SPARKLE_PUBLIC_KEY`**.
- The contents of `sparkle-private-key.txt` go in the secret **`SPARKLE_PRIVATE_KEY`**. Then delete the file; the keychain keeps a copy.

### 4. Homebrew tap → `HOMEBREW_TAP_TOKEN` (optional)

1. Create a public repo **`VenusOne-Lee/homebrew-tap`** with an empty `Casks/` folder (a README is enough to start).
2. GitHub → Settings → Developer settings → Fine-grained tokens → new token, only that repo, **Contents: Read and write**.
3. Paste it as **`HOMEBREW_TAP_TOKEN`**. Without it the release still works and skips the cask.

Once Vision One has enough users, the cask can move to `homebrew/cask` so `brew install --cask vision-one` works without the tap.

## Rehearsing a release

Before the first release, or after changing a key, run **Actions → Release rehearsal → Run workflow** on `main`. It does the real thing with the real keys, up to the point of publishing, and then stops:

1. Builds Vision One (version `0.0.0`) and signs it with your Developer ID certificate, then checks the signature is for `APPLE_TEAM_ID` and the app carries `SPARKLE_PUBLIC_KEY`.
2. Notarises the app with Apple and staples it, then has Gatekeeper check it.
3. Makes the DMG, signs it, notarises and staples that too.
4. Signs the DMG with `SPARKLE_PRIVATE_KEY` and checks the signature with `SPARKLE_PUBLIC_KEY` (`scripts/release/check-sparkle-key.sh`), so you know the two halves match.

The run's summary lists each check. It publishes nothing: no tag, no GitHub release, no workflow artifact, no appcast and no Homebrew update, and the signed files and keys are deleted when the job ends. That isn't a setting you could get wrong: the job's token can only read the repo, the tap token is never passed in, and `scripts/release/check-rehearsal-workflow.sh` (run by CI on every pull request) fails any change that would let the rehearsal publish.

It does send two builds to Apple's notary service, which is normal and costs nothing. Notarised builds that are never shipped do no harm.

## Cutting a release

1. Make sure `main` is green. If this is the first release, run the rehearsal first.
2. Actions → **Release** → Run workflow → branch `main`, version `0.1.0` → Run.
3. When it's done, check the release page, download the DMG on a Mac that has never run Vision One, and open it. It should open without "unidentified developer".

If notarisation fails, the job prints Apple's log. The usual causes are a helper that isn't signed with the hardened runtime or a missing timestamp.

## Building a release on your Mac

The same scripts run locally with your own keychain:

```sh
VERSION=0.1.0 BUILD_NUMBER=$(git rev-list --count HEAD) SIGN=1 TEAM_ID=ABCDE12345 \
  SPARKLE_PUBLIC_KEY=... scripts/release/build-app.sh
SIGN=1 TEAM_ID=ABCDE12345 scripts/release/make-dmg.sh "build/release/Vision One.app" build/release/Vision-One-0.1.0.dmg
```

Keep `build/` outside an iCloud-synced folder, or code signing fails on Finder's extended attributes.
