# Bounded native ownership audit

## Reproduce without release side effects

On macOS with the existing Apple compiler and frameworks:

```sh
python3 tests/ownership/run.py --baseline --output /tmp/windows-version-ownership
```

The runner compiles all 18 original native translation units, including the
**full unchanged** `4DPluginAPI.c`, as Objective-C++ with ASan and UBSan.
It calls the real SDK through `gCall4D` into an engine-boundary shim, not
replacement API functions or copied implementation snippets. No project build
phases, signing, packaging, releases, workflow dispatches or external services
are used. Synthetic paths and bytes never reach a filesystem picture importer.
LeakSanitizer is unavailable on macOS; explicit maps check string allocations,
handles and picture reference balances. Packed SDK members are copied into
aligned keys before passing references to STL containers.

The same harness is compiled against immutable `git archive`
`80b6f1d44d7189c91a16fe58e29d0472c09416d5`. Every original tracked file
(including binaries, projects, manifests and manual workflows) is compared
byte-for-byte, exempting only `C_PICTURE.cpp` and the directly related README.
New tests do not alter project membership.

## Inventory and reachability

| Surface | Audit result |
| --- | --- |
| `4DPlugin.cpp`, `4DPlugin.h` | Both dispatcher cases and all helpers read: `Windows_Is_WOW64`, `Windows_Get_version`, `IsWow64`, `getVersion`, `getKernel32Version`, `setVersionString`. The text return calls `C_TEXT::setReturn`/the content setter, not array transfer. No callbacks or native object/collection access. |
| `4DPluginAPI.def`, SDK `FourDPackex` | Actual exported entry is `FourDPackex`, which receives/stores the engine callback and forwards to `PluginMain`, then the two-case dispatcher. |
| Root and bundled `manifest.json` | Two scalar commands: `Windows Is WOW64:L`, `Windows Get version(&L):T`. No text-array signature, but not grounds to exclude wrappers. |
| `C_TEXT.cpp/.h`, `ARRAY_TEXT.cpp/.h` | All methods read, including Objective-C paths, scalar setters, borrowed input copies, independent array allocations, replacement and ownership transfer. |
| `C_PICTURE.cpp/.h` | All methods read, including dormant file-path, byte, conversion, grayscale, size, thumbnail, argument/return, Objective-C image and metadata helpers. Confirmed fixes are confined to this first-party wrapper. |
| `C_BLOB.cpp/.h`, `C_POINTER.cpp/.h` | All methods read. Blob text conversion uses independent C++ strings. Pointer metadata ownership is deferred below. |
| `C_DATE`, `C_INTEGER`, `C_LONGINT`, `C_REAL`, `C_TIME` (`.cpp/.h` each) | All scalar methods read; no owned SDK strings. |
| `ARRAY_BOOLEAN`, `ARRAY_DATE`, `ARRAY_INTEGER`, `ARRAY_LONGINT`, `ARRAY_REAL`, `ARRAY_TIME` (`.cpp/.h` each) | All methods read; no owned SDK strings. Common initial-array-allocation handling remains deferred. |
| `C_TYPES.h`, `4D Plugin_Prefix.pch` | Include graph reaches Apple frameworks, C++ containers, and platform headers; no hidden string owner or callback. |
| `4DPluginAPI.c/.h`, `PublicTypes.h`, `PrivateTypes.h`, `EntryPoints.h`, `Flags.h`, `licence.txt` | Bundled SDK contract/provenance boundary. Production SDK internals are unchanged. No object/collection API in this snapshot. |
| `.vcxproj`, `.vcxproj.filters`, `.sln`, `.xcodeproj/project.pbxproj`, scheme | Both projects compile all 16 wrapper implementations, the SDK and plugin entry. All headers are reachable; `C_TYPES.h` is transitively included. Dormant picture helpers are compiled, although the exported commands do not call them. |
| `.github/workflows`, scripts, metadata, sample `.4dm`, documentation and tracked product | Reviewed for CI/build reachability; no additional first-party native implementation. Product binaries, wizard databases and legacy 4D database files are not treated as source or executed. |

Both existing workflows are **manual only** (`workflow_dispatch`).
`Build` signs, notarizes, packages and publishes; it must not be used for
ownership validation. `Bump version` updates metadata. Neither is modified.
Direct compiler execution avoids project product-copy/Rez and output paths.

## Actual SDK provenance and contracts

The local SDK is the repository's vendor snapshot, present in first commit
`b05560a2c48209025cb37f78914f51d2db4628af` (2015-09-04), moved by
`8d0a2695dc22bdf39c65e772526ea2d0ac8c27b9`. There is no dependency
manifest, upstream release pin or verified upstream version identifier.
The source's `v14` and headers' `v13` comments are **not** release identity.
The miyako-authored wrapper files are distinct from the 4D SAS SDK internals.

