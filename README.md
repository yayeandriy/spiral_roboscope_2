# Roboscope 2 (iOS)

AR laser-guide / repair tooling for iOS.

| | |
|---|---|
| Bundle ID | `spiral-technology.yayeandriy.roboscope2` |
| Team | `2JL868AT85` |
| Scheme | `roboscope2` |

## CI

| Workflow | When |
|---|---|
| **CI** | PRs + pushes to `dev` — simulator build |
| **Deploy App Store** | Pushes to `main` (+ manual `workflow_dispatch`) — archive → TestFlight |
| **Version Bump** | Non-`main` branches — bumps marketing/build in `project.pbxproj` |

On `main`, version is bumped inside Deploy (no separate bump push).

## App Store deploy

Every push to `main` (except `[skip ci]` commits) runs
`.github/workflows/deploy.yml`: Release archive → IPA → upload to
**App Store Connect / TestFlight**. Promoting a build to a public App Store
release or submitting for review stays a manual step in App Store Connect.

Also triggerable via **Actions → Deploy App Store → Run workflow**.

### One-time Apple setup

1. Create the app record in [App Store Connect](https://appstoreconnect.apple.com)
   with bundle ID `spiral-technology.yayeandriy.roboscope2` (team `2JL868AT85`).
2. Create an **App Store Connect API** key (Users and Access → Integrations →
   App Store Connect API) with role **App Manager** or **Admin**. Download the
   `.p8` once; note **Key ID** and **Issuer ID**.
3. Create/export an **Apple Distribution** certificate as a `.p12`.
4. Ensure an **App Store** provisioning profile exists for the bundle ID
   (the workflow can create a named manual profile via the API).

### GitHub secrets

Set these on the `spiral_roboscope_2` repo (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `APPSTORE_CERTIFICATE_P12` | `base64 -i YourDistCert.p12 \| pbcopy` |
| `APPSTORE_CERTIFICATE_P12_PASSWORD` | Password used when exporting the `.p12` |
| `APPSTORE_ISSUER_ID` | Issuer ID from App Store Connect API keys page |
| `APPSTORE_KEY_ID` | Key ID of the API key |
| `APPSTORE_PRIVATE_KEY` | Full contents of `AuthKey_….p8` (including `BEGIN`/`END` lines) |

Also enable **Settings → Actions → General → Workflow permissions → Read and write**
so Deploy can push the version-bump commit.

Version / build numbers live in `roboscope2.xcodeproj/project.pbxproj`
(`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).
