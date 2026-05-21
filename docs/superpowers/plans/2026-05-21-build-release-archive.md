# Build release & archive workflow — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `python -m tools.release` — a maintainer command that archives the previous `build/` to GitHub Releases, regenerates the build, prompts the user for a "what's new" description, and updates `README.md` accordingly.

**Architecture:** Orchestrator at `tools/release.py` handles all I/O (subprocess `gh`/`git`/`$EDITOR`, filesystem, network). Pure helpers in `tools/lib/release.py` (tag building, editor-buffer parsing, README rewriting, tarball packing) are unit-testable. `build_geojson.py` is extended to stamp `built_at` and `commit` into `manifest.json` so the next release can construct the right archive tag. README gains two HTML-comment marker pairs for idempotent rewrites.

**Tech Stack:** Python 3, pytest, `tarfile` (stdlib), `subprocess` (stdlib), `gh` CLI (external), `git` (external).

**Reference spec:** `docs/superpowers/specs/2026-05-21-build-release-archive-design.md`

---

## File map

| Path | Action | Responsibility |
|---|---|---|
| `tools/release.py` | create | Orchestrator entry point. Sequences preflight → archive → rebuild → editor → README. Owns subprocess + filesystem I/O. |
| `tools/lib/release.py` | create | Pure helpers: `build_tag`, `render_editor_template`, `strip_editor_comments`, `pack_archive`, `rewrite_readme`. |
| `tools/build_geojson.py` | modify | Write `built_at` and `commit` into `build/manifest.json`. |
| `tests/test_release_lib.py` | create | Unit tests for `tools/lib/release.py`. |
| `tests/test_release_orchestrator.py` | create | Integration test for `tools/release.py` with stubbed `gh` and `$EDITOR`. |
| `tests/test_build_geojson_manifest.py` | create | Unit test for the new manifest fields. |
| `README.md` | modify | Add `<!-- whats-new:start/end -->` and `<!-- past-releases:start/end -->` markers; expand Contributor flow with a step 0 prerequisite + step 6 (release ritual). |
| `.gitignore` | modify | Ignore `dist/` (temp tarball staging). |

---

## Task 1: Add `built_at` + `commit` to `build/manifest.json`

**Files:**
- Modify: `tools/build_geojson.py:212-244` (the `main()` function and the surrounding manifest-writing logic)
- Test: `tests/test_build_geojson_manifest.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_build_geojson_manifest.py`:

```python
"""Smoke test for the new manifest fields written by tools.build_geojson."""

import json
import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_manifest_has_built_at_and_commit():
    """After running build_geojson, manifest.json must carry built_at + commit."""
    # Run the build in a subprocess to exercise the actual main() path.
    result = subprocess.run(
        ["python", "-m", "tools.build_geojson"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    manifest = json.loads((REPO_ROOT / "build" / "manifest.json").read_text())
    assert "built_at" in manifest, "manifest must record build timestamp"
    assert "commit" in manifest, "manifest must record commit at build time"

    # built_at is ISO 8601 with date prefix YYYY-MM-DD
    assert re.match(r"^\d{4}-\d{2}-\d{2}T", manifest["built_at"]), manifest["built_at"]
    # commit is a short SHA (7+ hex chars)
    assert re.match(r"^[0-9a-f]{7,}$", manifest["commit"]), manifest["commit"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_build_geojson_manifest.py -v`
Expected: FAIL — `KeyError`/`assert "built_at" in manifest` because the field isn't written yet.

- [ ] **Step 3: Modify `tools/build_geojson.py` to stamp the fields**

In `tools/build_geojson.py`, add a helper near the top (after the existing imports) and call it from `_build_manifest`:

Add this import alongside the existing `import` statements at the top of the file:

```python
import datetime as dt
import subprocess
```

In `_build_manifest`, change the return dict (currently lines ~205-209) from:

```python
    return {
        "shapefile": "data/shapefiles/DRC_Health_zones.shp",
        "n_features": len(load_zones()),
        "datasets": datasets,
    }
```

to:

```python
    return {
        "shapefile": "data/shapefiles/DRC_Health_zones.shp",
        "n_features": len(load_zones()),
        "built_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "commit": _current_short_sha(),
        "datasets": datasets,
    }
```

And add this helper above `_build_manifest` (near the other underscore-prefixed helpers):

```python
def _current_short_sha() -> str:
    """Return `git rev-parse --short HEAD`. Empty string if not in a git tree."""
    try:
        out = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(REPO_ROOT),
            stderr=subprocess.DEVNULL,
        )
        return out.decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/test_build_geojson_manifest.py -v`
Expected: PASS.

- [ ] **Step 5: Run the full test suite to confirm nothing else broke**

Run: `.venv/bin/python -m pytest tests/ -v`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add tools/build_geojson.py tests/test_build_geojson_manifest.py
git commit -m "Stamp built_at and commit into build/manifest.json"
```

---

## Task 2: `tools/lib/release.py` — `build_tag` helper

**Files:**
- Create: `tools/lib/release.py`
- Test: `tests/test_release_lib.py`

- [ ] **Step 1: Write the failing test**

Create `tests/test_release_lib.py`:

```python
"""Unit tests for pure helpers in tools.lib.release."""

from tools.lib.release import build_tag


def test_build_tag_combines_date_and_sha():
    assert build_tag("2026-05-21", "396cf8a") == "build-2026-05-21-396cf8a"


def test_build_tag_accepts_iso_timestamp_and_truncates_to_date():
    assert build_tag("2026-05-21T14:30:00+00:00", "abc1234") == "build-2026-05-21-abc1234"


def test_build_tag_rejects_empty_sha():
    import pytest
    with pytest.raises(ValueError, match="sha"):
        build_tag("2026-05-21", "")


def test_build_tag_rejects_empty_date():
    import pytest
    with pytest.raises(ValueError, match="date"):
        build_tag("", "abc1234")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'tools.lib.release'`.

- [ ] **Step 3: Implement `build_tag`**

Create `tools/lib/release.py`:

```python
"""Pure helpers for tools.release. No I/O side effects beyond writing to paths
the caller hands in. All functions here must be unit-testable without
subprocess, network, or environment dependencies."""

from __future__ import annotations


def build_tag(date_or_iso: str, short_sha: str) -> str:
    """Construct the GitHub-release tag for an archived build.

    `date_or_iso` may be a plain `YYYY-MM-DD` or an ISO 8601 timestamp; in the
    latter case only the date portion is used (the tag is per-day, with the
    sha disambiguating within a day).
    """
    if not date_or_iso:
        raise ValueError("date must be non-empty")
    if not short_sha:
        raise ValueError("sha must be non-empty")
    date_part = date_or_iso.split("T", 1)[0]
    return f"build-{date_part}-{short_sha}"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/release.py tests/test_release_lib.py
