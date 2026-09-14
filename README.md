# pipeline-template-2
Build, Version, Package &amp; Deploy

See [application versioning and artifact builds](scripts/versioning/README.md) for the PowerShell commands, release policy, dependency detection, and CI workflow.

## Release standard

Development branches may evolve independently and may create development artifacts
on demand for branch-level testing. A formal release candidate begins only when a
specific Git SHA is selected for promotion. That release artifact is built once
from that SHA, QA validates that exact artifact, and Production deploys the same
artifact without rebuilding it. The pipeline automatically promotes the approved
source commit into the appropriate protected source branches without requiring
humans to manually select SHAs.

See [eng/ci/RELEASE-STANDARD.md](eng/ci/RELEASE-STANDARD.md) for the difference
between a development build, a release candidate, a QA-approved release, and a
production release, and for what causes each transition.

| Workflow | Trigger | Produces |
| --- | --- | --- |
| `CI` | push to a non-release branch, pull request | Nothing deployable |
| `Development Artifact` | manual dispatch, or the `build:dev-artifact` PR label | `dev-<shortSha>` artifact for branch testing |
| `Release Candidate` | manual dispatch from a development branch | The immutable release artifact, QA, approval, production |
| `Redeploy Approved Release` | manual dispatch | Redeploys an approved digest (recovery only) |

## Release pipeline tooling

The reusable Windows/PowerShell release framework is in `eng/ci/ReleasePipeline`. It reads `.releasepipeline.yml`, uses component-scoped Git tags, defaults to minor bumps, and emits JSON release plans, generic ZIP artifacts with provenance, and a `release-manifest.json` release identity.

```powershell
pnpm release-plan
pnpm release-package
pnpm test-ci
```

Tag creation is a separate explicit step; use `pnpm release-tags` only from an approved release run. Install `powershell-yaml` for local YAML parsing:

```powershell
Install-Module powershell-yaml -Scope CurrentUser
```
