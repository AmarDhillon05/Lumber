# Building and installing Lumber without a Mac

You have a Windows PC and an iPhone. GitHub's macOS runners do the native
build; you sideload the result from Windows with a free Apple ID.

## 1. Get a build from GitHub Actions

The workflow is `.github/workflows/ios.yml`.

- **Manual:** GitHub → *Actions* → **iOS build** → *Run workflow*. Pick:
  - `debug`: a **dev-client** build. It has no JS inside; it loads the app
    from the dev server on your PC (see §3). Install this one first.
  - `release`: standalone. The JS is bundled in, so it runs without your PC.
- **Automatic:** every push to `main` builds `release`.

When the run finishes, open it and download the artifact
`Lumber-unsigned-<Debug|Release>-<n>`. It's a zip with `Lumber-unsigned.ipa`
inside.

> **Cost:** on a private repo, macOS minutes are billed at **10×** Linux
> minutes. A build takes about 20–30 min, so it uses roughly 200–300 of your
> included minutes. Public repos are free. Typecheck and tests run on Linux
> first, so a broken commit fails before it spends macOS minutes.

## 2. Sideload with Sideloadly (Windows)

One-time setup:

1. Install **iTunes** and **iCloud** for Windows from apple.com (the Apple
   website installers, not the Microsoft Store versions). Sideloadly uses
   their drivers.
2. Install **Sideloadly** from sideloadly.io.
3. Connect the iPhone by USB, unlock it and tap **Trust This Computer**.

Each install:

1. Open Sideloadly, drag in `Lumber-unsigned.ipa`, and choose your iPhone.
2. Enter your Apple ID. A free account works. Sideloadly signs the app with a
   free development certificate. An app-specific password is fine.
3. Click **Start**.
4. On the iPhone, go to **Settings → General → VPN & Device Management**,
   tap your Apple ID and choose **Trust**.
5. **Developer Mode:** iOS asks for this the first time you run a sideloaded
   app. Go to **Settings → Privacy & Security → Developer Mode**, turn it on,
   let the phone restart, then confirm.

Free Apple ID limits:

- The app **expires after 7 days**. Re-sign it by running Sideloadly again
  with the same IPA (your data is kept). Sideloadly can also auto-refresh over
  Wi-Fi while its tray app is running.
- At most **3 sideloaded apps** at a time, and a small number of new app IDs
  per week.

## 3. Day-to-day development loop (no rebuilds for JS changes)

Install the **debug** (dev-client) build once. After that:

```powershell
# on the Windows PC, in the repo
npm install
npx expo start --dev-client
```

- Put the PC and the iPhone on the **same Wi-Fi**. Allow Node through the
  Windows Firewall when it asks (private networks).
- Open Lumber on the phone. The dev-client launcher lists the server; tap it,
  or scan the QR code from the terminal with the Camera app. If discovery
  fails, type `http://<your-PC-LAN-IP>:8081` into the launcher.
- Edits to TypeScript, screens or the DSP reload instantly. **No CI build
  needed.**

You only need a **new CI build** (and to sideload it again) when native
code changes:

- you add, remove or upgrade a package with native code (for example
  `react-native-audio-api`, `onnxruntime-react-native` or any `expo-*`
  module),
- you change `app.json` plugins, permissions or the iOS config,
- you move to a new Expo SDK.

Pure-JS packages (for example `zustand`) don't need a rebuild.

## 4. Alternative: EAS Build (paid Apple Developer account)

With an Apple Developer Program membership ($99/year), **EAS Build** builds
and signs in Expo's cloud and can install over the air or ship to
TestFlight. You skip Sideloadly and the 7-day expiry:

```powershell
npm install -g eas-cli
eas login
eas build:configure
eas device:create          # register your iPhone (ad-hoc)
eas build -p ios --profile development   # dev client
eas build -p ios --profile preview       # standalone, internal distribution
```

EAS has a free tier with a monthly build quota. Paid plans give faster
queues. Builds for TestFlight or the App Store also need the paid Apple
account.