git commit -m "Add build_tag helper for release archives"
```

---

## Task 3: `render_editor_template` + `strip_editor_comments`

**Files:**
- Modify: `tools/lib/release.py`
- Modify: `tests/test_release_lib.py`

- [ ] **Step 1: Append failing tests**

Append to `tests/test_release_lib.py`:

```python
from tools.lib.release import render_editor_template, strip_editor_comments


def test_render_editor_template_starts_with_comment_lines():
    tpl = render_editor_template()
    lines = tpl.splitlines()
    # First lines are comment hints
    assert all(line.startswith("#") or line == "" for line in lines[:4])
    # Mentions key guidance
    assert "what's new" in tpl.lower()
    assert "first line" in tpl.lower()


def test_strip_editor_comments_drops_hash_prefixed_lines():
    raw = (
        "# Lines starting with '#' are ignored.\n"
        "# Describe what's new.\n"
        "\n"
        "Refreshed ACLED extract; added new flowminder month.\n"
        "\n"
        "Motivated by the WHO sitrep update.\n"
    )
    out = strip_editor_comments(raw)
    assert out == (
        "Refreshed ACLED extract; added new flowminder month.\n"
        "\n"
        "Motivated by the WHO sitrep update."
    )


def test_strip_editor_comments_returns_empty_when_only_comments():
    raw = "# comment one\n# comment two\n"
    assert strip_editor_comments(raw) == ""


def test_strip_editor_comments_preserves_inline_hashes():
    """A '#' that isn't the first non-whitespace char of a line is content."""
    raw = "Updated dataset #42 with new metrics.\n"
    assert strip_editor_comments(raw) == "Updated dataset #42 with new metrics."
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: FAIL — `ImportError: cannot import name 'render_editor_template'`.

- [ ] **Step 3: Implement both helpers**

Append to `tools/lib/release.py`:

```python
EDITOR_TEMPLATE = """\
# Lines starting with '#' are ignored.
# Describe what's new in this build and why.
# First line = short summary (shown in README's Past releases log).
# Following paragraphs = full release notes (shown on GitHub Releases).

"""


def render_editor_template() -> str:
    """Return the buffer shown to the user when $EDITOR opens."""
    return EDITOR_TEMPLATE


def strip_editor_comments(raw: str) -> str:
    """Drop lines whose first non-whitespace character is '#', then trim trailing whitespace."""
    kept = [line for line in raw.splitlines() if not line.lstrip().startswith("#")]
    return "\n".join(kept).strip()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/release.py tests/test_release_lib.py
git commit -m "Add editor template + comment-stripping helpers"
```

---

## Task 4: `pack_archive` helper

**Files:**
- Modify: `tools/lib/release.py`
- Modify: `tests/test_release_lib.py`

- [ ] **Step 1: Append failing test**

Append to `tests/test_release_lib.py`:

```python
import tarfile
from pathlib import Path

from tools.lib.release import pack_archive


def test_pack_archive_writes_tarball_with_expected_arcnames(tmp_path):
    # Source files
    src_dir = tmp_path / "src"
    src_dir.mkdir()
    (src_dir / "a.txt").write_text("alpha")
    nested = src_dir / "nested"
    nested.mkdir()
    (nested / "b.txt").write_text("bravo")

    members = [
        (src_dir / "a.txt", "build/a.txt"),
        (src_dir / "nested", "build/nested"),  # directory should recurse
    ]
    out = tmp_path / "out.tar.gz"

    pack_archive(members, out)

    assert out.exists()
    with tarfile.open(out, "r:gz") as tf:
        names = sorted(tf.getnames())
    assert "build/a.txt" in names
    assert "build/nested/b.txt" in names


def test_pack_archive_raises_on_missing_source(tmp_path):
    import pytest
    out = tmp_path / "out.tar.gz"
    with pytest.raises(FileNotFoundError):
        pack_archive([(tmp_path / "does-not-exist", "x")], out)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: FAIL — `ImportError: cannot import name 'pack_archive'`.

- [ ] **Step 3: Implement `pack_archive`**

Append to `tools/lib/release.py`:

```python
import tarfile
from pathlib import Path


def pack_archive(members: list[tuple[Path, str]], out_path: Path) -> None:
    """Write a gzip-compressed tarball.

    Each member is (source_path_on_disk, arcname_inside_tarball). Directories
    are recursed automatically by tarfile.add. Raises FileNotFoundError if any
    source path does not exist.
    """
    for src, _ in members:
        if not src.exists():
            raise FileNotFoundError(src)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out_path, "w:gz") as tf:
        for src, arcname in members:
            tf.add(str(src), arcname=arcname)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/lib/release.py tests/test_release_lib.py
git commit -m "Add pack_archive helper for tarball assembly"
```

---

## Task 5: Add README markers (no behavior change)

Before we can write `rewrite_readme`, the README needs the marker pairs it'll edit between. Add them as a no-op to set the stage; the next task implements the rewriter against this structure.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Insert `<!-- whats-new:start -->` and `<!-- whats-new:end -->` markers inside the Current build section**

Edit `README.md`. Locate the paragraph at lines 33-35:

```
# Current build (2026-05-21)

Snapshot of `build/drc_health_zones.geojson` (519 zones, \~25 MB) and the matrix catalogue, at commit `99ee96c`. Re-run `python -m tools.build_geojson` after pulling to regenerate locally; `build/manifest.json` carries the same information in machine-readable form.
```

Immediately after that paragraph (before the "**Embedded in the GeoJSON**" line), insert:

```
<!-- whats-new:start -->
<!-- whats-new:end -->

```

(Two blank lines below the comment block so the existing content keeps spacing.)

- [ ] **Step 2: Add a new "## Past releases" section above "# Repository layout"**

Locate `# Repository layout` (around line 69). Insert immediately before it:

```
## Past releases

<!-- past-releases:start -->
| Tag | Date | Summary | Download |
|-----|------|---------|----------|
<!-- past-releases:end -->

```

- [ ] **Step 3: Verify the README still renders cleanly**

Run: `grep -n "whats-new:start\|whats-new:end\|past-releases:start\|past-releases:end" README.md`
Expected: 4 lines, in order: whats-new:start, whats-new:end, past-releases:start, past-releases:end.

Also run: `.venv/bin/python -m pytest tests/ -v`
Expected: all green (no tests touch README yet).

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Add markers in README for release-driven rewrites"
```

---

## Task 6: `rewrite_readme` helper

**Files:**
- Modify: `tools/lib/release.py`
- Modify: `tests/test_release_lib.py`

- [ ] **Step 1: Append failing tests**

Append to `tests/test_release_lib.py`:

```python
from tools.lib.release import rewrite_readme


SAMPLE_README = """\
# Header

Last successful build: **OLD TIMESTAMP** (commit `oldsha1`).

# Current build (2026-01-01)

Some prose.

<!-- whats-new:start -->
old description
<!-- whats-new:end -->

More prose.

## Past releases

<!-- past-releases:start -->
| Tag | Date | Summary | Download |
|-----|------|---------|----------|
| build-2026-01-01-oldsha1 | 2026-01-01 | initial | [release](https://example/old) |
<!-- past-releases:end -->

# Repository layout
"""


