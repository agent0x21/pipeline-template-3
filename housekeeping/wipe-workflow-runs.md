Delete workflow runs

```powershell
gh run list --limit 10000 --json databaseId --jq '.[].databaseId' | ForEach-Object {
    gh run delete $_
}
```

A compact one-liner:

```powershell
gh run list --limit 10000 --json databaseId --jq '.[].databaseId' | % { gh run delete $_ }
```

That deletes all listed workflow runs from the current GitHub repository.
