# Adding dictator to jindrichskupa/homebrew-tap

The tap already holds `Casks/franta.rb`. Nothing here touches it.

**Why a formula and not a cask.** A cask installs a prebuilt binary; franta is
one, and GoReleaser generates its cask. dictator is shell source, which is what
formulae are for. The two live in separate directories, `Formula/` and
`Casks/`, and are installed differently:

```bash
brew install --cask jindrichskupa/tap/franta   # cask
brew install        jindrichskupa/tap/dictator # formula
```

## Automatic

Once `HOMEBREW_TAP_TOKEN` is set in the dictator repository, the `tap` job of
`.github/workflows/release.yml` writes `Formula/dictator.rb` on every tag,
with `url` and `sha256` filled in. Nothing to do by hand.

## Manual, the first time or if CI is unavailable

```bash
V=v0.1.0
curl -sSfL "https://github.com/jindrichskupa/dictator/archive/refs/tags/$V.tar.gz" -o /tmp/d.tgz
shasum -a 256 /tmp/d.tgz

git clone git@github.com:jindrichskupa/homebrew-tap.git
mkdir -p homebrew-tap/Formula
cp packaging/homebrew/dictator.rb homebrew-tap/Formula/dictator.rb
# edit url  -> .../archive/refs/tags/$V.tar.gz
# edit sha256 -> the checksum printed above
cd homebrew-tap && git add Formula/dictator.rb && git commit -m "dictator $V" && git push
```

Verify:

```bash
brew install jindrichskupa/tap/dictator
brew test    dictator
brew audit --strict --online jindrichskupa/tap/dictator
```

## Suggested tap README changes

The tap README says "Casks in `Casks/` are generated automatically by
GoReleaser". That is no longer the whole story once a formula is present.

Replace the **Available** table with:

```markdown
## Available

| Name       | Type    | Description                                  | Source |
|------------|---------|----------------------------------------------|--------|
| `franta`   | cask    | Terminal UI for Apache Kafka                 | [jindrichskupa/franta](https://github.com/jindrichskupa/franta) |
| `dictator` | formula | Claude Code session registry across repos    | [jindrichskupa/dictator](https://github.com/jindrichskupa/dictator) |
```

and the **Install** section with:

```markdown
## Install

```bash
brew install --cask jindrichskupa/tap/franta
brew install        jindrichskupa/tap/dictator
```

Or tap first:

```bash
brew tap jindrichskupa/tap
brew install --cask franta
brew install dictator
```
```

and extend the **Notes** section:

```markdown
## Notes

Casks in `Casks/` are generated automatically by
[GoReleaser](https://goreleaser.com) on each upstream release — do not edit by
hand.

Formulae in `Formula/` are written by the upstream project's own release
workflow — also generated, also not to be edited here. The source of
`dictator.rb` is `packaging/homebrew/dictator.rb` in
[jindrichskupa/dictator](https://github.com/jindrichskupa/dictator).
```
