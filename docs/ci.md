# No-hardware continuous integration

YunAudio's automated workflow is deliberately narrower than the release gate. It proves the
parts which can run without owning a person's audio devices, and makes the omitted hardware
evidence explicit. It never starts a route, changes a device, installs the driver or restarts
`coreaudiod`.

The workflow lives at [`.github/workflows/no-hardware-ci.yml`](../.github/workflows/no-hardware-ci.yml).
Every shell step enters through [`ci/no-hardware.sh`](../ci/no-hardware.sh), whose stage names
do not expose a hardware-mutating option. [`ci/workflow-policy.rb`](../ci/workflow-policy.rb)
then checks that this boundary has not been bypassed.

## What the jobs prove

| Job | Evidence | Host |
|---|---|---|
| `verify-matrix` | Swift build, every deterministic debug test which needs no live HAL, strict `swift-format`, localisation, driver build/tests/static checks, and the isolated app-bundle probe | macOS 26, macOS 27 and the nominated next beta |
| `release-evidence` | The same no-hardware selection in an optimised build, including release-only realtime-allocation and performance budgets | Stable macOS 27 by default |
| `sanitizers` | A bounded set of ownership, publication, queue, socket and DSP-layout tests under ASan, TSan and UBSan | Stable macOS 27 by default |

Eight tests in the ordinary Swift suite are not safe for this workflow: two change a physical
device's sample rate, four create live process taps, and two depend on live HAL enumeration. The
wrapper rejects an inherited `YUNAUDIO_LIVE_HAL_TESTS`, inventories their complete test
identifiers before executing anything, and skips exactly those eight. Every gated test carries
machine-readable `TestCapabilities.liveHALTest(...)` metadata; CI extracts the declarations in
the opposite direction and requires them to equal `ci/live-hal-tests.txt`. Its executed count must
therefore equal `App/test-floor.txt` minus eight; losing any other test is a failure rather than a
smaller green run.

A raw `swift test` is safe by default as well: those eight tests are present but disabled unless a
person explicitly sets `YUNAUDIO_LIVE_HAL_TESTS=1`. CI still applies the exact skip list as a
second, independently checked defence. macOS 26 runs the guarded transcription availability
branches rather than externally excluding them, so `.needsNewerSystem` remains affirmative test
evidence instead of a skipped assertion.

The sanitizer filter also has a lower bound so renamed test suites cannot silently turn it into
an empty run. ASan leak detection is disabled: this lane is evidence about invalid memory access,
while process-lifetime leak and Core Audio residue need the dedicated lifecycle harness.

The following are intentionally absent:

- `YUNAUDIO_FLOWCHECK=1`, `App/verify.sh --full` and every real-route UI flow;
- `AudioObjectStringTests`, `SampleRateRestorationTests`, `ProcessTapRestoreTests` and the live
  matching case in `AudioApplicationGroupingTests`;
- every `yunaudio-cli` hardware command, including `selftest`, `soak`, `dsp` and `light`;
- driver installation, `sudo`, `killall`, `launchctl` and any direct `coreaudiod` action;
- claims about device recovery, aggregate/tap disappearance, long-run drift, dropouts, the
  system Sound menu or system-wide audio responsiveness.

Those remain human-authorised evidence on an isolated machine. A green workflow is not a
release sign-off for issue #9.

## Runner labels and Xcode selection

GitHub-hosted labels are not assumed. Each `runs-on` value is a repository variable containing
a JSON array of labels; GitHub dispatches the job only to a self-hosted runner carrying every
label in the array. The checked-in defaults are useful conventions, not infrastructure claims.

| Repository variable | Default label set or purpose |
|---|---|
| `YUNAUDIO_RUNNER_MACOS_26` | `["self-hosted","macOS","yunaudio-ci","macos-26"]` |
| `YUNAUDIO_RUNNER_MACOS_27` | `["self-hosted","macOS","yunaudio-ci","macos-27"]` |
| `YUNAUDIO_RUNNER_MACOS_BETA` | `["self-hosted","macOS","yunaudio-ci","macos-beta"]` |
| `YUNAUDIO_RUNNER_RELEASE` | Optional release-specific label set; otherwise the macOS 27 set |
| `YUNAUDIO_RUNNER_SANITIZERS` | Optional sanitizer-specific label set; otherwise the macOS 27 set |
| `YUNAUDIO_XCODE_MACOS_26` | Optional absolute path ending in `/Contents/Developer` |
| `YUNAUDIO_XCODE_MACOS_27` | Optional absolute path ending in `/Contents/Developer` |
| `YUNAUDIO_XCODE_MACOS_BETA` | Optional absolute path ending in `/Contents/Developer` |
| `YUNAUDIO_XCODE_RELEASE` | Optional release-lane Xcode override |
| `YUNAUDIO_XCODE_SANITIZERS` | Optional sanitizer-lane Xcode override |
| `YUNAUDIO_BETA_OS_MAJOR` | Expected numeric OS major for the beta runner |

The macOS 26 runner still needs an Xcode whose SDK can compile the guarded macOS 27
transcription API. It executes the tests on macOS 26, which proves the availability boundary;
the SDK and host OS are separate axes. Each stable lane rejects the wrong host major, and the
beta lane does the same when `YUNAUDIO_BETA_OS_MAJOR` is set.

An unconfigured label leaves a job queued rather than substituting an unsuitable hosted image.
GitHub currently cancels a self-hosted job which has not been accepted within 24 hours. Runner
label matching is documented in [Using self-hosted runners in a workflow](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/use-in-a-workflow).

## Trust and runner operation

The workflow has no `pull_request` or `pull_request_target` trigger. It runs on trusted pushes,
manual dispatches and a weekly schedule because a public fork can modify the repository code it
asks a self-hosted runner to execute. Review an external pull request first, then reproduce its
reviewed revision on a protected branch before using these runners. GitHub's
[secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use)
describes the self-hosted runner boundary.

Operate the runners as disposable build machines:

- use a repository- or workflow-restricted runner group and do not attach deployment secrets;
- give the runner account no `sudo`, audio-driver installation or service-management rights;
- use one runner process per host, restore a clean snapshot between jobs, and keep caches
  disposable;
- keep the runner at version 2.327.1 or newer, which the pinned `actions/checkout` v6 requires;
- update each beta host and label deliberately; a label is an operator assertion, not OS
  discovery.

The workflow token has only `contents: read`, checkout discards its credentials, and third-party
actions must be pinned to full commit hashes. The policy check rejects all three properties if
they drift.

## Local reproduction

The wrapper can be used outside GitHub Actions without setting `CI`:

```bash
./ci/no-hardware.sh inventory
./ci/no-hardware.sh policy
./ci/no-hardware.sh all
./ci/no-hardware.sh release
./ci/no-hardware.sh sanitizer address
./ci/no-hardware.sh sanitizer thread
./ci/no-hardware.sh sanitizer undefined
```

`all` is the matrix verification surface; release and sanitizer evidence stay separate so their
cost and failure mode remain visible. Raw `swift test` is safe for ordinary local work, but do not
substitute it for the CI wrapper: it does not prove the reviewed exclusion inventory, the
executed-count arithmetic or the workflow policy. To select a particular Xcode locally, set
`YUNAUDIO_CI_DEVELOPER_DIR` to its absolute `Contents/Developer` directory.

When adding a CI stage, add it to the wrapper and the policy's required-stage list together. Do
not add a forwarding stage which accepts arbitrary commands or arguments: a closed vocabulary is
what keeps a harmless workflow edit from becoming a system-audio operation.
