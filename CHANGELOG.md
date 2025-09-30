# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/ollien/twine/compare/v0.4.0..
[0.4.0]: https://github.com/ollien/twine/compare/v0.3.0..v0.4.0
[0.3.0]: https://github.com/ollien/twine/compare/v0.2.0..v0.3.0
[0.2.0]: https://github.com/ollien/twine/compare/v0.1.1..v0.2.0
[0.1.1]: https://github.com/ollien/twine/compare/v0.1.0..v0.1.1
[0.1.0]: https://github.com/ollien/twine/releases/tag/v0.1.0