def test_rewrite_readme_updates_last_build_line():
    out = rewrite_readme(
        SAMPLE_README,
        last_build_line="Last successful build: **21 May 2026** (commit `newsha1`).",
        current_build_date="2026-05-21",
        whats_new="Brand new content.",
        past_release_row="| build-2026-05-21-newsha1 | 2026-05-21 | did stuff | [release](https://example/new) |",
    )
    assert "**21 May 2026**" in out
    assert "commit `newsha1`" in out
    assert "OLD TIMESTAMP" not in out


def test_rewrite_readme_updates_current_build_heading():
    out = rewrite_readme(
        SAMPLE_README,
        last_build_line="Last successful build: **X** (commit `a`).",
        current_build_date="2026-05-21",
        whats_new="x",
        past_release_row="| t | d | s | [r](u) |",
    )
    assert "# Current build (2026-05-21)" in out
    assert "# Current build (2026-01-01)" not in out


def test_rewrite_readme_replaces_whats_new_block():
    out = rewrite_readme(
        SAMPLE_README,
        last_build_line="Last successful build: **X** (commit `a`).",
        current_build_date="2026-05-21",
        whats_new="Refreshed ACLED. Added new month of Flowminder.",
        past_release_row="| t | d | s | [r](u) |",
    )
    # Content replaced
    assert "Refreshed ACLED" in out
    assert "old description" not in out
    # Markers preserved
    assert "<!-- whats-new:start -->" in out
    assert "<!-- whats-new:end -->" in out


def test_rewrite_readme_prepends_past_release_row():
    out = rewrite_readme(
        SAMPLE_README,
        last_build_line="Last successful build: **X** (commit `a`).",
        current_build_date="2026-05-21",
        whats_new="x",
        past_release_row="| build-2026-05-21-newsha1 | 2026-05-21 | new entry | [release](https://example/new) |",
    )
    # New row appears before the old row
    new_idx = out.index("build-2026-05-21-newsha1")
    old_idx = out.index("build-2026-01-01-oldsha1")
    assert new_idx < old_idx
    # Table header preserved exactly once
    assert out.count("|-----|------|---------|----------|") == 1


def test_rewrite_readme_is_idempotent_outside_markers():
    out1 = rewrite_readme(
        SAMPLE_README,
        last_build_line="Last successful build: **X** (commit `a`).",
        current_build_date="2026-05-21",
        whats_new="x",
        past_release_row="| t | d | s | [r](u) |",
    )
    # Surrounding prose is unchanged
    assert "Some prose." in out1
    assert "More prose." in out1
    assert "# Repository layout" in out1


def test_rewrite_readme_raises_on_missing_marker():
    import pytest
    broken = SAMPLE_README.replace("<!-- whats-new:end -->", "")
    with pytest.raises(ValueError, match="whats-new:end"):
        rewrite_readme(
            broken,
            last_build_line="Last successful build: **X** (commit `a`).",
            current_build_date="2026-05-21",
            whats_new="x",
            past_release_row="| t | d | s | [r](u) |",
        )
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: FAIL — `ImportError: cannot import name 'rewrite_readme'`.

- [ ] **Step 3: Implement `rewrite_readme`**

Append to `tools/lib/release.py`:

```python
import re


WHATS_NEW_START = "<!-- whats-new:start -->"
WHATS_NEW_END = "<!-- whats-new:end -->"
PAST_RELEASES_START = "<!-- past-releases:start -->"
PAST_RELEASES_END = "<!-- past-releases:end -->"
PAST_RELEASES_HEADER = (
    "| Tag | Date | Summary | Download |\n"
    "|-----|------|---------|----------|"
)


def rewrite_readme(
    readme: str,
    *,
    last_build_line: str,
    current_build_date: str,
    whats_new: str,
    past_release_row: str,
) -> str:
    """Return a new README body with release-driven content swapped in.

    Replaces:
      - the line starting with `Last successful build:` with `last_build_line`
      - the `# Current build (YYYY-MM-DD)` heading's date
      - the contents between whats-new markers with `whats_new`
      - prepends `past_release_row` after the past-releases table header

    Raises ValueError if any required marker is missing.
    """
    for marker in (WHATS_NEW_START, WHATS_NEW_END, PAST_RELEASES_START, PAST_RELEASES_END):
        if marker not in readme:
            raise ValueError(f"README is missing marker: {marker}")

    # 1. Last successful build line
    readme = re.sub(
        r"^Last successful build:.*$",
        last_build_line,
        readme,
        count=1,
        flags=re.MULTILINE,
    )

    # 2. Current build heading
    readme = re.sub(
        r"^# Current build \([^)]*\)",
        f"# Current build ({current_build_date})",
        readme,
        count=1,
        flags=re.MULTILINE,
    )

    # 3. Replace whats-new block contents
    readme = _replace_between(
        readme,
        WHATS_NEW_START,
        WHATS_NEW_END,
        f"{WHATS_NEW_START}\n{whats_new}\n{WHATS_NEW_END}",
    )

    # 4. Prepend past-release row after the table header
    block_pattern = re.compile(
        re.escape(PAST_RELEASES_START)
        + r".*?"
        + re.escape(PAST_RELEASES_END),
        re.DOTALL,
    )

    def _prepend_row(match: re.Match) -> str:
        block = match.group(0)
        # Reconstruct: marker, header, new row, existing rows, end marker
        body = block[len(PAST_RELEASES_START):-len(PAST_RELEASES_END)]
        # Drop any whitespace-only leading/trailing lines from body for clean reflow
        lines = [ln for ln in body.splitlines() if ln.strip()]
        # The first two lines of the existing block are the header rows; preserve them
        existing_rows = [ln for ln in lines if ln.startswith("|") and "---" not in ln and "Tag" not in ln]
        new_block = (
            PAST_RELEASES_START
            + "\n"
            + PAST_RELEASES_HEADER
            + "\n"
            + past_release_row
            + "\n"
            + "\n".join(existing_rows)
            + ("\n" if existing_rows else "")
            + PAST_RELEASES_END
        )
        return new_block

    readme = block_pattern.sub(_prepend_row, readme, count=1)
    return readme


def _replace_between(text: str, start: str, end: str, replacement: str) -> str:
    pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.DOTALL)
    return pattern.sub(replacement.replace("\\", "\\\\"), text, count=1)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py -v`
Expected: all PASS (6 prior + 6 new = 12).

- [ ] **Step 5: Commit**

```bash
git add tools/lib/release.py tests/test_release_lib.py
git commit -m "Add rewrite_readme helper for release-driven README edits"
```

---

## Task 7: `.gitignore` — add `dist/`

`dist/` is already listed in `.gitignore` (line ~14 of the Python boilerplate block). Verify, no change needed if so.

**Files:**
- Modify (only if needed): `.gitignore`

- [ ] **Step 1: Verify `dist/` is already ignored**

Run: `grep -n "^dist/" .gitignore`
Expected: at least one match (already present per existing `.gitignore`).

- [ ] **Step 2: If absent, add it**

If the grep above returned nothing, append `dist/` to `.gitignore` and commit:

```bash
echo "dist/" >> .gitignore
git add .gitignore
git commit -m "Gitignore dist/ for release tarball staging"
```

Otherwise, no commit needed. Move on.

---

## Task 8: `tools/release.py` orchestrator — preflight checks

Build the orchestrator incrementally, one capability at a time. Start with the preflight (no destructive actions yet).

**Files:**
- Create: `tools/release.py`
- Create: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Write failing tests for preflight**

Create `tests/test_release_orchestrator.py`:

```python
"""Integration tests for the tools.release orchestrator.