| File at audit baseline | SHA-256 |
| --- | --- |
| `4D Plugin API/4DPluginAPI.c` | `355ee208ad6c61dcc68e8432546fc42484888211dd07ed8fa3fdb4440f3edbd8` |
| `4D Plugin API/4DPluginAPI.h` | `7391841f0046f9e822b65ca6b07cafb3565aecfb58f65be4e0661adf97b8c786` |

Guidance was read at `miyako/skills` revision `e6b492f`,
`4d-skills/skills/4dplugin/SKILL.md`; conclusions use this repository's
actual implementation:

* `PA_SetStringInArray` (4444-4459) consumes only when kind is
  `eVK_ArrayUnicode`, data is non-null, `0 <= index <= fNbElements`,
  and the string pointer is non-null. It disposes the previous element and
  shallow-assigns the incoming descriptor. Index zero is accepted. Rejection
  retains caller ownership. `PA_GetStringInArray` (4266-4283) is borrowed.
* `PA_SetStringVariable` (3826-3831) shallow-assigns without clearing an old
  owner. `PA_CreateVariable(eVK_Unistring/Picture)` (3523-3657) creates
  owning empty contents. Undefined destinations avoid overwriting them.
  `PA_GetPictureVariable` explicitly returns a borrowed picture.
* `PA_SetUnistring` (263-270) forwards content to the engine.
  `PA_ReturnString` (2260-2263) and `C_TEXT::setReturn` use that setter.
  The shim models synchronous independent content storage, separately from
  array descriptor transfer; only a real 4D host can certify engine behavior.
* `PA_DuplicatePicture(p, 1)` retains; `setPicture` uses it. Temporary and
  argument owners must therefore release after that retain. Borrowed picture
  inputs are detached before argument clear. Returned pictures are detached
  from arguments so consumers own and release them.
* `PA_ConvertCharsetToCharset` (4775-4794) explicitly returns **bytes**,
  excluding the terminator. Conversion capacities and lengths in the shim
  remain bytes; production divides by `sizeof(PA_Unichar)` for string units.
* `PA_ExecuteCommandByID` (5257-5294) initializes a raw-kind-zero sentinel
  before handle creation and changes it to Undefined only on success.
  `PA_ExecuteMethodByID` instead starts Undefined. The new local command
  helper clears valid returned owners but never the raw sentinel. These
  picture commands ordinarily return Undefined; synthetic owning result
  variants establish cleanup if a host supplies such a result.

## Evidence and limits

Fixed source passes 24 regular scenarios: twelve cases, each with allocated
and null empty strings. The baseline fails the five explicitly named defects
with checked diagnostic markers: `path` double disposal; `bytes` and
`gray-owners` unbalanced picture references; `copy-units` ASan
heap-buffer-overflow in the actual production constructor; `command-result`
unreleased owning return. Baseline `arrays` and `scalars` controls pass.
Other baseline handoff/failure scenarios also reveal the same owner leaks.

Fixtures assert exact ASCII, BMP and supplementary UTF-16 text, lengths,
capacity/termination and empty contents. Coverage includes repeated
replacement, shrink/clear, independent transfers, copied borrowed inputs,
all setter rejection predicates, scalar result survival, retained picture
parameter inputs, owning picture handoff survival, failed picture creation
preserving the previous owner and SDK error, command errors, a poisoned
failed metadata output that must not be read, raw command-handle failure,
and owning string/picture command returns. Actual exported dispatcher cases
are exercised on macOS (empty text/zero).

**Deferred, not certified safe:**

* Initial `ARRAY_TEXT` handle-creation failure: the unchanged wrapper can
  publish `ArrayUnicode` with null data, losing the original Undefined kind
  and leaking rejected insertions. The separate `deferred-array-create`
  characterization must fail with its named diagnostic on both baseline
  and fixed source. It is not counted as a passing regression. These void
  wrappers have no explicit established error channel, and `PluginMain`
  swallows exceptions. A safe boundary/error-reporting design is required
  before changing this behavior; no success-shaped fallback is introduced.
* SDK resize OOM can corrupt the declared array count independently of
  normal transfer guards. Normal-array tests do not certify OOM safety;
  SDK rewriting is excluded.
* `C_POINTER::getVariable` mixes pointer-value metadata with reference
  definitions; do not clear and relabel uncertain borrowed metadata.
  SDK-only application-path and picture-data metadata output ownership is
  likewise not established. The shim uses a failing metadata response, not
  an invented ownership contract for successful metadata.
* No Windows build/execution, actual Windows platform calls, real 4D host,
  production document/image import, signing or published binary validation
  was performed. This does not reproduce or certify the originating Windows
  Poppler crash. Dormant helper fixes do not expand the public dispatcher.
