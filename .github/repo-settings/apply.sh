#!/usr/bin/env bash
#
# Applies the reviewed repository settings to GitHub:
#   .github/repo-settings/repository.json    merge settings (PATCH /repos/{repo})
#   .github/repo-settings/actions.json       Actions token default + fork PR approval policy
#   .github/repo-settings/environments.json  deployment environments + branch policies
#   .github/rulesets/*.json                  branch/tag rulesets (matched by name)
#
# Dry run by default: prints current vs desired state and changes nothing.
# Pass --apply to make the changes. Re-running is safe; rulesets are updated
# in place by name, never duplicated. Settings that exist on GitHub but are not
# described here (other rulesets, extra branch policies) are reported, not removed.
#
# Only run --apply from a clean checkout of the merged commit on the target
# repo's default branch, so that what is applied is exactly what was reviewed.
# See RELEASING.md.
#
# Usage: .github/repo-settings/apply.sh [--repo owner/name] [--apply] [--yes]

set -euo pipefail

REPO="systemjs/systemjs"
APPLY=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --yes) YES=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

for bin in gh jq git diff; do
  command -v "$bin" >/dev/null || { echo "Missing required tool: $bin" >&2; exit 1; }
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RULESETS_DIR="$ROOT/.github/rulesets"
CHANGES=0

dirty="$(git -C "$ROOT" status --porcelain -- .github/rulesets .github/repo-settings)"
if [ -n "$dirty" ]; then
  echo "Settings files have uncommitted changes:" >&2
  echo "$dirty" >&2
  if [ "$APPLY" = 1 ]; then
    echo "Refusing to --apply settings that are not committed." >&2
    exit 1
  fi
fi

echo "Repository:    $REPO"
echo "Source commit: $(git -C "$ROOT" log -1 --format='%h %s')"
echo "Mode:          $([ "$APPLY" = 1 ] && echo APPLY || echo dry-run)"

if [ "$APPLY" = 1 ] && [ "$YES" = 0 ]; then
  if [ ! -t 0 ]; then
    echo "Non-interactive --apply requires --yes." >&2
    exit 1
  fi
  read -r -p "Type the repository name ($REPO) to confirm: " answer
  [ "$answer" = "$REPO" ] || { echo "Aborted." >&2; exit 1; }
fi

# Prints a unified diff of current -> desired; returns 1 when they differ.
compare() {
  local current="$1" desired="$2"
  if diff -u --label current --label desired \
      <(printf '%s\n' "$current" | jq -S .) <(printf '%s\n' "$desired" | jq -S .); then
    echo "  up to date"
    return 0
  fi
  CHANGES=$((CHANGES + 1))
  return 1
}

