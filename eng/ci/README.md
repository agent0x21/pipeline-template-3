# ReleasePipeline

`ReleasePipeline` is the provider-neutral PowerShell core for this repository's CI/CD framework. It uses Git tags as the canonical version source and treats each configured component as independently releasable.

Read [RELEASE-STANDARD.md](RELEASE-STANDARD.md) first: it defines the difference between a development build, a release candidate, a QA-approved release, and a production release, and what causes each transition.

## Workflows

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Every push to a non-release branch, every pull request | Lints, builds, and runs the release-engine tests. Produces no artifact and creates no tag. |
| `.github/workflows/dev-build.yml` | Manual dispatch, or the `build:dev-artifact` pull-request label | Builds a development artifact `dev-<shortSha>` for one branch. Not a release candidate. |
| `.github/workflows/release.yml` | Manual dispatch from a development branch | The full release candidate lifecycle: build once, publish, advance `qa`, deploy QA, QA approval, advance `main`, deploy production. |
| `.github/workflows/promote.yml` | Manual dispatch | Recovery only: redeploys an already-approved release identity to QA or production. Never builds. |

Nobody types a commit SHA in any of these. The SHA is captured from the trigger context and verified against the checked-out `HEAD` before anything is built.

### Requesting a development artifact

Run the **Development Artifact** workflow on your branch, or label a pull request `build:dev-artifact`. Leave `components` empty to build everything, or pass a comma-separated subset. The result is traceable to branch, SHA, artifact version, and registry digest:

```text
branch:  dev/new-checkout
git_sha: 93abc12...
artifact: ghcr.io/agent0x21/pipeline-template-3-api:dev-93abc12ab34c
digest:   sha256:1234...
```

Development builds are grouped per branch, so concurrent branches never block each other, and a newer request on the same branch supersedes the older one.

### Creating a release candidate

Run the **Release Candidate** workflow from the development branch you want to ship. The dispatch context supplies the SHA. The candidate scope is computed from the merge base with `origin/qa`, so a candidate covers everything that branch adds to the source currently under QA validation.

From that point the artifact is immutable. `release-manifest.json` records the release identifier, the candidate SHA, and each component's archive checksum and registry manifest digest; every later stage consumes that document instead of a branch tip.

Local equivalents:

```powershell
pnpm verify-candidate -ExpectedSha <sha>
pnpm release-plan -Branch dev
pnpm release-package
pnpm release-manifest -PlanPath ./release-plan.json -ProvenancePath ./artifacts/provenance.json -CandidateSha <sha>
```

## Local usage

Install the YAML parser and the pinned Pester test dependency once, then plan and package:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser
pwsh ./eng/ci/New-ReleasePlan.ps1 -Branch dev
pwsh ./eng/ci/Invoke-ReleasePackage.ps1 -PlanPath ./release-plan.json
```

Manual overrides are normalized JSON maps:

```powershell
./eng/ci/New-ReleasePlan.ps1 -VersionBump patch `
  -ComponentOverridesJson '{"api":"major"}' `
  -ExactVersionsJson '{}'
```

The precedence order is component override, workflow-wide override, then `versioning.defaultBump` (which defaults to `minor`). Tags use `<tagPrefix>/v<SemVer>`. Beta and RC sequence numbers are calculated from existing tags, independently for each component, base version, and channel.

A parentless repository commit is treated as a bootstrap change: every configured component present in that commit receives its initial release version. For an existing repository, use the manual GitHub `release_all` input (or `New-ReleasePlan.ps1 -ReleaseAll`) only when an approved release must include every configured component regardless of source changes.

Channel version floors prevent branch regressions: QA releases must be above the latest stable version, and development releases must be above both the latest stable and QA/RC versions. The same validation applies to exact-version overrides; reruns of an existing tag remain idempotent.

Configuration loading rejects duplicate tag prefixes, invalid or escaping component paths, missing dependencies, dependency cycles, and unsupported branch channels. Component paths and optional legacy `build.solution` paths must exist relative to the configuration file. When a release tag for the planned component and channel already points to the planned commit, the plan is treated as a rerun and reuses that immutable version.

Tag pushes are atomic and retry transient push failures up to three times. If another runner creates the same tag first, the provisional local tag is removed; a matching remote commit is treated as an idempotent rerun, while a different remote commit fails safely and requires a newly reviewed plan.

The GitHub Actions adapter retains release workflow artifacts for 90 days and publishes an idempotent GitHub release record for each tagged component. It also attaches the verified deployable ZIP to that component's GitHub release. The provider-specific metadata and asset scripts use `GITHUB_TOKEN`; their behavior is intentionally kept outside the provider-neutral release module.

Each stage runs with least privilege: the build/package job has read-only repository permissions, tagging and branch promotion jobs add `contents: write`, and only the publication and deployment jobs receive `packages: write` and `id-token: write`.

Configure the GitHub governance from an authenticated `gh` session. This is idempotent and does not accept or print a token:

```powershell
gh auth login
pwsh ./eng/ci/providers/github/Set-GitHubReleaseGovernance.ps1 `
  -Repository 'OWNER/REPOSITORY' `
  -Reviewer @('reviewer-user', 'my-org/release-managers') `
  -PreventSelfReview
```

