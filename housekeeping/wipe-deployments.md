For **GitHub Deployments** in the current repository, there isn’t a dedicated `gh deployment delete` command, so use `gh api`. GitHub’s API only allows deleting deployments that are inactive when the repo has multiple deployments.

To delete every deployment that GitHub allows you to delete:

```powershell
gh api --paginate "/repos/agent0x21/pipeline-template-3/deployments?per_page=100" --jq '.[].id' | ForEach-Object {
    gh api --method DELETE "/repos/agent0x21/pipeline-template-3/deployments/$_"
}
```

You may get `422` errors for deployments that are still considered active. To first mark every deployment inactive, then delete them:

```powershell
$deployments = gh api --paginate "/repos/agent0x21/pipeline-template-3/deployments?per_page=100" --jq '.[].id'

$deployments | ForEach-Object {
    gh api --method POST "/repos/agent0x21/pipeline-template-3/deployments/$_/statuses" `
        -f state='inactive'
}

$deployments | ForEach-Object {
    gh api --method DELETE "/repos/agent0x21/pipeline-template-3/deployments/$_"
}
```

The `{owner}` and `{repo}` placeholders are automatically resolved by `gh` from your current repository.

To preview deployments first:

```powershell
gh api --paginate "/repos/agent0x21/pipeline-template-3/deployments?per_page=100" `
    --jq '.[] | [.id, .environment, .ref, .created_at] | @tsv'
```

One caveat: GitHub specifically restricts deletion of active deployments, so the **mark inactive → delete** version is the one I’d use for a full cleanup.
