From inside the repo, this deletes **all GitHub Releases** in that repository while leaving the Git tags intact:

```bash
gh release list --limit 10000 --json tagName --jq '.[].tagName' | while read -r tag; do gh release delete "$tag" --yes; done
```

If you also want to delete the associated Git tags:

```bash
gh release list --limit 10000 --json tagName --jq '.[].tagName' | while read -r tag; do gh release delete "$tag" --yes --cleanup-tag; done
```

This is destructive and has no bulk undo, so you can preview what will be deleted first with:

```bash
gh release list --limit 10000
```
