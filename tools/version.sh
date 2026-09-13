#!/bin/sh
# The version of this checkout: what `jolt --version` reports when nothing
# bakes one in (bin/jolt), what build-jolt.ss bakes into a binary when
# $JOLT_VERSION is unset, and what the release workflow bakes into a nightly.
# One definition, because the property below is lost by editing any one of the
# three back to a bare `git describe`.
#
#   v0.8.0                on a release tag
#   v0.8.0-56-g63374117   56 commits past it, at that sha (-dirty with edits)
#   dev-g63374117         no release tag reachable (a shallow clone)
#   dev                   not a git checkout (a source tarball; the flake sets
#                         JOLT_VERSION itself)
#
# Release tags only (`v` + digit). The rolling `vnightly` tag the release
# workflow moves to main's head every day is the NEAREST tag from main, so a
# plain `git describe --tags` on any clone that has fetched it answers
# "vnightly". And the no-tag case is prefixed rather than the bare sha:
# jolt.deps reads a version's leading digits, so a sha such as 0a1b2c3 would
# read as version 0 and fail every :jolt/min-version floor, while dev-g0a1b2c3
# reads as a version with no number, which no floor applies to.
#
# Usage: tools/version.sh [checkout]   (default: the checkout this script is in)
set -eu
root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

