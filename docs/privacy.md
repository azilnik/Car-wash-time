# Privacy

A public fork of this repo leaks a few things through normal workflow activity. None of it is dangerous on its own, but if you set `LOCATION` to a street address, that address ends up in your repo's git history. Worth knowing before you commit.

## What leaks on a public fork

- **`state.json` is committed back to `main` after every run.** With `LOCATION` set, it includes the text you typed (e.g. `"123 Main St, Anytown, OH"`), the resolved coordinates, and the city name. All of that is readable in the repo's git history.
- **Workflow run logs are public** and echo the geocode result (`Geocoded 'X' → lat, lon (city, country)`) and your ntfy topic.
- **ntfy topics are public by design.** Anyone who knows the topic name can subscribe and read your notifications.

Repo variables themselves are only visible to collaborators in Settings, but their values leak through the runtime artifacts above.

## Option A: Keep your setup private (recommended)

GitHub won't let you make a fork private, so duplicate the repo to a new private one instead.

```bash
gh repo create you/car-wash-time-private --private --clone=false
git clone --bare https://github.com/azilnik/Car-wash-time.git
cd Car-wash-time.git
git push --mirror git@github.com:you/car-wash-time-private.git
```

Now you have a disconnected private copy. Set your real `LOCATION` and `NTFY_TOPIC` there. Leave any public fork on demo defaults.

Private repos get 2,000 free Actions minutes per month. This workflow uses about 5.

### Pulling future upstream updates

```bash
git remote add upstream https://github.com/azilnik/Car-wash-time.git
git fetch upstream
git merge upstream/main
git push origin main
```

See [GitHub's docs on duplicating a repository](https://docs.github.com/en/repositories/creating-and-managing-repositories/duplicating-a-repository) for the full flow.

## Option B: Keep your fork public, minimize the leak

If a private repo is overkill for you:

- Use `LATITUDE` and `LONGITUDE` directly. Leave `LOCATION` unset. Your typed input never hits `state.json`. Only the coordinates do, which is a weaker privacy signal than a street address.
- Pick a long, random `NTFY_TOPIC` you don't share.