These tests stub out `gh`, `git`, and `$EDITOR` via PATH manipulation and
environment variables, then exercise the real orchestrator end-to-end against
a tmp directory.
"""

import json
import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]


def _make_stub(path: Path, body: str) -> None:
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _seed_minimal_repo(tmp: Path) -> None:
    """Lay down the minimum file tree the release orchestrator inspects."""
    (tmp / "build").mkdir()
    (tmp / "build" / "long").mkdir()
    (tmp / "build" / "drc_health_zones.geojson").write_text('{"type":"FeatureCollection","features":[]}')
    (tmp / "build" / "manifest.json").write_text(json.dumps({
        "shapefile": "data/shapefiles/DRC_Health_zones.shp",
        "n_features": 0,
        "built_at": "2026-05-20T12:00:00+00:00",
        "commit": "abc1234",
        "datasets": [],
    }))
    (tmp / "build" / "DESCRIPTION.md").write_text("Previous description.\n")
    (tmp / "qa").mkdir()
    (tmp / "qa" / "qa_log.csv").write_text("dataset,type,file,status\nfoo,vector,foo.csv,pass\n")
    (tmp / "qa" / "matrix_log.csv").write_text("dataset,file\n")
    (tmp / "README.md").write_text("placeholder readme — markers added separately in this test where needed")


def test_preflight_fails_when_qa_log_missing(tmp_path, monkeypatch):
    _seed_minimal_repo(tmp_path)
    (tmp_path / "qa" / "qa_log.csv").unlink()
    monkeypatch.chdir(tmp_path)

    result = subprocess.run(
        [sys.executable, "-m", "tools.release"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONPATH": str(REPO_ROOT)},
    )
    assert result.returncode != 0
    assert "qa" in result.stderr.lower()


def test_preflight_fails_when_qa_log_has_failures(tmp_path, monkeypatch):
    _seed_minimal_repo(tmp_path)
    (tmp_path / "qa" / "qa_log.csv").write_text(
        "dataset,type,file,status\nfoo,vector,foo.csv,fail\n"
    )
    monkeypatch.chdir(tmp_path)

    result = subprocess.run(
        [sys.executable, "-m", "tools.release"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={**os.environ, "PYTHONPATH": str(REPO_ROOT)},
    )
    assert result.returncode != 0
    assert "fail" in result.stderr.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: FAIL — `No module named 'tools.release'`.

- [ ] **Step 3: Implement preflight scaffolding**

Create `tools/release.py`:

```python
"""`python -m tools.release` — archive previous build, rebuild, prompt for
description, update README.

This module owns all I/O (subprocess, network, $EDITOR). Pure helpers live in
tools.lib.release.

Run from repo root:
    python -m tools.release
"""

from __future__ import annotations

import csv
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
QA_LOG = REPO_ROOT / "qa" / "qa_log.csv"


def _eprint(msg: str) -> None:
    print(msg, file=sys.stderr)


def _preflight() -> int:
    """Validate environment before any side effects. Returns exit code (0 = ok)."""
    if not QA_LOG.exists():
        _eprint(f"qa log not found at {QA_LOG}; run `python -m tools.qa` first.")
        return 2

    with QA_LOG.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("status") == "fail":
                _eprint(
                    "qa log contains failures — resolve them and re-run "
                    "`python -m tools.qa` before releasing."
                )
                return 2
    return 0


def main() -> int:
    rc = _preflight()
    if rc != 0:
        return rc
    _eprint("preflight ok (further steps pending — TODO in next tasks)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: Run preflight tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: PASS for both tests.

- [ ] **Step 5: Commit**

```bash
git add tools/release.py tests/test_release_orchestrator.py
git commit -m "Add tools.release preflight scaffold (qa log checks)"
```

---

## Task 9: Preflight — `gh` and working-tree checks

**Files:**
- Modify: `tools/release.py`
- Modify: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Append failing tests**

Append to `tests/test_release_orchestrator.py`:

```python
def test_preflight_fails_when_gh_missing(tmp_path, monkeypatch):
    _seed_minimal_repo(tmp_path)
    monkeypatch.chdir(tmp_path)
    # PATH without gh
    monkeypatch.setenv("PATH", "/nonexistent-bin")

    result = subprocess.run(
        [sys.executable, "-m", "tools.release"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            "PATH": "/nonexistent-bin",
            "PYTHONPATH": str(REPO_ROOT),
            "HOME": str(tmp_path),
        },
    )
    assert result.returncode != 0
    assert "gh" in result.stderr.lower()


def test_preflight_fails_on_unrelated_dirty_paths(tmp_path):
    _seed_minimal_repo(tmp_path)
    # Initialize a git repo and commit baseline so `git status --porcelain`
    # has a baseline to diff against.
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"],
        cwd=tmp_path,
        check=True,
    )
    # Stub gh by putting a shim on PATH
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _make_stub(bin_dir / "gh", "#!/usr/bin/env bash\nexit 0\n")
    # Make an unrelated file dirty
    (tmp_path / "unrelated.txt").write_text("dirty")

    result = subprocess.run(
        [sys.executable, "-m", "tools.release"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "PYTHONPATH": str(REPO_ROOT),
        },
    )
    assert result.returncode != 0
    assert "unrelated" in result.stderr.lower() or "dirty" in result.stderr.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: the two new tests FAIL (orchestrator currently passes preflight without these checks).

- [ ] **Step 3: Extend `_preflight`**

Modify `tools/release.py`. Add imports at the top:

```python
import shutil
import subprocess
```

Replace `_preflight` with:

```python
ALLOWLIST_PREFIXES = ("build/", "qa/qa_log.csv", "qa/matrix_log.csv", "README.md")


def _preflight() -> int:
    if not QA_LOG.exists():
        _eprint(f"qa log not found at {QA_LOG}; run `python -m tools.qa` first.")
        return 2

    with QA_LOG.open(newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row.get("status") == "fail":
                _eprint(
                    "qa log contains failures — resolve them and re-run "
                    "`python -m tools.qa` before releasing."
                )
                return 2

    if shutil.which("gh") is None:
        _eprint(
            "gh CLI not found. Install from https://cli.github.com/ and run `gh auth login`."
        )
        return 2

    dirty = _git_dirty_paths()
    unrelated = [p for p in dirty if not any(p.startswith(pre) for pre in ALLOWLIST_PREFIXES)]
    if unrelated:
        _eprint(
            "working tree has unrelated uncommitted changes; commit or stash them first:\n"
            + "\n".join(f"  {p}" for p in unrelated)
        )
        return 2

    return 0


def _git_dirty_paths() -> list[str]:
    """Paths reported by `git status --porcelain` (no status code prefix)."""
    result = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    paths: list[str] = []
    for line in result.stdout.splitlines():
        # Porcelain format: "XY path" or "XY path1 -> path2" (renames).
        path = line[3:].split(" -> ", 1)[-1].strip()
        if path:
            paths.append(path)
    return paths
```

Also update `REPO_ROOT` in `tools/release.py` so it respects the current working directory (the tests run in a tmp dir, not the project tree):

```python
REPO_ROOT = Path.cwd()
QA_LOG = REPO_ROOT / "qa" / "qa_log.csv"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: all preflight tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/release.py tests/test_release_orchestrator.py
git commit -m "Tighten tools.release preflight (gh CLI + dirty-tree)"
```

---

## Task 10: Archive step — pack tarball + push GitHub Release

**Files:**
- Modify: `tools/release.py`
- Modify: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_release_orchestrator.py`:

```python
def test_archive_step_invokes_gh_with_expected_tag_and_notes(tmp_path):
    _seed_minimal_repo(tmp_path)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"],
        cwd=tmp_path,
        check=True,
    )

    # Stub gh: log every invocation to a file, return success.
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh_log = tmp_path / "gh.log"
    _make_stub(
        bin_dir / "gh",
        f"""#!/usr/bin/env bash
