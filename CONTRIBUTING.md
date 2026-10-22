# Contributing to Clementine

Thanks for wanting to help. Bug reports, format requests and pull requests are all welcome.

## How changes get in

`main` is protected. Nobody pushes to it directly except the maintainer:

1. **Fork** the repo and create a branch from `main`.
2. Make your change and run `make test` (and `make ui-test` for UI work).
3. **Open a pull request** against `main`. The template asks how you tested it.
4. CI has to pass, every review conversation has to be resolved, and
   [@mustafahalabi](https://github.com/mustafahalabi) has to approve it. New pushes after an approval need a fresh
   approval.
5. The maintainer merges it.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- [AGENTS.md](AGENTS.md) lists decisions that are already made (no sandbox, bundled ffmpeg, every action runnable
  from the CLI…) and the project's conventions. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the
  code fits together, and [docs/TESTING.md](docs/TESTING.md) covers the test suites.
- Homebrew's `ffmpeg` and `webp` are needed for the tests: `brew install ffmpeg webp`.

## Licensing of contributions

Clementine's own code has no open-source license; it's public to read with all rights reserved. By opening a pull
request you agree that your contribution can be included and distributed as part of Clementine under the same
terms.
