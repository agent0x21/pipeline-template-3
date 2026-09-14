# pipeline-template-3

A pnpm monorepo (React web app, ASP.NET Core API, WPF desktop app) wired to a
deterministic release pipeline: **build once, deploy that exact artifact to QA,
approve it, then ship the same artifact to production** — with no human ever
typing or looking up a commit SHA.

- [What the pipeline guarantees](#what-the-pipeline-guarantees)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Day-to-day: how do I…](#day-to-day-how-do-i)
- [Workflow reference](#workflow-reference)
- [Configuration](#configuration)
- [Local commands](#local-commands)
- [First-time repository setup](#first-time-repository-setup)
- [When something fails](#when-something-fails)
- [Further reading](#further-reading)

## What the pipeline guarantees

> Development branches may evolve independently and may create development
> artifacts on demand for branch-level testing. A formal release candidate begins
> only when a specific Git SHA is selected for promotion. That release artifact is
> built once from that SHA, QA validates that exact artifact, and Production
> deploys the same artifact without rebuilding it. The pipeline automatically
> promotes the approved source commit into the appropriate protected source
> branches without requiring humans to manually select SHAs.

Concretely:

| Guarantee | How it is enforced |
| --- | --- |
| A release artifact is built exactly once | Only the `candidate` job builds. Every later job consumes `release-manifest.json`. |
| QA and production run the same artifact | Both deploy `image@sha256:…`; production asserts digest equality with the approved release before deploying. |
| Production never rebuilds | No build step, plus a job that fails if any build output is present, plus config validation that rejects a `build` key on an environment. |
| Every release ties to one exact commit | The SHA is captured from the trigger and `HEAD` is verified against it before anything is built. |
| `main` contains the QA-approved commit | The pipeline fast-forwards `main`, or merges while keeping the approved SHA in ancestry. Never cherry-picks or squashes. |
| Branch names are never the release identity | After candidate creation, everything reads the persisted manifest, not `qa`/`main`. |

Four states, and what moves you between them:

```text
development build  →  (nothing; it is a dead end for testing only)
release candidate  →  built once from a selected SHA
QA-approved release→  a reviewer approves that specific SHA + digest
production release →  automatic, same digest
```

[eng/ci/RELEASE-STANDARD.md](eng/ci/RELEASE-STANDARD.md) defines each state and
every guardrail in full.

## Repository layout

```text
apps/web          React + TypeScript + Vite client
apps/api          ASP.NET Core HTTP API (published as a GHCR container)
apps/desktop      WPF desktop client (Windows)
packages/shared   Shared TypeScript contracts and helpers
eng/ci            The release engine: PowerShell module, scripts, docs
.github/workflows CI, development artifacts, release lifecycle
.releasepipeline.yml  Component, channel, and environment configuration
```

Each app is a **component** with its own version line and its own
`<component>/v<SemVer>` tags. A release can cover one component or several.

## Prerequisites

Local development:

```powershell
# pnpm 12.3.4 (declared in package.json)
pnpm install
```

Working on the release engine itself also needs:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
```

CI runs on `self-hosted` Windows runners with `git`, `pwsh`, `dotnet`, `node`,
`pnpm`, and `docker` available. Each workflow checks for these before starting.

## Day-to-day: how do I…

### …work on a feature?

Branch from `dev`, commit freely, open a pull request. Every push and PR runs
**CI**, which lints, builds, and runs the release-engine tests. It produces no
artifact and creates no tag — ordinary commits cost you nothing.

Branches are isolated: CI and development builds are grouped per branch, so your
branch never blocks or is blocked by anyone else's.

### …deploy my branch somewhere to test it?

Request a development artifact. Two ways:

- **Actions → Development Artifact → Run workflow**, selecting your branch. Leave
  `components` empty to build everything, or pass a comma-separated subset such as
  `api,web`.
- **Add the `build:dev-artifact` label to your pull request.**

You never enter a SHA. The workflow reads the branch or PR head commit, verifies
the checkout matches it, and builds:

```text
branch:   dev/new-checkout
git_sha:  93abc12ab34c…
artifact: ghcr.io/agent0x21/pipeline-template-3-api:dev-93abc12ab34c
digest:   sha256:1234…
```

The run summary and `development-build.json` carry all four values. Development
artifacts are disposable (7-day retention) and are **not** release candidates —
they create no Git tag and cannot enter the QA → production path.

To build one locally:

```powershell
pnpm dev-build -ExpectedSha (git rev-parse HEAD) -Branch (git branch --show-current)
```

### …ship a release?

**Actions → Release Candidate → Run workflow**, selecting the development branch
you want to ship. Optional inputs:

| Input | Meaning |
| --- | --- |
| `version_bump` | `minor` (default), `patch`, or `major` for all changed components |
| `component_overrides` | Per-component bump, e.g. `{"api":"patch"}` |
| `exact_versions` | Pin a version, e.g. `{"api":"2.4.0"}` |
| `release_all` | Release every component, even unchanged ones |

Everything else is automatic. The workflow:

1. Captures the dispatch SHA and verifies `HEAD` equals it.
2. Works out which components changed relative to the source currently under QA
   validation (the merge base with `origin/qa`).
3. Runs the engine tests, then **builds and packages once**.
4. Creates immutable beta tags and GitHub releases on that commit.
5. Publishes to GHCR and resolves the **registry manifest digest**.
6. Writes `release-manifest.json` — the release identity every later stage reads.
7. **Waits for RC approval.**
8. Advances `qa` onto the candidate commit (fast-forward preferred).
9. Deploys that exact digest to QA.
10. **Waits for QA approval.**

If the branch has no configured release channel, or nothing changed, the run fails
with that reason rather than passing green and doing nothing.

### …approve a release?

The run pauses three times, each on its own environment, each gating a different
decision:

| Gate | Environment | Who | Decision |
| --- | --- | --- | --- |
| RC approval | `rc-approval` | Release manager | The built candidate may go to QA |
| QA approval | `qa-approval` | QA | The QA-tested digest may ship |
| Production approval | `production-approval` | Development manager | The QA-approved release may be promoted into `main` and production |

The job name shows what you are approving, for example:

```text
QA approval: api api/v1.18.0-beta.1 @ 7f31ab4…
```

Open the run, check the **Release identity** and **QA-approved release** summaries
(release id, commit, version, digest per component), and approve. QA's approval is
recorded against `git_sha + artifact_digest + release_id` — not against "whatever
is on the qa branch". If the digest QA actually ran does not match the released
digest, the approval cannot even be written.

After RC approval, the candidate is deployed to QA. After QA approval, RC tags and
the RC registry tag are applied to the approved digest. After production approval:

- `main` advanced onto the approved commit, plus stable release tags.
- Production deploys **the same digest**, after proving it equals the approved one
  and that no build output exists in the job.

End to end:

```text
Candidate:            release 1.18.0-beta.1, git_sha 7f31ab4…  (HEAD verified == 7f31ab4)
Build:                ghcr.io/acme/orders, digest sha256:a872…  (built once)
RC approval:          approved
qa:                   fast-forwarded to 7f31ab4
QA:                   deployed sha256:a872…   approved: yes
Production approval:  approved
Main:                 advanced to include 7f31ab4
Production:           deployed sha256:a872…   rebuilt: false
Release tag:          api/v1.18.0 → 7f31ab4
```

### …redeploy something that already shipped?

**Actions → Redeploy Approved Release**, with the Release Candidate run ID and the
target environment. It re-reads the approved identity from that run, asserts the
manifests still match, and redeploys the same digest. It never builds and never
moves a branch. This is a recovery path, not a normal step.

### …push directly to `qa` or `main`?

You do not. Those branches are owned by the pipeline and, once governance is
applied, are writable only by the automation identity. Dispatching a release
candidate *from* `qa` or `main` is also rejected.

## Workflow reference

| Workflow | Trigger | Produces | Approval |
| --- | --- | --- | --- |
| [CI](.github/workflows/ci.yml) | Push to any non-release branch, any PR | Nothing deployable | — |
| [Development Artifact](.github/workflows/dev-build.yml) | Manual dispatch, or the `build:dev-artifact` PR label | `dev-<shortSha>` artifact + image | — |
| [Release Candidate](.github/workflows/release.yml) | Manual dispatch from a development branch | The immutable release, through QA to production | `rc-approval`, `qa-approval`, `production-approval` |
| [Redeploy Approved Release](.github/workflows/promote.yml) | Manual dispatch | Redeploys an approved digest | Target environment |

GitHub environments: `development`, `beta`, `qa`, `rc`, `production`, plus the
three approval gates `rc-approval`, `qa-approval`, `production-approval`. Only
those three gate on a human by default — each is a separate release decision
(ship to QA, ship from QA, ship to production), held by whoever is accountable
for that decision.

## Configuration

Everything component-specific lives in [.releasepipeline.yml](.releasepipeline.yml):

```yaml
versioning:
  strategy: independent      # each component versions on its own line
  source: git-tags
  defaultBump: minor

branches:
  main: { channel: stable }
  qa:   { channel: rc }
  dev:  { channel: beta }

environments:                # deployment targets; may never declare a build
  qa:         { aliasTag: qa }
  production: { aliasTag: production }

components:
  api:
    path: apps/api
    tagPrefix: api
    build:   { command: dotnet publish ./apps/api -c Release -o .release-output/api }
    package: { path: .release-output/api }
    publishing:
      adapter: container
      image: ghcr.io/agent0x21/pipeline-template-3-api
      dockerfile: apps/api/Dockerfile
```

Two things worth knowing:

- **`aliasTag` is a convenience pointer only.** `:qa` and `:production` move; the
  `sha256:` digest is authoritative and is what deployments resolve.
- **The artifact is environment independent.** There is no `app-qa` or
  `app-production` build. Add an `environments.<name>.deploy.command` to hand the
  digest to your deployment target; the pipeline exports `RELEASE_ENVIRONMENT`,
  `RELEASE_ID`, `RELEASE_GIT_SHA`, `RELEASE_COMPONENT`, `RELEASE_VERSION`,
  `RELEASE_IMAGE`, `RELEASE_IMAGE_DIGEST`, and `RELEASE_IMAGE_REFERENCE` to it.
  With no command configured, the step verifies the digest and does nothing else.

## Local commands

Application:

```powershell
pnpm dev-web            # Vite dev server
pnpm build-web          # type-check + production bundle
pnpm --filter ./apps/web lint
pnpm start-api          # run the API on its HTTP profile
pnpm build              # web + API
```

Release engine:

```powershell
pnpm test-ci            # Pester suite for the release engine
pnpm verify-candidate   # assert HEAD equals a captured SHA
pnpm release-plan       # compute versions and tags for a branch
pnpm release-package    # build, test, package, write provenance
pnpm release-manifest   # combine plan + provenance + digests into the identity
pnpm dev-build          # a development artifact, locally
pnpm test-container-api # build and smoke-test the API container
```

Run `pnpm test-ci` before touching anything under `eng/ci`.

`pnpm release-tags` mutates Git. Use it only from an approved release run.

## First-time repository setup

Apply branch protections and environments once, from an authenticated `gh`
session. Preview first:

```powershell
gh auth login
pnpm github-governance `
  -Repository 'OWNER/REPOSITORY' `
  -Reviewer @('reviewer-user', 'my-org/release-managers') `
  -PreventSelfReview -WhatIf
```

Then run it without `-WhatIf`. It applies two different policies:

- **Development branches** (`dev`): pull-request reviews, stale-review dismissal,
  last-push approval, the `validate` status check, no force pushes or deletions.
- **Promotion branches** (`qa`, `main`): pushes restricted to the `github-actions`
  automation app, no force pushes or deletions, no pull request required — the
  only writer is the promotion job.

Two caveats: required environment reviewers need a public repository on GitHub
Free, and classic branch `restrictions` require an organization-owned repository.
On a user-owned repository, configure a repository ruleset with the automation app
as a bypass actor instead.

## When something fails

The pipeline is built to stop rather than guess. Common stops and what they mean:

| Message | Meaning | Action |
| --- | --- | --- |
| `could not be determined unambiguously` | The candidate SHA was not a full 40-character object name | Re-dispatch; do not pass a short SHA |
| `does not equal the captured candidate SHA` | The checkout drifted from the trigger commit | Re-dispatch the workflow |
| `cannot fast-forward` | `main` advanced independently | The workflow already retries with a merge that preserves the approved SHA; a conflict means you need a new candidate |
| `ref changed during promotion` | Another promotion moved the branch | Re-run the promotion job; the artifact is unaffected |
| `does not equal the QA-approved digest` | Production was handed a different artifact | Stop. Do not override — investigate the mismatch |
| `Production must never rebuild the application` | Build output appeared in a deployment job | A build step was introduced where it must not be |
| `Tag … already exists on another commit` | An immutable tag would have to move | Investigate; never force a tag |

[eng/ci/RECOVERY.md](eng/ci/RECOVERY.md) has full runbooks for partial tags,
metadata failures, registry retries, branch promotion failures, and post-approval
deployment failures.

## Further reading

| Document | Covers |
| --- | --- |
| [eng/ci/RELEASE-STANDARD.md](eng/ci/RELEASE-STANDARD.md) | The release standard, the four states, the full guardrail table |
| [eng/ci/README.md](eng/ci/README.md) | The release engine in depth: versioning, promotion, deployment, governance |
| [eng/ci/RECOVERY.md](eng/ci/RECOVERY.md) | Failure runbooks |
| [eng/ci/MIGRATION.md](eng/ci/MIGRATION.md) | Moving an existing repository onto component-scoped tags |
| [eng/ci/PROVIDER-MAPPINGS.md](eng/ci/PROVIDER-MAPPINGS.md) | Azure DevOps and Jenkins equivalents |
| [eng/ci/templates/README.md](eng/ci/templates/README.md) | Starter `.releasepipeline.yml` files |
| [AGENTS.md](AGENTS.md) | Contribution conventions |