The script applies two different policies. Development branches (`dev` by default) keep pull-request reviews, stale-review dismissal, last-push approval, conversation resolution, the `validate` status check, and no force pushes or deletions: that is where humans work. Promotion branches (`qa` and `main`) are owned by the pipeline — pushes are restricted to the `github-actions` automation app (override with `-AutomationApp`), force pushes and deletions stay disabled, and no pull request is required, because the only writer is the promotion job advancing the branch onto the QA-approved commit.

It also creates the `development`, `beta`, `qa`, `rc`, `production`, `rc-approval`, `qa-approval`, and `production-approval` environments. Only the three `-approval` environments carry required reviewers by default (change this with `-ApprovalEnvironments`): `rc-approval` gates the built candidate before QA receives it, `qa-approval` is QA's sign-off on the tested digest, and `production-approval` gates `main`/production being advanced after QA approval, separately from QA's own sign-off. Preview the API changes first with `-WhatIf`. On GitHub Free, required environment reviewers require a public repository; private repositories need a compatible paid plan. Classic `restrictions` on a branch require an organization-owned repository; on a user-owned repository, use a repository ruleset with the automation app as a bypass actor instead.

On a user-owned repository, use [`Set-GitHubPromotionBranchRulesets.ps1`](providers/github/Set-GitHubPromotionBranchRulesets.ps1) for `qa`/`main` instead of the classic-protection branch in `Set-GitHubReleaseGovernance.ps1`, which cannot restrict pushes on a personal account. It configures a ruleset per promotion branch that blocks force pushes and deletion, does not require a pull request (the pipeline pushes directly), and grants no bypass actor. It cannot, however, stop the repository owner from manually opening and merging a PR into `qa`/`main` — on a personal repository the pipeline and the owner push as the same GitHub identity, so no ruleset can tell them apart. That only becomes possible once the release workflow pushes under its own distinct identity (a GitHub App installation token or a dedicated bot account) instead of the owner's account.

`-PreservePromotionCommits` remains available to disable squash and rebase merging repository-wide. It is no longer required for traceability — the pipeline advances `qa` and `main` itself and never squashes or cherry-picks the approved commit — but it keeps developer merges into `dev` from rewriting commits that a candidate may already reference.

### Preserving the approved source commit through QA and production

`Update-PromotionBranch.ps1` advances a protected branch onto the approved commit:

* **Fast-forward** when the branch is an ancestor of the candidate. This is preferred: the QA-approved SHA is unchanged.
* **Already contains / up to date** when the approved commit is already in the branch. No ref update.
* **Merge commit** when the branch advanced independently. The branch tip is the first parent and the approved commit the second, so the approved SHA stays in ancestry and remains the artifact source identity. The artifact is never rebuilt from the merge commit, and `promotion-<branch>.json` records the relationship between `approvedSha` and `mergeCommit`.

Cherry-pick, squash, and rebase are never used for promotion because they create a new SHA. Without `-AllowMerge` a divergent branch fails the release instead of being forced. The push is a plain, non-forced ref update from a commit that descends from the branch head that was read at the start, so a competing promotion causes a rejection rather than an overwrite; `-ExpectedSha` adds an explicit expected-head assertion on top.

