# Open source and App Store release

A checklist for making the repo public and shipping to the App Store. Steps marked **(owner)** need
the repo owner's decision or account.

## 1. Before the repo goes public

| Item | Status |
|---|---|
| MIT `LICENSE`, `CONTRIBUTING.md`, `.github/SECURITY.md`, `PRIVACY.md`, `.github/CODEOWNERS` | Done |
| Third-party licenses shown in the app (Settings > Open Source Licenses) and in `App/Acknowledgements.txt` | Done |
| History scanned for onion addresses, client keys, signing files, team IDs, real Bitcoin addresses, private IPs | Clean: only public test vectors and placeholders |
| Personal phone name moved out of the `Makefile` into ignored `Config/local.mk` | Done |
| Commit author email | Done: history rewritten to the GitHub noreply address, which this repo now commits with |
| Earlier *Game of Thrones* theme | Done: replaced with a neutral night-sky theme and a new crescent moon icon |

## 2. Make public and lock down **(owner)**

Run from the repo, as the owner, in this order. Making the repo public can't be fully undone: forks,
clones and caches keep what they saw.

```sh
R=ehallmark/electrs-watch
OWNER_ID=$(gh api user --jq .id)

gh repo edit $R --visibility public --accept-visibility-change-consequences
gh repo edit $R --enable-projects=false --enable-wiki=false --delete-branch-on-merge \
  --enable-merge-commit=false --enable-rebase-merge=false --enable-squash-merge

# Private vulnerability reports, secret scanning and push protection.
gh api -X PUT repos/$R/private-vulnerability-reporting
gh api -X PATCH repos/$R --input - <<'EOF'
{"security_and_analysis": {"secret_scanning": {"status": "enabled"},
                           "secret_scanning_push_protection": {"status": "enabled"}}}
EOF

# Actions: read-only token, GitHub's own actions only, and every outside contributor's
# workflow run needs approval.
gh api -X PUT repos/$R/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
gh api -X PUT repos/$R/actions/permissions -F enabled=true -f allowed_actions=selected
gh api -X PUT repos/$R/actions/permissions/selected-actions \
  -F github_owned_allowed=true -F verified_allowed=false
gh api -X PUT repos/$R/actions/permissions/fork-pr-contributor-approval \
  -f approval_policy=all_external_contributors

# The signing secrets' environment: runs only from main, only after the owner approves.
gh api -X PUT repos/$R/environments/testflight --input - <<EOF
{"reviewers": [{"type": "User", "id": $OWNER_ID}],
 "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}}
EOF

# main: no force pushes or deletion, linear history, changes by pull request with a code owner's
# review and passing CI. The owner can merge their own pull requests but can't push straight to main.
gh api -X POST repos/$R/rulesets --input - <<'EOF'
{"name": "main", "target": "branch", "enforcement": "active",
 "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
 "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "pull_request"}],
 "rules": [
   {"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "required_linear_history"},
   {"type": "pull_request", "parameters": {"required_approving_review_count": 1,
     "require_code_owner_review": true, "dismiss_stale_reviews_on_push": true,
     "require_last_push_approval": true, "required_review_thread_resolution": true}},
   {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true,
     "required_status_checks": [{"context": "test"}]}}
 ]}
EOF
```

After this, changes land through pull requests, including the owner's. Then add the signing secrets to
the `testflight` environment as in `docs/RELEASING.md`, step 5.

## 3. App Store **(owner)**

| Item | Notes |
|---|---|
| Name | The display name has to be unique on the App Store. Check "electrs-watch" is free when creating the app record. The home screen shows the same name, which hints at Bitcoin to anyone who sees the phone; that was chosen knowingly |
| Privacy | Privacy policy URL: `PRIVACY.md` on GitHub. App Privacy answer: Data Not Collected |
| Encryption export | The app includes Tor, which uses standard, publicly available open source encryption. App Store Connect's export compliance questions found that it needs no documentation, so `ITSAppUsesNonExemptEncryption` is `NO`. Declaring `YES` without an `ITSEncryptionExportComplianceCode` makes uploads fail with error 90592. Revisit this if the app adds other encryption |
| App Review access | Reviewers can't reach your node or authorize a key on it. Decide between a review-only demo server (an onion service with mock data and no client authorization) and a clearly labeled demo mode inside the app |
| Crypto rules | Guideline 3.1.5 limits wallets to organization accounts. This app holds no keys and can't move coins; say so plainly in the review notes |
| Listing | Category Finance, age rating 4+, screenshots, description, support URL (the GitHub issues page) |
| Builds | `docs/RELEASING.md` already produces signed App Store Connect uploads (TestFlight). The same build can be submitted for review |
