# Release recovery

## Retry the original identity

Use GitHub's rerun on the original Build Release Candidate run. Its run ID identifies the durable release set. The source SHA and plan are restored rather than resolving today's main.

- Before a build bundle is uploaded: the reserved version may be rebuilt because no deployable component artifacts have been published.
- After the bundle is uploaded: restore the exact bundle; never build again. Registry/tag/component publication can resume from these bytes.
- An existing release asset with different bytes is an error, never an invitation to overwrite it.
- If a registry version already exists, its image identity must match the staged image before publication proceeds.
- If a reserved tag points elsewhere, stop and investigate. Never force a tag.
- If durable staging artifacts are missing after publication began, recover the original bytes from storage; do not reconstruct them by rebuilding.

Failed QA preparation can be rerun against the same release ID. Failed QA sign-off can be rerun against the same prepared manifest. A new QA run produces a separate sign-off record; use the successful run ID in PROD.

Failed stable promotion can be retried with the same release and QA run. Existing stable releases must carry the same source manifest checksum. Each ZIP and container digest is checked again. A stable release owned by another RC fails, even if the source commit happens to match.

Partial stable publication is not a deployment. Do not manually install a partial set; wait until Promote PROD has succeeded for all listed components.

## Expired Actions artifacts

GitHub Releases retain the manifest, build bundle, ZIPs and approval records; GHCR retains images. Prepare QA and Promote PROD consume these durable records, not expiring Actions downloads. Keep GitHub release assets and referenced registry digests out of retention cleanup.

## Manual installation and rollback

Handoff records mean prepared, not deployed. Record actual environment installation details in the operator's change record: release ID, SHA, ZIP checksums/image digests, environment, operator and timestamp.

Rollback is manual installation of a previously approved artifact set. Do not rebuild an old commit or move a production branch. Current workflows authorize stable publication, not fleet state or installation order.

## Legacy releases

Historical v1/beta manifests are not automatically trusted as new QA sign-off. Legacy helpers remain for inspecting provenance, but new workflows require v2 records. Recover historical production artifacts manually from their original releases/digests, with an operator-recorded approval. Do not fabricate a v2 approval for an unverified old build.
