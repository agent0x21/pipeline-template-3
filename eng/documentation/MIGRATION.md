# Cutover to main-based development

Do not run the old and new release pipelines concurrently.

1. Inventory open PRs, in-flight releases and unique commits on dev/qa. Reconcile needed work into main through reviewed PRs. Preserve historical tags, releases and image digests.
2. Merge the conversion and make main the default integration branch. Retarget open development PRs.
3. Finish or cancel old beta-based release workflows. Existing v1 manifests remain historical/manual recovery records; new handoffs require v2 identities.
4. Remove automation-only promotion protections from main and any overlapping old rulesets that prevent PR merges. Replace them with required CI (`validate`), PR review, no force push and no deletion.
5. Configure Windows runners with the Windows label, pnpm 12.3.4, .NET 10/WPF tooling, Git, GitHub CLI, PowerShell 7 and Docker/Linux-container support. Use isolated runners for untrusted PRs; never expose publishing credentials to PR jobs.
6. Create DEV, QA and PROD GitHub Environments. DEV has no reviewers. QA reviewers attest to completed manual testing; PROD reviewers separately authorize stable publication. Restrict workflow refs to main; source selection is validated separately by the release engine.
7. Configure contents/packages permissions for GitHub Actions and GHCR ownership/access. Configure QA/PROD required reviewers, prevent self-review by default and disable administrator bypass. Confirm the repository's GitHub plan supports required environment reviewers.
8. Review protected release tag rules and migrate required environment secrets. DEV/QA/PROD do not need hosting credentials yet.
9. Exercise DEV creation, an RC/QA/PROD cycle, retry after staged publication, and an older-line hotfix in a test repository.
10. Retire dev/qa and any other environment branches only after confirming no unique work remains. Remove obsolete development/beta/rc/production and approval environments after migrating settings.

Governance automation is opt-in and never runs from a release workflow:

```powershell
# GH_TOKEN must have repository administration permissions; prefer a short-lived token.
./eng/ci/providers/github/Set-GitHubReleaseGovernance.ps1 -Repository owner/repo -QaReviewer qa-user -ProductionReviewer release-user -WhatIf
# Inspect the proposed settings before running without -WhatIf.
```

The script updates main protection, DEV/QA/PROD reviewers and branch policies, and immutable tag rules. It does not remove old rulesets, delete branches, migrate secrets or change the default branch. Those are explicit cutover tasks.

No history rewriting or release deletion is required. The old promote-branch command and branch synchronization scripts are removed.
