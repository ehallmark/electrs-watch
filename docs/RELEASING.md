# Releasing to your iPhone

`.github/workflows/testflight.yml` runs on the 1st of each month. It runs the tests, builds `main`, checks the signature, and uploads to TestFlight
for internal testing. TestFlight builds last about 90 days, so a monthly upload leaves room for a missed run.

## Security model

**Whoever controls these secrets, or can push to `main`, can produce a build for your phone.** With the same team and bundle ID, that build can read the
app's Keychain item once you unlock it with Face ID, which holds your Tor client key, onion address and watched addresses. It can't touch your coins.

| Protection | How |
|---|---|
| You decide when a build reaches the phone | Turn off Automatic Updates for this app in TestFlight, then tap Update yourself |
| Limited Apple access | The API key has the App Manager role, not Admin |
| Small CI attack surface | No pull request trigger, read-only `GITHUB_TOKEN`, no third-party actions, `actions/checkout` pinned to a commit |
| Short-lived on the runner | Secrets are only given to the steps that need them, and signing material is removed at the end of the job |

Keep two-factor authentication on for GitHub and your Apple account.

**If you suspect a leak:** revoke the key under App Store Connect, Users and Access, Integrations. Revoke the certificate under Certificates, Identifiers
and Profiles. Delete the repo secrets. Don't install any build from TestFlight until you've checked `main`.

## One-time setup

### 1. Create the app record

In [App Store Connect](https://appstoreconnect.apple.com/apps), add a new iOS app with bundle ID `com.ehallmark.electrswatch`. App names must be unique across the
store, so use something like "electrs-watch Node Viewer". Creating a record doesn't publish anything, and the home-screen name still comes from the build.

### 2. Create the API key

In App Store Connect, go to Users and Access, Integrations, then Team Keys. Generate a key with the **App Manager** role. Note the Key ID and Issuer ID, and
download the `.p8` file, which Apple only offers once.

### 3. Create the certificate

In Xcode, go to Settings, Apple Accounts (called Accounts in older versions). Select your Apple ID, select your team, then choose Manage Certificates.
Add an **Apple Distribution** certificate. Then right-click it, choose Export Certificate, save `distribution.p12`, and choose a strong password.

If Xcode doesn't offer Manage Certificates, use Keychain Access instead. Choose Keychain Access, Certificate Assistant, Request a Certificate From a
Certificate Authority, and save the request to disk. Upload it on [Apple's Certificates page](https://developer.apple.com/account/resources/certificates/add)
as an **Apple Distribution** certificate, then download it and double-click it. In Keychain Access, under My Certificates, right-click "Apple Distribution:
..." and choose Export to save `distribution.p12`.

### 4. Create the profile

On [Apple's Profiles page](https://developer.apple.com/account/resources/profiles/add), choose **App Store Connect** under Distribution. Select the
`com.ehallmark.electrswatch` App ID and the certificate from step 3, name it `electrs-watch TestFlight`, and download it.

### 5. Store the secrets

From this repo, using your own file paths. `gh secret set` prompts for values, so they stay out of your shell history. The secrets go in the `testflight` environment, not the repo, so only an owner-approved run from `main` can read them. Create the environment first (`docs/OPEN-SOURCE.md`, section 2). GitHub only offers environment secrets on public repos, unless the account has GitHub Pro, so make the repo public before this step.

```sh
base64 -i distribution.p12 | gh secret set APPLE_DISTRIBUTION_P12 --env testflight
gh secret set APPLE_DISTRIBUTION_P12_PASSWORD --env testflight
base64 -i electrs-watch_TestFlight.mobileprovision | gh secret set TESTFLIGHT_PROFILE --env testflight
gh secret set ASC_KEY_P8 --env testflight < AuthKey_XXXXXXXXXX.p8
gh secret set ASC_KEY_ID --env testflight
gh secret set ASC_ISSUER_ID --env testflight
gh secret set APPLE_TEAM_ID --env testflight
```

Then delete `distribution.p12` and the `.p8` from your Mac. If you ever need them again, it's easier and safer to create new ones.

### 6. Upload the first build

```sh
gh workflow run testflight.yml
gh run watch
```

The run waits for your approval before it can read the secrets: open it under the repo's Actions tab and choose Review deployments, then Approve.

### 7. Set up TestFlight

1. Wait for the build to finish processing in App Store Connect. Answer its export compliance question if it asks.
2. Under the app's TestFlight tab, create an internal group, add yourself, and turn on automatic distribution.
3. Install Apple's TestFlight app on the phone and accept the invite.
4. Install electrs-watch over the existing copy. Don't delete the old one first.
5. In TestFlight, open electrs-watch and turn off Automatic Updates.
6. Turn off Developer Mode, restart, and confirm that electrs-watch opens.

## Ongoing

- **Monthly:** open TestFlight and tap Update. You must do this at least every 90 days, or the app stops opening until you do.
- **If a run fails:** GitHub emails you. Run it again with `gh workflow run testflight.yml` once it's fixed.
- **Yearly:** the certificate and profile last about a year. The workflow still uploads but reports a failure when they have under 45 days left. Repeat
  steps 3 to 5 for those two secrets. The API key doesn't expire.
- **Membership:** builds stop if the Apple Developer Program membership lapses.
- **Cost:** a run should take a few minutes, at about 0.06 USD per macOS minute, which fits in GitHub's included monthly usage.

## Other build scripts

- `scripts/testflight-build.sh` with no arguments is a dry run on your Mac. It builds and checks but uploads nothing.
- `scripts/release-build.sh` makes an Ad Hoc build. It lasts about a year, but the phone must keep Developer Mode on.
- `make install` runs that script and installs the build on your iPhone.
