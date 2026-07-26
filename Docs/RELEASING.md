# Releasing AgentUsage

AgentUsage intentionally does not require an Apple Developer Program membership. Releases use two persistent, non-Apple secrets:

- A self-signed code-signing certificate keeps the app's macOS designated requirement stable across builds.
- A Sparkle EdDSA private key authenticates update archives. Its matching public key is embedded in `Scripts/build-app.sh`.

Neither mechanism notarizes the app or makes Gatekeeper identify it as coming from an Apple-verified developer.

AgentUsage ships a narrowly scoped Claude usage helper. On first use, the app
copies that helper to `~/Library/Application Support/AgentUsage/ClaudeUsageHelper-v1`
and never replaces it. The helper reads Claude Code's access token, makes the
fixed Anthropic usage request, and returns only the HTTP status, Retry-After
header, non-secret subscription type, and original response body. The
replaceable host app owns all response parsing.

Do not rebuild or replace an installed v1 helper during ordinary app updates.
Its exact executable identity is what macOS authorizes. If the credential shape,
endpoint, or required request headers eventually make a helper change necessary,
introduce a new versioned helper and document that it requires a new one-time
authorization.

Because a self-signed certificate has no Apple TeamIdentifier, the host app carries `com.apple.security.cs.disable-library-validation` so it can load the separately signed Sparkle framework. The hardened runtime remains enabled for the app, framework, and updater helpers.

## One-time local setup

Create and install the persistent code-signing identity:

```sh
./Scripts/create-signing-identity.sh /tmp/AgentUsage-Code-Signing.p12
```

The script stores both generated passwords in the login Keychain under service `io.github.rock-z.agentusage.release-signing`. Keep an encrypted offline backup of the `.p12` file.

The private signing identity remains in its own `AgentUsage-signing.keychain-db`. Local builds retrieve its password from the login Keychain and unlock it automatically. To unlock it manually:

```sh
security unlock-keychain -p "$(
  security find-generic-password -w \
    -s io.github.rock-z.agentusage.release-signing \
    -a keychain-password \
    "$HOME/Library/Keychains/login.keychain-db"
)" "$HOME/Library/Keychains/AgentUsage-signing.keychain-db"
```

The Sparkle key is stored in the login Keychain under account `io.github.rock-z.agentusage`. To export it for CI:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account io.github.rock-z.agentusage \
  -x /tmp/AgentUsage-Sparkle-Private-Key
```

## Required GitHub Actions secrets

Create these repository secrets:

### `AGENTUSAGE_SIGNING_CERTIFICATE_P12`

The single-line base64 encoding of the PKCS#12 file:

```sh
base64 < /tmp/AgentUsage-Code-Signing.p12 | tr -d '\n' \
  | gh secret set AGENTUSAGE_SIGNING_CERTIFICATE_P12
```

### `AGENTUSAGE_SIGNING_CERTIFICATE_PASSWORD`

Pipe the stored PKCS#12 password directly into GitHub:

```sh
security find-generic-password -w \
  -s io.github.rock-z.agentusage.release-signing \
  -a certificate-password \
  "$HOME/Library/Keychains/login.keychain-db" \
  | gh secret set AGENTUSAGE_SIGNING_CERTIFICATE_PASSWORD
```

### `SPARKLE_ED_PRIVATE_KEY`

The contents of the exported Sparkle private-key file:

```sh
gh secret set SPARKLE_ED_PRIVATE_KEY \
  < /tmp/AgentUsage-Sparkle-Private-Key
```

Delete the temporary exported secret files after the GitHub secrets and offline backups are confirmed.

## Release invariants

- Never replace either signing identity without planning a migration.
- Never replace an existing `ClaudeUsageHelper-v1` executable.
- Increment `CFBundleVersion` for every release.
- Match the Git tag to `CFBundleShortVersionString`.
- Build v0.4.3 or later with the stable signing certificate.
- Verify the app's designated requirement remains identical between releases:

```sh
codesign -d -r- /Applications/AgentUsage.app
```

- Verify the appcast and DMG are attached to the GitHub release before announcing it.
- Trigger the tap update immediately after publishing (a six-hour schedule is the fallback):

```sh
gh workflow run update-agentusage.yml --repo Rock-Z/homebrew-tap
```

- Verify Homebrew reports the new release:

```sh
brew update
brew info --cask Rock-Z/tap/agentusage
```