# The aspect integration line may descend from a historical release commit
# whose public tag was later moved to a tree-identical rewritten commit.  Its
# provenance lock is the authority for that deliberately preserved ancestry;
# derive the same version a restored tag would have produced without mutating
# local refs.  Branches outside that recorded lineage keep the generic release-
# tag behavior below.
lock="$root/config/aspect-integration.lock"
if [ -f "$lock" ] && git -C "$root" rev-parse --verify HEAD >/dev/null 2>&1; then
  # Probe only the root first. A shallow or non-aspect checkout can contain the
  # lock without containing its historical objects; it must retain the generic
  # version behavior. Once ancestry confirms this is the aspect line, every
  # lock field becomes fail-closed.
  aspect_root_probe="$(sed -n 's/^aspect_root_commit=//p' "$lock")"
  aspect_line=0
  if [ -n "$aspect_root_probe" ] &&
     [ "$(printf '%s\n' "$aspect_root_probe" | wc -l)" -eq 1 ] &&
     [ "${#aspect_root_probe}" -eq 40 ]; then
    case "$aspect_root_probe" in
      *[!0-9a-f]*) ;;
      *)
        if git -C "$root" cat-file -e "$aspect_root_probe^{commit}" 2>/dev/null &&
           git -C "$root" merge-base --is-ancestor "$aspect_root_probe" HEAD; then
          aspect_line=1
        fi ;;
    esac
  fi

  if [ "$aspect_line" -eq 1 ]; then
    # POSIX sh has no portable local variables; callers consume each result
    # immediately, so the function's assignments are intentionally global.
    lock_value() {
      key="$1"
      values="$(sed -n "s/^${key}=//p" "$lock")"
      [ -n "$values" ] && [ "$(printf '%s\n' "$values" | wc -l)" -eq 1 ] || {
        echo "tools/version.sh: invalid aspect integration lock key: $key" >&2
        exit 1
      }
      printf '%s\n' "$values"
    }

    schema="$(lock_value schema)"
    release="$(lock_value upstream_release)"
    base="$(lock_value upstream_base_commit)"
    aspect_root="$(lock_value aspect_root_commit)"
    [ "$schema" = 1 ] || [ "$schema" = 2 ] || [ "$schema" = 3 ] || {
      echo "tools/version.sh: unsupported aspect integration lock schema: $schema" >&2
      exit 1
    }
    if ! printf '%s\n' "$release" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "tools/version.sh: invalid locked upstream release: $release" >&2
      exit 1
    fi
    if [ "${#base}" -ne 40 ] || [ "${#aspect_root}" -ne 40 ]; then
      echo "tools/version.sh: invalid locked aspect commit" >&2
      exit 1
    fi
    case "$base$aspect_root" in
      *[!0-9a-f]*)
        echo "tools/version.sh: invalid locked aspect commit" >&2
        exit 1 ;;
    esac
    [ "$aspect_root" = "$aspect_root_probe" ] || {
      echo "tools/version.sh: aspect root changed during lock read" >&2
      exit 1
    }
    git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null || {
      echo "tools/version.sh: locked upstream base is absent" >&2
      exit 1
    }
    root_parent="$(git -C "$root" rev-parse --verify "$aspect_root^1" 2>/dev/null)" || {
      echo "tools/version.sh: locked aspect root has no parent" >&2
      exit 1
    }
    [ "$root_parent" = "$base" ] || {
      echo "tools/version.sh: locked upstream base is not the aspect root parent" >&2
      exit 1
    }
    # Schema 1 replay epochs count from the aspect root's historical base.
    # Schema 2 and 3 merge epochs count from the current merged upstream
    # release, excluding the old aspect-line history reachable through the
    # other parent. Schema 3's extra base anchors provenance, not version
    # distance, so its counting rule is unchanged.
    distance_base="$base"
    if [ "$schema" = 2 ] || [ "$schema" = 3 ]; then
      release_commit="$(lock_value upstream_release_commit)"
      if [ "${#release_commit}" -ne 40 ]; then
        echo "tools/version.sh: invalid locked upstream release commit" >&2
        exit 1
      fi
      case "$release_commit" in
        *[!0-9a-f]*)
          echo "tools/version.sh: invalid locked upstream release commit" >&2
          exit 1 ;;
      esac
      if [ "$schema" = 3 ]; then
        release_base="$(lock_value upstream_release_base_commit)"
        base_tree_lock="$(lock_value upstream_base_tree)"
        if [ "${#release_base}" -ne 40 ] || [ "${#base_tree_lock}" -ne 40 ]; then
          echo "tools/version.sh: invalid locked release-lineage base" >&2
          exit 1
        fi
        case "$release_base$base_tree_lock" in
          *[!0-9a-f]*)
            echo "tools/version.sh: invalid locked release-lineage base" >&2
            exit 1 ;;
        esac
        release_base_tree="$(git -C "$root" rev-parse --verify "$release_base^{tree}" 2>/dev/null)" || {
          echo "tools/version.sh: locked release-lineage base is absent" >&2
          exit 1
        }
        historical_base_tree="$(git -C "$root" rev-parse --verify "$base^{tree}" 2>/dev/null)" || {
          echo "tools/version.sh: locked historical base tree is absent" >&2
          exit 1
        }
        [ "$historical_base_tree" = "$base_tree_lock" ] &&
          [ "$release_base_tree" = "$base_tree_lock" ] || {
          echo "tools/version.sh: locked release-lineage base tree mismatch" >&2
          exit 1
        }
        git -C "$root" merge-base --is-ancestor "$release_base" "$release_commit" || {
          echo "tools/version.sh: locked release does not descend from its tree-equivalent base" >&2
          exit 1
        }
      fi
      git -C "$root" merge-base --is-ancestor "$release_commit" HEAD || {
        echo "tools/version.sh: locked upstream release is not merged" >&2
        exit 1
      }
      distance_base="$release_commit"
    fi
    distance="$(git -C "$root" rev-list --ancestry-path --count "$distance_base..HEAD")"
    short="$(git -C "$root" rev-parse --short HEAD)"
    dirty=
    git -C "$root" update-index -q --refresh >/dev/null 2>&1 || :
    git -C "$root" diff-index --quiet HEAD -- 2>/dev/null || dirty=-dirty
    printf '%s-%s-g%s%s\n' "$release" "$distance" "$short" "$dirty"
    exit 0
  fi
fi

v="$(git -C "$root" describe --tags --always --dirty --match 'v[0-9]*' 2>/dev/null)" || v=""
case "$v" in
  v[0-9]*) ;;
  "")      v=dev ;;
  *)       v="dev-g$v" ;;
esac
printf '%s\n' "$v"
