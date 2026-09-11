# framework-size-report

> Measure what your framework actually costs an app, diff it on every pull request, and fail the build when it grows past its budget.

[![CI](https://github.com/sentinelden/framework-size-report/actions/workflows/ci.yml/badge.svg)](https://github.com/sentinelden/framework-size-report/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Swift 5.9+](https://img.shields.io/badge/swift-5.9+-orange.svg)](https://swift.org)

```
$ framework-size measure MyKit.framework

  MyKit.framework
  ────────────────────────────────────────────────────
  shipped        1.2 MB   ← budget against this
  on disk        3.4 MB
  resources      118.0 KB

  arm64
    __TEXT        892.0 KB
    __LINKEDIT    2.1 MB    (excluded — stripped before shipping)
    __DATA_CONST  164.0 KB
    __DATA        72.0 KB
    total         1.1 MB
```

On a pull request it posts this instead:

> 🟠 **MyKit.framework grew more than this change is allowed to**
>
> | | Size |
> |---|---|
> | Base | `1.15 MB` |
> | This change | `1.23 MB` |
> | **Delta** | **`+82.0 KB` (+6.96%)** |
> | Budget | `2.0 MB` (headroom `+788.0 KB`) |

## Why

"How much will your SDK add to my app?" is the first question every framework vendor gets, and almost nobody answers it well — because the obvious answer is wrong in two specific ways.

**A file-size number counts `__LINKEDIT`.** Symbol tables, bind opcodes and the code signature can be *most* of an unstripped debug build, and they are stripped before a customer ships. Quoting that number makes your SDK look several times larger than it is, and being wrong in your own disfavour still erodes trust in the measurement.

**Summing a universal binary double-counts.** App Store thinning delivers one architecture to each device. Adding arm64 and x86_64 together roughly doubles what anyone actually pays.

This tool excludes `__LINKEDIT` from the headline figure and uses the largest single architecture, not the sum. It shows everything else in the breakdown so you can see what it did.

## Install

```sh
brew install sentinelden/tap/framework-size
```

From source:

```sh
git clone https://github.com/sentinelden/framework-size-report
cd framework-size-report
swift build -c release
./.build/release/framework-size --help
```

## Usage

```sh
# Measure. Accepts .framework, .app, an .xcframework slice, or a bare binary.
framework-size measure MyKit.framework

# Enforce a ceiling right now.
framework-size measure MyKit.framework --budget 2MB

# Record a measurement, then compare two of them.
framework-size measure MyKit.framework --output head.json
framework-size diff base.json head.json --budget 2MB --tolerance 50KB

# Markdown, for a PR comment.
framework-size diff base.json head.json --format markdown
```

### Budget vs tolerance

Two limits, because they catch different failures and most teams want both.

| | Question it answers | Failure it catches |
| --- | --- | --- |
| `--budget 2MB` | Is the framework too big, full stop? | The absolute ceiling |
| `--tolerance 50KB` | Did *this change* add too much? | Gradual creep |

A budget alone lets a framework drift from 500 KB to 1.9 MB without ever failing. A tolerance alone never notices that the total is already too large.

### Exit codes

| Code | Meaning |
|------|---------|
| `0`  | Within limits, or smaller than base |
| `1`  | Over budget or over tolerance |
| `64` | Could not parse a budget or tolerance |
| `65` | Target missing, or not a Mach-O image |

## GitHub Action

```yaml
# .github/workflows/size.yml
permissions:
  contents: read
  pull-requests: write     # for the PR comment
  actions: read            # to read the baseline artifact

jobs:
  size:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - run: xcodebuild -scheme MyKit -derivedDataPath build
      - uses: sentinelden/framework-size-report@v0.1.0
        with:
          target: build/Build/Products/Release-iphoneos/MyKit.framework
          budget: 2MB
          tolerance: 50KB
```

The baseline comes from the most recent successful run on the pull request's base branch, uploaded as an artifact by this same action. That means **the first run on your default branch seeds the baseline** and pull requests opened afterwards get a real diff. Before that — and on forks without artifact access — it reports the measurement and says there is nothing to compare against, rather than failing.

The PR comment is **sticky**: one comment per pull request, edited on each push. A new comment per push is how size bots get muted.

Set `fail-on-regression: false` to report without blocking while you work down an existing overage.

## Library use

```swift
import FrameworkSizeCore

let base = try Measurer.measure(path: "base/MyKit.framework")
let head = try Measurer.measure(path: "head/MyKit.framework")

let diff = Differ.compare(before: base, after: head,
                          budget: 2 * 1024 * 1024, tolerance: 50 * 1024)
print(Differ.markdown(diff))
```

## What it does not measure

- **App Store download size.** That depends on Apple's compression and on-demand resources, and is only knowable from App Store Connect. This measures install-size contribution, which is the part you control and the part that moves when you change code.
- **Bitcode or LTO effects at the app level.** Your framework's size in isolation is not exactly its cost inside a host app that may deduplicate shared dependencies.
- **Static library contribution.** A `.a` only costs what the linker actually pulls in. Measuring it standalone overstates it — measure the host app before and after instead.

Each of these is a place where a confident number would be a wrong one.

## Contributing

Most useful right now:

1. **`.xcframework` support** — measure every slice and report them together, rather than pointing at one platform's `.framework` inside it.
2. **Section-level breakdown** — `__TEXT,__text` versus `__TEXT,__cstring` tells you *why* something grew, which segment totals do not.
3. **Swift metadata attribution** — mapping `__swift5_*` section growth back to the types that caused it.

```sh
swift test
```

## License

MIT. See [`LICENSE`](LICENSE).

## Who builds this

[Sentinel Den](https://sentinelden.com) — iOS security research and runtime-defense SDKs from Vancouver, BC. We ship twelve SDKs and got asked the size question enough times to write the answer down.
