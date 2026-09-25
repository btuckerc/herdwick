# Herdwick

- Core package: `cd Packages/HerdwickCore && mise exec -- swift test`. Live suites are opt-in:
  `HERDWICK_LIVE=1` (local herdr; read-only on session `main`, writes only in throwaway
  `herdwick-test-*` sessions) and `HERDWICK_SSH_LIVE=1` (private unprivileged sshd on 127.0.0.1).
- Never write to the user's real herdr session `main`.
- The iOS app builds only on the Mac Mini (`ssh mini`, Xcode on `/Volumes/E0/Developer`); Linux builds the core package only.
  `scripts/mini/sync-and-build.sh` (rsync + XcodeGen + simulator build); add `testflight` with `ASC_KEY_ID`/`ASC_ISSUER_ID` to upload.
- Simulator UI checks: `axe` on the Mini (coordinate taps; `--label` taps time out).
