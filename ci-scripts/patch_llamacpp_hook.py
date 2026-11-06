#!/usr/bin/env python3
"""Safely patch llm_llamacpp's build hook so it can load a locally-built
llama.framework instead of relying on the package's broken iOS prebuilt /
source-build paths.

What it does (deliberately minimal, no brace-matching so it cannot corrupt the
Dart file the way a regex rewrite can):
  1. Insert a top-level helper `_localPrebuilt` right before `main()`.
  2. Change the call site `await _tryDownloadPrebuilt(` into
     `_localPrebuilt(libraryName, input) ?? await _tryDownloadPrebuilt(`.

`_localPrebuilt` returns the framework + companion dylibs found under the
directory named by the LLM_LLAMACPP_PREBUILT env var, or null to fall through
to the original (broken-for-iOS) logic.

This is only used by CI; it has zero effect on normal `flutter` usage because the
env var is never set outside the workflow.
"""
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("::error::usage: patch_llamacpp_hook.py <path-to-build.dart>")
        return 1

    path = sys.argv[1]
    with open(path, encoding="utf-8") as fh:
        src = fh.read()

    helper = (
        "List<Uri>? _localPrebuilt(String libraryName, BuildInput input) {\n"
        "  final dirPath = Platform.environment['LLM_LLAMACPP_PREBUILT'];\n"
        "  if (dirPath == null || dirPath.isEmpty) return null;\n"
        "  final dir = Directory(dirPath);\n"
        "  if (!dir.existsSync()) return null;\n"
        "  final uris = <Uri>[];\n"
        "  for (final entity in dir.listSync(recursive: true)) {\n"
        "    final base = p.basename(entity.path);\n"
        "    if (base == libraryName || base.endsWith('.framework') || base.endsWith('.dylib')) {\n"
        "      uris.add(entity.uri);\n"
        "    }\n"
        "  }\n"
        "  return uris.isEmpty ? null : uris;\n"
        "}\n\n"
    )

    marker = "Future<void> main(List<String> args) async {"
    idx = src.find(marker)
    if idx == -1:
        print("::error::main() not found; aborting patch")
        return 1
    src = src[:idx] + helper + src[idx:]

    old = "await _tryDownloadPrebuilt("
    if old not in src:
        print("::error::call site 'await _tryDownloadPrebuilt(' not found")
        return 1
    src = src.replace(old, "_localPrebuilt(libraryName, input) ?? await _tryDownloadPrebuilt(", 1)

    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)

    print("Patched llm_llamacpp hook to honor LLM_LLAMACPP_PREBUILT")
    return 0


if __name__ == "__main__":
    sys.exit(main())
