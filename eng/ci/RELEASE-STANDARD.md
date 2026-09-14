# Release standard

> Development branches may evolve independently and may create development
> artifacts on demand for branch-level testing. A formal release candidate begins
> only when a specific Git SHA is selected for promotion. That release artifact is
> built once from that SHA, QA validates that exact artifact, and Production
> deploys the same artifact without rebuilding it. The pipeline automatically
> promotes the approved source commit into the appropriate protected source
> branches without requiring humans to manually select SHAs.

## The four states

| State | What it is | What creates it | Lifetime |
| --- | --- | --- | --- |
| **Development build** | A deployable artifact for branch-level testing. Tagged `dev-<shortSha>`. Not a release candidate. | A developer runs the **Development Artifact** workflow, or adds the `build:dev-artifact` label to a pull request. | Disposable. 7-day workflow retention; registry tags are replaceable. |
| **Release candidate** | The first immutable artifact. Built exactly once from one exact Git SHA and published with a resolved registry digest. | A release manager runs the **Release Candidate** workflow from a development branch. | Immutable from creation. |
| **QA-approved release** | A release candidate that QA deployed and signed off, recorded against `git_sha + artifact_digest + release_id`. | A required reviewer approves the `qa-approval` environment. | Immutable. |
| **Production release** | The QA-approved artifact, deployed to production. Byte-identical to what QA ran. | Automatic, after the QA approval. | Immutable. |

## What causes each transition

```text
commit on dev/feature-a
        │  normal CI runs (ci.yml). No artifact.
        │
        ├─ developer requests a development artifact ─────────► development build
        │     dev-build.yml, explicit dispatch or PR label
        │     SHA captured from the branch/PR head
        │
        └─ release manager dispatches release.yml ────────────► release candidate
              SHA captured from the dispatch context,
              HEAD verified against it, built once,
              published, digest resolved, manifest persisted
                        │
                        ├─ qa advanced onto the candidate SHA (ff, else merge)
                        ├─ QA deploys the candidate digest
                        │
                        └─ required reviewer approves ────────► QA-approved release
                                  approval names the SHA,
                                  release id and digest
                                    │
                                    ├─ rc tags + rc image tag (same digest)
                                    ├─ main advanced onto the approved SHA
                                    ├─ stable tags on the approved SHA
                                    │
                                    └─ production deploys the ► production release
                                       approved digest, no build
```

A development build never becomes a release candidate. To ship the code a
development build exercised, dispatch the Release Candidate workflow: it rebuilds
from the selected SHA under the release rules and that build becomes the one and
only release artifact.

## Identity rules

```text
branch        = source-history pointer     (never the identity of a release)
commit SHA    = exact source identity
artifact      = exact executable identity  (registry manifest digest)
environment   = where an artifact is deployed
```

* `release-manifest.json` is the durable release identity. Every stage after the
  candidate build consumes it. No stage re-reads the head of `qa` or `main` to
  decide what to ship.
* `qa`, `latest`, and `production` image tags exist as convenience aliases. The
  `sha256:` manifest digest is authoritative and is what deployments resolve.
* Release tags are immutable markers on the approved source commit:
  `<component>/v<version>-beta.N`, `qa-approved/<component>/v<version>`,
  `<component>/v<version>-rc.N`, and `<component>/v<version>`. A published tag is
  never moved; an attempt to move one fails the release.
* The artifact is environment independent. Configuration, secrets, endpoints, and
  feature flags are supplied at deployment time through the environment's
  `deploy.command` and the `RELEASE_*` variables the pipeline exports.

## Guardrails

The pipeline fails, rather than proceeding, when:

| Condition | Enforced by |
| --- | --- |
| The candidate SHA is not a full, unambiguous Git object name | `Assert-CandidateCommit.ps1` |
| Checked-out `HEAD` differs from the captured candidate SHA | `Assert-CandidateCommit.ps1`, re-run in the tagging job |
| An artifact cannot be traced to the candidate SHA | `New-ReleaseManifest` (every release's commit must equal the candidate) |
| A container release has no resolved registry digest | `New-ReleaseManifest` |
| QA deployed a digest other than the released digest | `New-QaApprovalRecord.ps1` |
| Production would deploy a digest other than the approved one | `Assert-ReleaseIdentity`, via `Invoke-EnvironmentDeployment.ps1 -RequireApprovedRelease` |
| A promoted tag resolves to a different digest | `Publish-PromotedImageTag.ps1` |
| Production contains application build output | `Assert-NoApplicationBuild.ps1` |
| An environment declares a build step | `Import-ReleaseConfig` |
| The approved SHA cannot be safely promoted into `main` | `Update-PromotionBranch.ps1` (no `-AllowMerge`, or merge conflict) |
| `qa`/`main` changed unexpectedly during promotion | `Update-PromotionBranch.ps1` expected-head check and non-forced push |
| Two release candidates promote concurrently | `concurrency: release-candidate` plus the non-forced ref update |
| An existing immutable release tag would move | `New-ReleaseTag` |

Development artifact builds are deliberately outside all of this: they are grouped
per branch, so an active release or another branch's build never blocks them.
