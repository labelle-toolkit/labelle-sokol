// Translate-c shim for `@cImport`. Zig 0.16's translate-c rejects
// clang's nullability qualifiers when they appear on array parameters
// (e.g. `unsigned short __xsubi[_Nonnull 3]` in Bionic's stdlib.h on
// the Android NDK 27 sysroot — see Flying-Platform/flying-platform-labelle#450).
// `_Nonnull`, `_Nullable`, and `_Null_unspecified` are clang keywords,
// but redefining them as empty macros at the top of the translation
// unit makes the preprocessor strip them before translate-c sees the
// declarations. clang itself is happy either way; only translate-c is
// stricter than the language spec here.
//
// The real `stb_*_impl.c` files compile as C (not translate-c), so they
// keep the original Bionic headers + qualifiers intact for the C
// runtime symbols they actually call.
#ifndef LABELLE_STB_SHIM_H
#define LABELLE_STB_SHIM_H

// Strip clang nullability keywords so translate-c parses `[_Nonnull 3]`
// array parameters cleanly. clang itself doesn't care either way.
#ifdef _Nonnull
#undef _Nonnull
#endif
#define _Nonnull

#ifdef _Nullable
#undef _Nullable
#endif
#define _Nullable

#ifdef _Null_unspecified
#undef _Null_unspecified
#endif
#define _Null_unspecified

// Disable Bionic's fortify-source overloads. Without nullability
// qualifiers the fortified and unfortified `sprintf` / `vsprintf` /
// etc. signatures collide; clang's `__overloadable` machinery
// distinguishes them by nullability, and stripping those above leaves
// the two definitions ambiguous. Stb only uses libc through malloc /
// free / memcpy paths that don't need fortify.
#ifdef _FORTIFY_SOURCE
#undef _FORTIFY_SOURCE
#endif
#define _FORTIFY_SOURCE 0

#include "stb_image.h"
#include "stb_truetype.h"

#endif // LABELLE_STB_SHIM_H
