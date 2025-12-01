# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2025-12-01
### Fixed
- Fixed typo in doc-comment that used incorrect name for `track_outcome`.

## [0.5.0] - 2025-11-30
### Changed
- `ignore_outcome` has been replaced with ~~`show_outcome`~~ `track_outcome`, to make the default
more clear. As an upgrade, `ignore_outcome` is still accepted, but deprecated.
This will be removed in a future release.

### Fixed
- Recursive calls can now be tracked with `track_outcome: true`. Previously,
`Twine` incorrectly assumed that there would be only one active call per pid,
which was incorrect.
- Fixed memory runaway in tail-recursive calls when using `track_outcome: false`.
- To reduce overhead, arguments/return values are mapped before being stored in memory when `track_outcome: true` is specified.
- Error messages are more clear when giving incorrect `&function/arity` syntax.

## [0.4.3] - 2025-10-07
### Changed
- ⚠️ Breaking Change: `ignore_outcome: true` to be the default. This is a
useful tool, but can introduce extra overhead when used on production systems,
so this has been changed.

## [0.4.2] - 2025-09-30

### Fixed
- Fix process leak of call tracker after tracing process had terminated

## [0.4.1] - 2025-09-30

### Fixed
- Fix minor process leak when there are no matching functions to trace.

## [0.4.0] - 2025-09-30

### Changed
- ⚠️ Breaking Change: `mapper` is now `arg_mapper`
- ⚠️ Breaking Change: `recv_calls` now sends a `Twine.TracedCall` structure, instead of a bare tuple.
- Long function calls now wrap more gracefully.

### Added
- Added support for tracing function outcomes, including function return values.
- Added support for tracing via function capture syntax (`&MyModule.my_function/2`).

## [0.3.0] - 2025-08-10

### Added
- Added `recv_calls`, to receive calls in the `iex` shell's mailbox
- Added support for guards when matching calls

## [0.2.0] - 2025-07-27

### Added
- Cleaned up output, it is no longer based on exceptions
- Hex docs now include a dedicated page
- Added warning when using pin operator

## [0.1.1] - 2025-07-27

### Fixed
- Suppress warnings when calls use non-underscore prefixed argument names.

## [0.1.0] - 2025-07-27

Initial Release

[Unreleased]: https://github.com/ollien/twine/compare/v0.5.0..
[0.5.0]: https://github.com/ollien/twine/compare/v0.4.3..v0.5.0
[0.4.3]: https://github.com/ollien/twine/compare/v0.4.2..v0.4.3
[0.4.2]: https://github.com/ollien/twine/compare/v0.4.1..v0.4.2
[0.4.1]: https://github.com/ollien/twine/compare/v0.4.0..v0.4.1
[0.4.0]: https://github.com/ollien/twine/compare/v0.3.0..v0.4.0
[0.3.0]: https://github.com/ollien/twine/compare/v0.2.0..v0.3.0
[0.2.0]: https://github.com/ollien/twine/compare/v0.1.1..v0.2.0
[0.1.1]: https://github.com/ollien/twine/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/ollien/twine/releases/tag/v0.1.0
