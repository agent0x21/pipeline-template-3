From inside the repo, this deletes **all remote tags** from `origin`:

```bash
git tag -l | xargs -r -n 1 git push origin --delete
```

If you also want to remove all **local tags** afterward:

```bash
git tag -l | xargs -r git tag -d
```

To do both:

```bash
git tag -l | tee /tmp/repo-tags.txt | xargs -r -n 1 git push origin --delete && xargs -r git tag -d < /tmp/repo-tags.txt
```

You can preview the tags first with:

```bash
git tag -l
```
