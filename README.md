# 4d-plugin-get-version

A 4D plugin that reports which version of Windows 4D is running on, and whether 4D is a 32-bit process running on 64-bit Windows (WOW64). It exists because `PLATFORM PROPERTIES` in older 4D versions reports `6.2` on every Windows release from Windows 8 onward. The plugin gives you two independent ways to read the version: the classic `GetVersionEx` Win32 API (subject to the same limitation), or the file version of the system's own `kernel32.dll` (not subject to it). Results are returned as `Text` (`"major.minor"`) and `Longint`.

| Command | Returns | Purpose |
|:--|:--|:--|
| [`Windows Get version`](#windows-get-version) | `Text` | Windows version as `"major.minor"`, using the method you choose |
| [`Windows Is WOW64`](#windows-is-wow64) | `Longint` | `1` if 4D is a 32-bit process on 64-bit Windows, otherwise `0` |

**Platforms:** Windows only (the commands exist on macOS but return empty values there — see below).

---

## Requirements & platform notes

- **Windows only.** On macOS both commands are callable, but do nothing: [`Windows Get version`](#windows-get-version) returns an empty string and [`Windows Is WOW64`](#windows-is-wow64) returns `0`. Check the platform first if your code runs on both (see the examples).
- **The shipped bundle contains a 64-bit Windows binary only** (`Contents/Windows64`). With a 64-bit 4D, [`Windows Is WOW64`](#windows-is-wow64) always returns `0`, by definition.
- **Failure is silent, not a 4D error.** If the underlying Windows call fails, [`Windows Get version`](#windows-get-version) returns an empty string. Always test for `""` before parsing the result.
- **Only major and minor numbers are reported.** Windows 10 and Windows 11 both report `"10.0"`; this plugin cannot tell them apart (that requires the build number, which it does not return).
- **Version of this document.** Two behaviors described below apply to the plugin **built from the corrected source** accompanying this document, and not necessarily to an older binary you may already have installed:
  - `GetFileVersionInfo` mode returns a correct `"major.minor"` in a 64-bit 4D. Older binaries return a meaningless value such as `"655360.655360"` in that configuration (they were only correct for 32-bit 4D on 64-bit Windows).
  - [`Windows Is WOW64`](#windows-is-wow64) returns `0` if Windows cannot determine the answer. Older binaries returned `1` in that case.

### Constants

The plugin installs a constant theme, **Windows Get Version Option**, used as the `option` parameter of [`Windows Get version`](#windows-get-version):

| Constant | Value | Meaning |
|:--|:--|:--|
| `GetFileVersionInfo` | `1` | Read the product version of `kernel32.dll` from the Windows system folder |
| `GetVersionInfoEx` | `0` | Ask Windows via the `GetVersionEx` API |

---

## Windows Get version

### Syntax

```4d
version:=Windows Get version(option)
```

| Parameter | Type | Description |
|:--|:--|:--|
| `option` | `Longint` | `GetFileVersionInfo` or `GetVersionInfoEx`. Any value other than `1` is treated as `GetVersionInfoEx` |
| Result | `Text` | Windows version as `"major.minor"` (e.g. `"10.0"`, `"6.3"`), or `""` on failure |

### Description

`Windows Get version` returns the Windows version number as text in the form `"major.minor"`. How the number is obtained depends on `option`.

**`GetFileVersionInfo`** reads the product version stored in `kernel32.dll` in the Windows system folder. This reflects the Windows that is actually installed, regardless of how 4D itself is configured, so it is the option to use when you need the real version. Typical results:

| Windows release | Result |
|:--|:--|
| Windows 7 / Server 2008 R2 | `"6.1"` |
| Windows 8 / Server 2012 | `"6.2"` |
| Windows 8.1 / Server 2012 R2 | `"6.3"` |
| Windows 10 / Windows 11 / Server 2016 and later | `"10.0"` |

**`GetVersionInfoEx`** calls the Win32 `GetVersionEx` API. Since Windows 8.1, Windows deliberately reports `6.2` to any application that does not declare support for newer Windows versions in its application manifest. The manifest in question belongs to the 4D executable, not to the plugin, so the result depends on your 4D version and cannot be changed from the plugin side. On a 4D whose executable does not declare this support, you'll get `"6.2"` on Windows 8.1, 10 and 11. This option is kept mainly to show that difference; use `GetFileVersionInfo` when you want a trustworthy number.

`option` is declared as a mandatory parameter. Either way, the value `0` and every value other than `1` select `GetVersionInfoEx`.

If the underlying call fails (for example, `kernel32.dll`'s version information cannot be read), the result is an empty string; no 4D error is raised.

### Example

From the plugin's own test method (`Method1.4dm`):

```4d
$version_1:=Windows Get version(GetFileVersionInfo)
$version_2:=Windows Get version(GetVersionInfoEx)
$isWOW64:=Windows Is WOW64
```

Splitting the result into numbers, with a guard for the empty-string failure case:

```4d
C_TEXT($version)
C_LONGINT($major;$minor;$dot)

$version:=Windows Get version(GetFileVersionInfo)

If ($version#"")
	$dot:=Position(".";$version)
	$major:=Num(Substring($version;1;$dot-1))
	$minor:=Num(Substring($version;$dot+1))
Else
	  // the version could not be read
End if
```

Requiring Windows 8.1 or later:

```4d
C_TEXT($version)
C_LONGINT($major;$minor;$dot)

$version:=Windows Get version(GetFileVersionInfo)
$dot:=Position(".";$version)
$major:=Num(Substring($version;1;$dot-1))
$minor:=Num(Substring($version;$dot+1))

If (($major>6) | (($major=6) & ($minor>=3)))
	  // Windows 8.1, 10 or 11
Else
	ALERT("This feature requires Windows 8.1 or later.")
End if
```

---

## Windows Is WOW64

### Syntax

```4d
isWOW64:=Windows Is WOW64
```

| Parameter | Type | Description |
|:--|:--|:--|
| Result | `Longint` | `1` if 4D is a 32-bit process running on 64-bit Windows, otherwise `0` |

### Description

`Windows Is WOW64` tells you whether the current 4D process is a 32-bit application running under WOW64, Windows' compatibility layer for 32-bit programs on 64-bit Windows.

| 4D | Windows | Result |
|:--|:--|:--|
| 32-bit | 64-bit | `1` |
| 32-bit | 32-bit | `0` |
| 64-bit | 64-bit | `0` |

Note that `0` does **not** mean "32-bit Windows": a 64-bit 4D on 64-bit Windows also returns `0`. Since the shipped plugin bundle contains only a 64-bit Windows binary, you'll get `0` in practice unless you build and install a 32-bit version.

**On ARM64 Windows**, a 32-bit (x86) 4D returns `1`, but a 64-bit (x64) 4D running under emulation returns `0` — Windows does not count x64 emulation as WOW64.

If Windows cannot determine the answer, the command returns `0` (corrected build; see Requirements). On macOS it always returns `0`.

### Example

From the plugin's own test method (`Method1.4dm`):

```4d
$isWOW64:=Windows Is WOW64
```

Branching on the result:

```4d
If (Windows Is WOW64=1)
	  // 32-bit 4D on 64-bit Windows:
	  // file system and registry redirection apply to this process
Else
	  // native process (or not on Windows)
End if
```

---

## Error handling & troubleshooting

- **Empty string from [`Windows Get version`](#windows-get-version).** The Windows call behind the chosen option failed, or you are on macOS. No 4D error is raised, so test for `""` before parsing.
- **`"6.2"` on Windows 8.1, 10 or 11.** You used `GetVersionInfoEx`, and the 4D executable does not declare support for newer Windows versions. Use `GetFileVersionInfo` instead.
- **`"10.0"` on Windows 11.** Expected: Windows 11 still reports version 10.0. This plugin returns only major and minor numbers, so it cannot distinguish the two.
- **A huge number such as `"655360.655360"`.** You are using a binary built from the uncorrected source, in a 64-bit 4D. Install a build from the corrected source.
- **[`Windows Is WOW64`](#windows-is-wow64) returns `0` on 64-bit Windows.** Expected with a 64-bit 4D, which is what the shipped bundle targets. The command only returns `1` for a 32-bit process.
- **Both commands return empty/zero values on macOS.** By design: the plugin is Windows only. Check the platform first (see Quick reference).

---

## Quick reference

```4d
C_LONGINT($platform)
C_TEXT($version)

PLATFORM PROPERTIES($platform)
If ($platform=Windows)
	$version:=Windows Get version(GetFileVersionInfo)  // "10.0", "6.3", ... or ""
	If (Windows Is WOW64=1)
		  // 32-bit 4D on 64-bit Windows
	End if
End if
```