echo "$@" >> {gh_log}
# Mimic 'gh release view <tag>' returning failure (release does not yet exist).
if [ "$1" = "release" ] && [ "$2" = "view" ]; then exit 1; fi
# Mimic 'gh release create' emitting a URL on stdout.
if [ "$1" = "release" ] && [ "$2" = "create" ]; then
  echo "https://github.com/example/repo/releases/tag/$3"
fi
exit 0
""",
    )

    # Stub editor to write a fixed description and exit.
    editor_stub = bin_dir / "fake-editor"
    _make_stub(
        editor_stub,
        """#!/usr/bin/env bash
cat > "$1" <<EOF
Fresh build description.

Bullet about new things.
EOF
""",
    )

    result = subprocess.run(
        [sys.executable, "-m", "tools.release", "--skip-rebuild", "--skip-readme"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "PYTHONPATH": str(REPO_ROOT),
            "EDITOR": str(editor_stub),
        },
    )
    assert result.returncode == 0, result.stderr

    # gh was called for `release view` and `release create` with the right tag.
    log = gh_log.read_text()
    assert "release view build-2026-05-20-abc1234" in log
    assert "release create build-2026-05-20-abc1234" in log

    # tarball was produced.
    archives = list((tmp_path / "dist").glob("build-2026-05-20-abc1234.tar.gz"))
    assert archives, "expected one tarball under dist/"
```

(The `--skip-rebuild` and `--skip-readme` flags are temporary scaffolding so this task can exercise the archive step in isolation; later tasks add and then remove the no-op-default flags as those features land.)

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py::test_archive_step_invokes_gh_with_expected_tag_and_notes -v`
Expected: FAIL — `unrecognized arguments: --skip-rebuild`.

- [ ] **Step 3: Implement archive step**

Replace the body of `main()` in `tools/release.py`:

```python
import argparse
import json

from tools.lib.release import build_tag, pack_archive


BUILD_DIR = REPO_ROOT / "build"
MANIFEST = BUILD_DIR / "manifest.json"
DESCRIPTION = BUILD_DIR / "DESCRIPTION.md"
DIST_DIR = REPO_ROOT / "dist"


def _archive_previous_build() -> str | None:
    """Pack the current build/ into dist/<tag>.tar.gz and create a GitHub Release.

    Returns the release URL on success, or None if archiving was skipped (no
    prior DESCRIPTION.md exists — first ever release).
    """
    if not DESCRIPTION.exists():
        _eprint("no build/DESCRIPTION.md found — skipping archive (first-ever release).")
        return None

    manifest = json.loads(MANIFEST.read_text())
    tag = build_tag(manifest["built_at"], manifest["commit"])

    # If the release already exists, refuse rather than silently overwriting.
    view = subprocess.run(
        ["gh", "release", "view", tag],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    if view.returncode == 0:
        _eprint(f"GitHub release {tag} already exists; did a previous rebuild fail?")
        sys.exit(2)

    out_path = DIST_DIR / f"{tag}.tar.gz"
    members: list[tuple[Path, str]] = [
        (BUILD_DIR / "drc_health_zones.geojson", "build/drc_health_zones.geojson"),
        (BUILD_DIR / "long", "build/long"),
        (BUILD_DIR / "manifest.json", "build/manifest.json"),
        (BUILD_DIR / "DESCRIPTION.md", "build/DESCRIPTION.md"),
        (REPO_ROOT / "qa" / "qa_log.csv", "qa/qa_log.csv"),
        (REPO_ROOT / "qa" / "matrix_log.csv", "qa/matrix_log.csv"),
    ]
    pack_archive(members, out_path)

    create = subprocess.run(
        [
            "gh", "release", "create", tag,
            str(out_path),
            "--title", tag,
            "--notes-file", str(DESCRIPTION),
        ],
        capture_output=True,
        text=True,
        cwd=str(REPO_ROOT),
    )
    if create.returncode != 0:
        _eprint(f"`gh release create` failed:\n{create.stderr}")
        sys.exit(2)

    url = create.stdout.strip().splitlines()[-1] if create.stdout.strip() else ""
    _eprint(f"✓ Archived previous build as {tag} → {url}")
    return url


def main() -> int:
    parser = argparse.ArgumentParser(prog="tools.release")
    parser.add_argument("--skip-rebuild", action="store_true",
                        help="DEV ONLY: skip the rebuild step (used by tests)")
    parser.add_argument("--skip-readme", action="store_true",
                        help="DEV ONLY: skip the README rewrite step (used by tests)")
    args = parser.parse_args()

    rc = _preflight()
    if rc != 0:
        return rc

    _archive_previous_build()

    if not args.skip_rebuild:
        _eprint("rebuild step pending — implemented in next task")
    if not args.skip_readme:
        _eprint("readme rewrite pending — implemented in later task")

    return 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: all preflight + archive tests PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/release.py tests/test_release_orchestrator.py
git commit -m "Archive previous build to GitHub Releases in tools.release"
```

---

## Task 11: Rebuild step

**Files:**
- Modify: `tools/release.py`
- Modify: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_release_orchestrator.py`:

```python
def test_rebuild_step_invokes_build_geojson_main(tmp_path, monkeypatch):
    """The rebuild step must invoke tools.build_geojson.main and propagate failure."""
    _seed_minimal_repo(tmp_path)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"],
        cwd=tmp_path,
        check=True,
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _make_stub(bin_dir / "gh", "#!/usr/bin/env bash\n[ \"$1\" = release ] && [ \"$2\" = view ] && exit 1; echo https://example/url; exit 0\n")
    _make_stub(bin_dir / "fake-editor", "#!/usr/bin/env bash\necho 'desc' > \"$1\"\n")

    # Sentinel file to confirm the build module was loaded.
    sentinel = tmp_path / "rebuild_marker.txt"

    # Inject a fake tools.build_geojson via PYTHONPATH that writes the sentinel.
    fake_pkg = tmp_path / "fake_tools"
    (fake_pkg / "tools").mkdir(parents=True)
    (fake_pkg / "tools" / "__init__.py").write_text("")
    (fake_pkg / "tools" / "build_geojson.py").write_text(
        f"def main():\n    open(r'{sentinel}', 'w').write('rebuilt')\n    return 0\n"
    )

    result = subprocess.run(
        [sys.executable, "-m", "tools.release", "--skip-readme"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            # Fake tools first on PYTHONPATH so its build_geojson wins; release.py
            # itself comes from the real REPO_ROOT.
            "PYTHONPATH": f"{fake_pkg}:{REPO_ROOT}",
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "EDITOR": str(bin_dir / "fake-editor"),
        },
    )
    assert result.returncode == 0, result.stderr
    assert sentinel.exists(), "rebuild step never invoked build_geojson.main()"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py::test_rebuild_step_invokes_build_geojson_main -v`
Expected: FAIL — sentinel file not created.

- [ ] **Step 3: Implement rebuild**

In `tools/release.py`, replace the placeholder rebuild block in `main()` with an actual call:

Locate:
```python
    if not args.skip_rebuild:
        _eprint("rebuild step pending — implemented in next task")
```

Replace with:
```python
    if not args.skip_rebuild:
        from tools import build_geojson as _build_geojson  # import lazily so tests can substitute
        rc = _build_geojson.main()
        if rc != 0:
            _eprint(
                "rebuild failed AFTER archive was published. The release stands "
                "and accurately describes the old build; fix the rebuild and re-run."
            )
            return rc
        _eprint("✓ Rebuilt build/")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/release.py tests/test_release_orchestrator.py
git commit -m "Invoke build_geojson rebuild after archiving"
```

---

## Task 12: Editor prompt + DESCRIPTION.md write

**Files:**
- Modify: `tools/release.py`
- Modify: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_release_orchestrator.py`:

```python
def test_editor_step_writes_description(tmp_path):
    _seed_minimal_repo(tmp_path)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"],
        cwd=tmp_path,
        check=True,
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _make_stub(bin_dir / "gh", "#!/usr/bin/env bash\n[ \"$1\" = release ] && [ \"$2\" = view ] && exit 1; echo https://example/url; exit 0\n")
    editor = bin_dir / "fake-editor"
    _make_stub(
        editor,
        """#!/usr/bin/env bash