# Projects a ruleset onto the fields this repo manages, so API-added defaults
# don't show up as differences. Rules that exist only on GitHub are kept whole.
NORMALIZE_RULESET='
  def rules_like($want):
    [ .rules[]? as $c
      | (first($want.rules[]? | select(.type == $c.type)) // null) as $w
      | if $w == null then $c
        elif $w.parameters == null then { type: $c.type }
        else { type: $c.type,
               parameters: (($c.parameters // {})
                 | with_entries(select(.key as $k | $w.parameters | has($k)))) }
        end
    ] | sort_by(.type);
  {
    name, target, enforcement,
    conditions: { ref_name: { include: (.conditions.ref_name.include // []),
                              exclude: (.conditions.ref_name.exclude // []) } },
    bypass_actors: [ .bypass_actors[]? | { actor_id, actor_type, bypass_mode } ],
    rules: rules_like($want)
  }'

echo
echo "== Merge settings (.github/repo-settings/repository.json)"
want="$(cat "$HERE/repository.json")"
current="$(gh api "repos/$REPO" | jq --argjson want "$want" \
  'with_entries(select(.key as $k | $want | has($k)))')"
if ! compare "$current" "$want" && [ "$APPLY" = 1 ]; then
  gh api -X PATCH "repos/$REPO" --input "$HERE/repository.json" >/dev/null
  echo "  applied"
fi

echo
echo "== Actions permissions (.github/repo-settings/actions.json)"
for setting in workflow fork_pr_contributor_approval; do
  endpoint="repos/$REPO/actions/permissions/${setting//_/-}"
  want="$(jq ".$setting" "$HERE/actions.json")"
  echo "-- $setting"
  current="$(gh api "$endpoint" | jq --argjson want "$want" \
    'with_entries(select(.key as $k | $want | has($k)))')"
  if ! compare "$current" "$want" && [ "$APPLY" = 1 ]; then
    gh api -X PUT "$endpoint" --input - <<<"$want" >/dev/null
    echo "  applied"
  fi
done

echo
echo "== Rulesets (.github/rulesets/*.json)"
existing="$(gh api "repos/$REPO/rulesets?includes_parents=false" --paginate | jq -s 'add // []')"
managed_names="[]"
for file in "$RULESETS_DIR"/*.json; do
  want="$(cat "$file")"
  name="$(jq -r .name "$file")"
  managed_names="$(jq --arg n "$name" '. + [$n]' <<<"$managed_names")"
  want_norm="$(jq --argjson want "$want" "$NORMALIZE_RULESET" <<<"$want")"
  id="$(jq -r --arg n "$name" 'first(.[] | select(.name == $n) | .id) // empty' <<<"$existing")"
  echo "-- $name ($(basename "$file"))"
  if [ -z "$id" ]; then
    echo "  missing: will be created"
    CHANGES=$((CHANGES + 1))
    if [ "$APPLY" = 1 ]; then
      gh api -X POST "repos/$REPO/rulesets" --input "$file" >/dev/null
      echo "  created"
    fi
    continue
  fi
  current_norm="$(gh api "repos/$REPO/rulesets/$id" | jq --argjson want "$want" "$NORMALIZE_RULESET")"
  if ! compare "$current_norm" "$want_norm" && [ "$APPLY" = 1 ]; then
    gh api -X PUT "repos/$REPO/rulesets/$id" --input "$file" >/dev/null
    echo "  updated (id $id)"
  fi
done
unmanaged="$(jq -r --argjson m "$managed_names" '.[] | select(.name as $n | $m | index($n) | not) | "\(.name) (id \(.id))"' <<<"$existing")"
if [ -n "$unmanaged" ]; then
  echo "-- Rulesets on GitHub not described here (left untouched):"
  printf '  %s\n' "$unmanaged"
fi

echo
echo "== Environments (.github/repo-settings/environments.json)"
count="$(jq length "$HERE/environments.json")"
i=0
while [ "$i" -lt "$count" ]; do
  env_name="$(jq -r ".[$i].name" "$HERE/environments.json")"
  want_branches="$(jq -c ".[$i].deployment_branches | sort" "$HERE/environments.json")"
  want_reviewers="$(jq -c ".[$i].reviewers // [] | sort" "$HERE/environments.json")"
  want="$(jq -n --argjson b "$want_branches" --argjson r "$want_reviewers" \
    '{ deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }, branches: $b, reviewers: $r }')"
  echo "-- $env_name"
  if env_json="$(gh api "repos/$REPO/environments/$env_name" 2>/dev/null)"; then
    branches="$(gh api "repos/$REPO/environments/$env_name/deployment-branch-policies" \
      | jq -c '[ .branch_policies[] | select((.type // "branch") == "branch") | .name ] | sort')"
    current="$(jq --argjson b "$branches" \
      '{ deployment_branch_policy: (.deployment_branch_policy // null), branches: $b,
         reviewers: ([ .protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]
                       | .reviewer.login // .reviewer.slug ] | sort) }' <<<"$env_json")"
  else
    current='{"deployment_branch_policy": null, "branches": [], "reviewers": [], "missing": true}'
  fi
  if ! compare "$current" "$want" && [ "$APPLY" = 1 ]; then
    reviewer_ids="[]"
    for login in $(jq -r '.[]' <<<"$want_reviewers"); do
      reviewer_ids="$(jq --argjson id "$(gh api "users/$login" --jq .id)" \
        '. + [{ type: "User", id: $id }]' <<<"$reviewer_ids")"
    done
    jq -n --argjson r "$reviewer_ids" \
      '{ deployment_branch_policy: { protected_branches: false, custom_branch_policies: true }, reviewers: $r }' \
      | gh api -X PUT "repos/$REPO/environments/$env_name" --input - >/dev/null
    have="$(gh api "repos/$REPO/environments/$env_name/deployment-branch-policies" \
      | jq -c '[ .branch_policies[] | .name ]')"
    for branch in $(jq -r '.[]' <<<"$want_branches"); do
      if ! jq -e --arg b "$branch" 'index($b)' <<<"$have" >/dev/null; then
        gh api -X POST "repos/$REPO/environments/$env_name/deployment-branch-policies" \
          -f name="$branch" -f type=branch >/dev/null
      fi
    done
    extra="$(jq -r --argjson w "$want_branches" '.[] | select(. as $b | $w | index($b) | not)' <<<"$have")"
    [ -z "$extra" ] || echo "  note: extra branch policies left in place: $extra"
    echo "  applied"
  fi
  i=$((i + 1))
done

echo
if [ "$APPLY" = 1 ]; then
  echo "Done."
elif [ "$CHANGES" = 0 ]; then
  echo "Everything is up to date."
else
  echo "$CHANGES setting group(s) differ. Re-run with --apply to change them."
fi