Promotion of the artifact itself never involves a build. `New-ManifestPromotionPlan.ps1` derives the RC and stable versions from the persisted release identity and always targets the candidate SHA; `Invoke-ArtifactPromotion.ps1` creates the tags; `Publish-PromotedImageTag.ps1` applies the promoted registry tag to the approved digest and re-reads the digest afterwards to prove it did not change. Only `beta -> rc -> stable` is allowed, and stable requires an RC tag on the approved commit. `New-ArtifactPromotionPlan.ps1` remains for provenance-driven recovery promotions.

Registry publication is opt-in per component through `publishing.adapter`: `nuget`, `npm`, or `container`. Generate a publication plan with `pnpm registry-plan -ProvenancePath ...`; for promotion, also pass `-PromotionPlanPath promotion-plan.json`. The plan carries the immutable source artifact digest while using the target RC/stable version, without copying credentials. `pnpm registry-publish` invokes `dotnet nuget push`, `npm publish --provenance`, or `docker push`, and for container pushes it resolves and records the registry manifest digest. Authenticate those tools in the provider workflow using a short-lived/OIDC credential or a preconfigured credential helper; never put tokens in command-line arguments. `id-token: write` is granted only to publication jobs.

### Deployment

`Invoke-EnvironmentDeployment.ps1` is the only thing that deploys, and it contains no build path. It resolves each component by `image@sha256:...` from the release manifest, pulls that exact digest to prove the registry serves it, optionally publishes the environment's convenience alias (`qa`, `production`), and then invokes the environment's `deploy.command` from `.releasepipeline.yml` with `RELEASE_ENVIRONMENT`, `RELEASE_ID`, `RELEASE_GIT_SHA`, `RELEASE_COMPONENT`, `RELEASE_VERSION`, `RELEASE_IMAGE`, `RELEASE_IMAGE_DIGEST`, and `RELEASE_IMAGE_REFERENCE` exported. With no `deploy.command` configured, the step records a verified digest resolution and nothing else — wire your deployment target in there.

Production additionally passes `-RequireApprovedRelease -ApprovedManifestPath`, so the release fails unless the built identity and the QA-approved identity match on release id, candidate SHA, component set, versions, archive checksums, and artifact digests. An environment that declares a `build` key is rejected at configuration load, and `Assert-NoApplicationBuild.ps1` fails the production job if any component's package output is present in the workspace.

The API is configured as a GHCR container component. Packaging builds `apps/api/Dockerfile`, saves its versioned image as a SHA-256-provenanced `.container.tar` artifact, and the publication job reloads that artifact before pushing it. Run `pnpm test-container-api` to build and smoke-test the API container locally.

`pnpm test-ci-legacy` builds the included non-SDK-style .NET Framework 4.8 solution through `vswhere.exe` and MSBuild. Run it on a Windows machine with Visual Studio Build Tools and the [.NET Framework 4.8 Developer Pack](https://aka.ms/msbuild/developerpacks) installed; the command checks for the targeting pack before starting a build.

Packaging creates generic ZIP files and `artifacts/provenance.json`. The explicit `New-ReleaseTags.ps1` step is the only operation that mutates Git. It is idempotent when the requested tag already points to the planned commit and fails safely on a conflicting tag.

For legacy .NET components, set `type: legacy-dotnet-framework` and provide a PowerShell build command that discovers MSBuild (for example through `vswhere.exe`) and invokes it. Provider-specific workflows should pass normalized parameters to these scripts rather than embedding release logic.

See [PROVIDER-MAPPINGS.md](PROVIDER-MAPPINGS.md) for Azure DevOps and Jenkins examples, normalized input mappings, approval boundaries, and artifact-transfer requirements.

See [MIGRATION.md](MIGRATION.md) for moving from repository-global tags to component-scoped tags, selecting bootstrap version floors, and safely planning the first migrated release.

See [templates/README.md](templates/README.md) for copyable single-application and polyglot-monorepo `.releasepipeline.yml` starting points.

See [RECOVERY.md](RECOVERY.md) for safe handling of partial tags, metadata failures, registry retries, and promotion/artifact-transfer failures.

See [RELEASE-STANDARD.md](RELEASE-STANDARD.md) for the release standard itself and the full guardrail table.