cat > "$1" <<EOF
# this comment must be stripped
Updated ACLED + new Flowminder month.

More detail here.
EOF
""",
    )

    result = subprocess.run(
        [sys.executable, "-m", "tools.release", "--skip-rebuild", "--skip-readme"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "PYTHONPATH": str(REPO_ROOT),
            "EDITOR": str(editor),
        },
    )
    assert result.returncode == 0, result.stderr
    body = (tmp_path / "build" / "DESCRIPTION.md").read_text()
    assert body.startswith("Updated ACLED")
    assert "# this comment" not in body


def test_editor_step_refuses_empty_description(tmp_path):
    _seed_minimal_repo(tmp_path)
    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"],
        cwd=tmp_path,
        check=True,
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _make_stub(bin_dir / "gh", "#!/usr/bin/env bash\n[ \"$1\" = release ] && [ \"$2\" = view ] && exit 1; echo https://example/url; exit 0\n")
    editor = bin_dir / "fake-editor"
    # Editor writes only comments
    _make_stub(editor, "#!/usr/bin/env bash\necho '# just a comment' > \"$1\"\n")

    result = subprocess.run(
        [sys.executable, "-m", "tools.release", "--skip-rebuild", "--skip-readme"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "PYTHONPATH": str(REPO_ROOT),
            "EDITOR": str(editor),
        },
    )
    assert result.returncode != 0
    assert "description" in result.stderr.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: the new tests FAIL.

- [ ] **Step 3: Implement the editor step**

In `tools/release.py`, add imports if not present:
```python
import os
import tempfile
```

Add the helper above `main`:

```python
from tools.lib.release import render_editor_template, strip_editor_comments


def _prompt_description() -> str:
    editor = os.environ.get("EDITOR", "vi")
    with tempfile.NamedTemporaryFile("w+", suffix=".md", delete=False) as f:
        f.write(render_editor_template())
        tmp_path = Path(f.name)
    try:
        subprocess.run([editor, str(tmp_path)], check=True)
        raw = tmp_path.read_text()
    finally:
        tmp_path.unlink(missing_ok=True)
    body = strip_editor_comments(raw)
    if not body:
        _eprint("description is required (empty after stripping comments); aborting.")
        sys.exit(2)
    return body
```

Wire it into `main()` — add a call after the rebuild block (before the `--skip-readme` check):

```python
    description = _prompt_description()
    DESCRIPTION.write_text(description + "\n", encoding="utf-8")
    _eprint("✓ Wrote build/DESCRIPTION.md")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/release.py tests/test_release_orchestrator.py
git commit -m "Prompt for build description via \$EDITOR and persist to build/DESCRIPTION.md"
```

---

## Task 13: README rewrite step

**Files:**
- Modify: `tools/release.py`
- Modify: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Write failing test**

Append to `tests/test_release_orchestrator.py`:

```python
def test_readme_rewrite_updates_pointers_and_past_releases(tmp_path):
    _seed_minimal_repo(tmp_path)
    # Replace the placeholder README with one that has the real markers.
    (tmp_path / "README.md").write_text(
        "# Header\n\n"
        "Last successful build: **OLD** (commit `oldsha`).\n\n"
        "# Current build (2026-01-01)\n\n"
        "prose\n\n"
        "<!-- whats-new:start -->\n"
        "old description\n"
        "<!-- whats-new:end -->\n\n"
        "## Past releases\n\n"
        "<!-- past-releases:start -->\n"
        "| Tag | Date | Summary | Download |\n"
        "|-----|------|---------|----------|\n"
        "<!-- past-releases:end -->\n\n"
        "# Repository layout\n"
    )

    subprocess.run(["git", "init", "-q"], cwd=tmp_path, check=True)
    subprocess.run(["git", "add", "."], cwd=tmp_path, check=True)
    subprocess.run(
        ["git", "-c", "user.email=t@e", "-c", "user.name=t", "commit", "-qm", "init"],
        cwd=tmp_path,
        check=True,
    )

    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    _make_stub(
        bin_dir / "gh",
        "#!/usr/bin/env bash\n"
        "[ \"$1\" = release ] && [ \"$2\" = view ] && exit 1\n"
        "[ \"$1\" = release ] && [ \"$2\" = create ] && echo https://github.com/x/y/releases/tag/$3 && exit 0\n"
        "exit 0\n",
    )
    editor = bin_dir / "fake-editor"
    _make_stub(
        editor,
        "#!/usr/bin/env bash\n"
        "cat > \"$1\" <<EOF\n"
        "Brand new content line.\n\n"
        "More detail.\n"
        "EOF\n",
    )

    # Fake build_geojson that bumps the manifest date so the README "current build" is the new one.
    fake_pkg = tmp_path / "fake_tools"
    (fake_pkg / "tools").mkdir(parents=True)
    (fake_pkg / "tools" / "__init__.py").write_text("")
    (fake_pkg / "tools" / "build_geojson.py").write_text(
        "import json, pathlib\n"
        "def main():\n"
        "    p = pathlib.Path('build/manifest.json')\n"
        "    m = json.loads(p.read_text())\n"
        "    m['built_at'] = '2026-05-21T10:00:00+00:00'\n"
        "    m['commit'] = 'newsha1'\n"
        "    p.write_text(json.dumps(m))\n"
        "    return 0\n"
    )

    result = subprocess.run(
        [sys.executable, "-m", "tools.release"],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        env={
            **os.environ,
            "PYTHONPATH": f"{fake_pkg}:{REPO_ROOT}",
            "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}",
            "EDITOR": str(editor),
        },
    )
    assert result.returncode == 0, result.stderr

    readme = (tmp_path / "README.md").read_text()
    # New current-build pointer (uses the rebuilt manifest)
    assert "# Current build (2026-05-21)" in readme
    assert "newsha1" in readme
    # whats-new block holds the new description
    assert "Brand new content line." in readme
    assert "old description" not in readme
    # Past releases gained a row for the *archived* build (the old one)
    assert "build-2026-05-20-abc1234" in readme
    # First line of the archived build's DESCRIPTION.md ("Previous description.") is the summary
    assert "Previous description." in readme
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_release_orchestrator.py::test_readme_rewrite_updates_pointers_and_past_releases -v`
Expected: FAIL — README not yet rewritten.

- [ ] **Step 3: Implement README rewrite**

In `tools/release.py`, add imports if not present:

```python
import datetime as dt
```

Add the helper above `main`:

```python
from tools.lib.release import rewrite_readme


README = REPO_ROOT / "README.md"


def _format_human_date(iso_ts: str) -> str:
    """Render an ISO 8601 timestamp as e.g. '21 May 2026, 10:00 (UTC)'."""
    parsed = dt.datetime.fromisoformat(iso_ts)
    return parsed.strftime("%-d %B %Y, %H:%M (%Z)") if parsed.tzinfo else parsed.strftime("%-d %B %Y, %H:%M")


def _update_readme(
    archived_tag: str | None,
    archived_release_url: str | None,
    archived_description_summary: str | None,
) -> None:
    manifest = json.loads(MANIFEST.read_text())
    built_at = manifest["built_at"]
    short_sha = manifest["commit"]
    current_date = built_at.split("T", 1)[0]
    human_ts = _format_human_date(built_at)

    last_build_line = f"Last successful build: **{human_ts}** (commit `{short_sha}`)."
    whats_new = DESCRIPTION.read_text().rstrip()

    if archived_tag and archived_release_url and archived_description_summary:
        past_release_row = (
            f"| {archived_tag} | {archived_tag.split('-', 1)[1].rsplit('-', 1)[0]} "
            f"| {archived_description_summary} "
            f"| [release]({archived_release_url}) |"
        )
    else:
        past_release_row = None  # Nothing to prepend (first ever release)

    readme = README.read_text()
    if past_release_row is None:
        # Still update the other fields (last-build line, current-build heading, whats-new block).
        readme = rewrite_readme(
            readme,
            last_build_line=last_build_line,
            current_build_date=current_date,
            whats_new=whats_new,
            past_release_row="",  # rewrite_readme will tolerate an empty row by emitting just the header
        )
        # Strip the trailing empty-row blank line we just produced.
        readme = readme.replace("\n\n<!-- past-releases:end -->", "\n<!-- past-releases:end -->")
    else:
        readme = rewrite_readme(
            readme,
            last_build_line=last_build_line,
            current_build_date=current_date,
            whats_new=whats_new,
            past_release_row=past_release_row,
        )

    README.write_text(readme, encoding="utf-8")
    _eprint("✓ Updated README.md")
```

Wire it into `main()`. The archive step needs to return what the README step needs, so rework the archive call. Replace the entire archive block in `main()` with:

```python
    archived_tag = None
    archived_url = None
    archived_summary = None
    if DESCRIPTION.exists():
        prior_manifest = json.loads(MANIFEST.read_text())
        archived_tag = build_tag(prior_manifest["built_at"], prior_manifest["commit"])
        archived_summary = DESCRIPTION.read_text().strip().splitlines()[0]
    archived_url = _archive_previous_build()
```

(`_archive_previous_build` already constructs the same tag internally; that's fine — both compute it from the same manifest before the rebuild.)

Then at the end of `main()`, before the success message:

```python
    if not args.skip_readme:
        _update_readme(archived_tag, archived_url, archived_summary)
```

Also tweak `rewrite_readme` so an empty `past_release_row` doesn't insert a stray blank line. In `tools/lib/release.py`, in `_prepend_row`, change:

```python
        new_block = (
            PAST_RELEASES_START
            + "\n"
            + PAST_RELEASES_HEADER
            + "\n"
            + past_release_row
            + "\n"
            + "\n".join(existing_rows)
            + ("\n" if existing_rows else "")
            + PAST_RELEASES_END
        )
```

to:

```python
        rows: list[str] = []
        if past_release_row:
            rows.append(past_release_row)
        rows.extend(existing_rows)
        new_block = (
            PAST_RELEASES_START
            + "\n"
            + PAST_RELEASES_HEADER
            + ("\n" + "\n".join(rows) if rows else "")
            + "\n"
            + PAST_RELEASES_END
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_release_lib.py tests/test_release_orchestrator.py -v`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/release.py tools/lib/release.py tests/test_release_orchestrator.py
git commit -m "Rewrite README on release: pointers, what's new, past releases"
```

---

## Task 14: Final success message + remove `--skip-*` flags

The `--skip-rebuild` / `--skip-readme` flags were scaffolding for incremental testing. Now that every step is in place, prune them so the public CLI is clean.

**Files:**
- Modify: `tools/release.py`
- Modify: `tests/test_release_orchestrator.py`

- [ ] **Step 1: Update tests that referenced the dev flags**

In `tests/test_release_orchestrator.py`, audit every `subprocess.run([... "tools.release", "--skip-rebuild", ...])` call. For tests that explicitly need to short-circuit, replace the approach with stubbing `tools.build_geojson.main` via the same PYTHONPATH fake-pkg trick used in the rebuild test:

For each test that used `--skip-rebuild`:
1. Add a tmp fake_tools dir with a no-op `tools/build_geojson.py` whose `main()` returns 0.
2. Prepend it to `PYTHONPATH`.
3. Remove the `--skip-rebuild` arg.

Similarly for `--skip-readme`:
1. Seed `README.md` with the markers (use the same template from `test_readme_rewrite_updates_pointers_and_past_releases`).
2. Remove the `--skip-readme` arg.

This is repetitive but localized to four tests. Use a shared helper at the top of the file:

```python
def _install_fake_build(tmp: Path) -> Path:
    fake_pkg = tmp / "fake_tools"
    (fake_pkg / "tools").mkdir(parents=True)
    (fake_pkg / "tools" / "__init__.py").write_text("")
    (fake_pkg / "tools" / "build_geojson.py").write_text("def main():\n    return 0\n")
    return fake_pkg


READMEMARKERS_TEMPLATE = (
    "# Header\n\nLast successful build: **OLD** (commit `oldsha`).\n\n"
    "# Current build (2026-01-01)\n\nprose\n\n"
    "<!-- whats-new:start -->\nold\n<!-- whats-new:end -->\n\n"
    "## Past releases\n\n"
    "<!-- past-releases:start -->\n"
    "| Tag | Date | Summary | Download |\n"
    "|-----|------|---------|----------|\n"
    "<!-- past-releases:end -->\n\n"
    "# Repository layout\n"
)
```

Use them in `_seed_minimal_repo` (replace the placeholder README line with `(tmp / "README.md").write_text(READMEMARKERS_TEMPLATE)`).

- [ ] **Step 2: Remove the flags from `tools/release.py`**

In `tools/release.py`, replace `argparse` setup and downstream `args.skip_*` references. The new `main` body:

```python
def main() -> int:
    parser = argparse.ArgumentParser(prog="tools.release")
    parser.parse_args()  # no flags; --help still works

    rc = _preflight()
    if rc != 0:
        return rc

    archived_tag = None
    archived_summary = None
    if DESCRIPTION.exists():
        prior = json.loads(MANIFEST.read_text())
        archived_tag = build_tag(prior["built_at"], prior["commit"])
        archived_summary = DESCRIPTION.read_text().strip().splitlines()[0]
    archived_url = _archive_previous_build()

    from tools import build_geojson as _bg
    rc = _bg.main()
    if rc != 0:
        _eprint(
            "rebuild failed AFTER archive was published. The release stands "
            "and accurately describes the old build; fix and re-run."
        )
        return rc
    _eprint("✓ Rebuilt build/")

    description = _prompt_description()
    DESCRIPTION.write_text(description + "\n", encoding="utf-8")
    _eprint("✓ Wrote build/DESCRIPTION.md")

    _update_readme(archived_tag, archived_url, archived_summary)

    _eprint("")
    _eprint("Next: review the changes, then")
    _eprint("  git add build/ qa/qa_log.csv qa/matrix_log.csv README.md")
    _eprint("  git commit -m \"New build YYYY-MM-DD\"")
    _eprint("  git push")
    return 0
```

- [ ] **Step 3: Run the full suite**

Run: `.venv/bin/python -m pytest tests/ -v`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add tools/release.py tests/test_release_orchestrator.py
git commit -m "Finalize tools.release CLI: drop dev-only --skip-* flags"
```

---

## Task 15: README — update Contributor flow

**Files:**
- Modify: `README.md` (the `# Contributor flow` section, around lines 106-134)

- [ ] **Step 1: Update step 0 (one-time setup)**

Locate the bullet list under `0.  One-time setup (anyone cloning):` (around lines 108-115). After the existing block describing `git lfs install` + venv setup, append two bullets:

Change the block from:

```
    git lfs install
    python -m venv .venv && .venv/bin/pip install -r tools/requirements.txt
    ```

    LFS is required because binary raw blobs (`*.xlsx`, `*.zip`, `*.pdf`, `*.tif`, etc.) under `data/*/raw/` are stored via Git LFS — see `.gitattributes`.
```

to:

```
    git lfs install
    python -m venv .venv && .venv/bin/pip install -r tools/requirements.txt
    ```

    LFS is required because binary raw blobs (`*.xlsx`, `*.zip`, `*.pdf`, `*.tif`, etc.) under `data/*/raw/` are stored via Git LFS — see `.gitattributes`.

    Additionally, maintainers who will cut releases need:

    - `gh` CLI installed and authenticated (`gh auth login`).
    - `$EDITOR` environment variable set (used by `tools.release` for the description prompt).
```

- [ ] **Step 2: Add step 6 (publishing a release)**

After step 5 ("Open a PR. CI runs `pytest` + `tools.qa` …"), insert:

```
6.  Publishing a release (maintainer task). After a merge to `main` introduces changes worth a new public snapshot:

    ```
    .venv/bin/python -m tools.release
    ```

    This will:

    - archive the current `build/` as a GitHub Release tagged `build-YYYY-MM-DD-<sha>`
    - rebuild from current data
    - open `$EDITOR` to capture a "what's new" description for the new build
    - update `README.md` (current-build pointers + Past releases log)

    Then `git add build/ qa/*.csv README.md && git commit && git push` to land the new build alongside its description.

    Use `tools.build_geojson` (not `tools.release`) for normal local iteration — `tools.release` is only for cutting versioned snapshots.
```

- [ ] **Step 3: Verify the README still renders**

Run: `grep -n "^6\." README.md` — should find the new step.
Run: `grep -n "tools.release" README.md` — should find at least the contributor-flow mentions.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Document tools.release in Contributor flow"
```

---

## Task 16: End-to-end smoke (manual)

Automated tests cover everything except the real-GitHub interaction. Smoke-test it once.

- [ ] **Step 1: Run `tools.release` for real on a branch**

```bash
git checkout -b release-smoke
.venv/bin/python -m tools.release
```

Expect:
- Editor opens with the comment template.
- After save, a GitHub Release appears at `https://github.com/kraemer-lab/Ebola_DRC_2026/releases/tag/build-...`.
- `build/DESCRIPTION.md` is created/updated.
- `README.md` shows the new pointers and a row in "Past releases".

- [ ] **Step 2: If something is wrong, delete the test release**

```bash
gh release delete <tag> --yes
git reset --hard HEAD
```

- [ ] **Step 3: When happy, push and PR**

```bash
git push -u origin release-smoke
gh pr create --title "Build release & archive workflow" --body "Implements docs/superpowers/specs/2026-05-21-build-release-archive-design.md"
```
