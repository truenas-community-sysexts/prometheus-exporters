"""Run promote.yml's github-script under node with a stub GitHub client.

Each test closes a hardware-test issue against a canned release list and
checks the release update and issue comment the workflow would make. The
tracked trains come from the real .github/tracked-versions.json (25.10 is
stable, 26 is preview)."""
import copy
import unittest
from pathlib import Path

from release_fixtures import issue, marker, release, tag
from workflow_script import run_script, step_script

PROMOTE_YML = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "promote.yml"

HARNESS = """
const state = JSON.parse(require('fs').readFileSync(0, 'utf8'));
const out = { updates: [], comments: [], generated: [], compared: [] };
console.log = (...a) => process.stderr.write(a.join(' ') + '\\n');
const notFound = () => Object.assign(new Error('Not Found'), { status: 404 });
const github = {
  paginate: async (fn, args) => (await fn(args)).data,
  rest: {
    repos: {
      getReleaseByTag: async ({ tag }) => {
        const r = state.releases.find((x) => x.tag_name === tag);
        if (!r) throw notFound();
        return { data: r };
      },
      listReleases: async () => ({ data: state.releases }),
      generateReleaseNotes: async (args) => {
        out.generated.push(args);
        return { data: { body: "## What's Changed\\n* fix: a change by @someone" } };
      },
      compareCommitsWithBasehead: async (args) => {
        out.compared.push(args.basehead);
        return { data: { commits: [{ sha: 'abcdef1234567', commit: { message: 'fix: a change\\n\\nmore' } }] } };
      },
      updateRelease: async (args) => { out.updates.push(args); },
    },
    issues: { createComment: async (args) => { out.comments.push(args.body); } },
  },
};
const context = { repo: { owner: 'truenas-community-sysexts', repo: 'prometheus-exporters' },
                  payload: { issue: state.issue } };
const core = { info: () => {}, warning: () => {} };
(async () => {
%s
})().then(() => process.stdout.write(JSON.stringify(out)),
          (e) => { process.stderr.write(String(e && e.stack || e)); process.exit(1); });
"""

R4, R5, R6, R7 = (tag(n) for n in (4, 5, 6, 7))


def promote_script():
    return step_script("promote.yml", "Record the sign-off on the release this issue gates")


def close(iss, releases):
    return run_script(HARNESS, promote_script(), {"issue": iss, "releases": releases})


def apply(releases, update):
    """The release list after the workflow's updateRelease call."""
    rels = copy.deepcopy(releases)
    for r in rels:
        if r["id"] == update["release_id"]:
            r["prerelease"] = update.get("prerelease", r["prerelease"])
            r["body"] = update.get("body", r["body"])
    return rels


STABLE = dict(train="25.10", labels=("hardware-test",))
PREVIEW = dict(train="26", labels=("preview-hardware-test",))


class Approval(unittest.TestCase):
    def test_first_approval_flips_prerelease_adds_marker_and_changelog(self):
        rels = [release(R6, prerelease=True), release(R5)]
        out = close(issue(R6, **STABLE), rels)
        self.assertEqual(len(out["updates"]), 1, out)
        up = out["updates"][0]
        self.assertIs(up["prerelease"], False)
        self.assertEqual(up["body"].count(marker("25.10")), 1)
        self.assertEqual(up["body"].count("## Changelog"), 1)
        self.assertTrue(up["body"].startswith(rels[0]["body"]))
        self.assertIn("approved for train `25.10`", out["comments"][0])
        self.assertIn("first approval", out["comments"][0])

    def test_marker_is_in_the_same_update_as_the_flip(self):
        # A full release with no marker counts as approved for every train,
        # so flip and marker must never land in separate updates.
        rels = [release(R6, prerelease=True), release(R5)]
        out = close(issue(R6, **PREVIEW), rels)
        self.assertEqual(len(out["updates"]), 1)
        self.assertIs(out["updates"][0]["prerelease"], False)
        self.assertIn(marker("26"), out["updates"][0]["body"])

    def test_second_train_only_adds_its_marker(self):
        rels = [release(R6, prerelease=True), release(R5)]
        first = close(issue(R6, **PREVIEW), rels)
        rels = apply(rels, first["updates"][0])
        second = close(issue(R6, number=2, **STABLE), rels)
        self.assertEqual(len(second["updates"]), 1)
        body = second["updates"][0]["body"]
        self.assertTrue(body.startswith(rels[0]["body"]))
        self.assertEqual(body[len(rels[0]["body"]):].strip(), marker("25.10"))
        self.assertEqual(body.count("## Changelog"), 1)
        self.assertEqual(second["generated"], [])
        self.assertNotIn("first approval", second["comments"][0])

    def test_marker_is_added_once(self):
        rels = [release(R6, prerelease=True), release(R5)]
        first = close(issue(R6, **STABLE), rels)
        rels = apply(rels, first["updates"][0])
        again = close(issue(R6, number=3, **STABLE), rels)
        self.assertEqual(again["updates"], [])
        self.assertIn("already approved for TrueNAS 25.10", again["comments"][0])

    def test_grandfathered_release_is_left_alone(self):
        # A marker on a marker-less full release would narrow "every train"
        # down to this one.
        rels = [release(R5)]
        out = close(issue(R5, **PREVIEW), rels)
        self.assertEqual(out["updates"], [])
        self.assertIn("already approved for every train", out["comments"][0])

    def test_malformed_train_marker_changes_nothing(self):
        rels = [release(R6, prerelease=True)]
        out = close(issue(R6, train="26.0.0-BETA.3", labels=("preview-hardware-test",)), rels)
        self.assertEqual(out["updates"], [])
        self.assertIn("not a TrueNAS train key", out["comments"][0])

    def test_missing_release_is_reported(self):
        out = close(issue(tag(99), **STABLE), [release(R5)])
        self.assertEqual(out["updates"], [])
        self.assertIn(f"No release found for tag `{tag(99)}`", out["comments"][0])

    def test_changelog_starts_at_the_previous_approved_release(self):
        # r5 was never approved (still a prerelease): the range must reach
        # back to r4, the last release approved anywhere.
        rels = [release(R6, prerelease=True), release(R5, prerelease=True),
                release(R4)]
        out = close(issue(R6, **STABLE), rels)
        self.assertEqual(out["compared"], [f"{R4}...{R6}"])
        self.assertEqual(out["generated"][0]["previous_tag_name"], R4)


class Legacy(unittest.TestCase):
    # Issues opened before per-train issues carry no train marker.

    def test_issue_without_train_marker_keeps_the_old_promotion(self):
        rels = [release(R6, prerelease=True), release(R5)]
        out = close(issue(R6), rels)
        self.assertEqual(len(out["updates"]), 1)
        up = out["updates"][0]
        self.assertIs(up["prerelease"], False)
        self.assertEqual(up["make_latest"], "true")
        self.assertIn("## Changelog", up["body"])
        self.assertNotIn("verified-train", up["body"])

    def test_already_full_release_is_not_touched(self):
        out = close(issue(R5), [release(R5)])
        self.assertEqual(out["updates"], [])

    def test_preview_issue_without_train_marker_changes_nothing(self):
        rels = [release(R6, prerelease=True)]
        out = close(issue(R6, labels=("preview-hardware-test",)), rels)
        self.assertEqual(out["updates"], [])
        self.assertIn("does not say which TrueNAS train", out["comments"][0])


class MakeLatest(unittest.TestCase):
    def latest(self, iss, rels):
        out = close(iss, rels)
        self.assertEqual(len(out["updates"]), 1, out)
        return out["updates"][0]["make_latest"], out["comments"][0]

    def test_stable_approval_of_the_newest_release_takes_latest(self):
        ml, comment = self.latest(issue(R6, **STABLE),
                                  [release(R6, prerelease=True), release(R5)])
        self.assertEqual(ml, "true")
        self.assertIn("marked Latest", comment)

    def test_preview_approval_never_takes_latest(self):
        ml, _ = self.latest(issue(R6, **PREVIEW),
                            [release(R6, prerelease=True), release(R5)])
        self.assertEqual(ml, "false")

    def test_older_stable_approval_does_not_regress_latest(self):
        ml, comment = self.latest(issue(R6, **STABLE),
                                  [release(R7, trains=["25.10"]),
                                   release(R6, prerelease=True)])
        self.assertEqual(ml, "false")
        self.assertIn(f"Latest stays on the newer `{R7}`", comment)

    def test_release_approved_on_preview_only_cannot_hold_latest(self):
        ml, _ = self.latest(issue(R6, **STABLE),
                            [release(R7, trains=["26"]),
                             release(R6, prerelease=True), release(R5)])
        self.assertEqual(ml, "true")

    def test_grandfathered_newer_release_keeps_latest(self):
        ml, _ = self.latest(issue(R4, **STABLE),
                            [release(R5), release(R4, prerelease=True)])
        self.assertEqual(ml, "false")

    def test_preview_approval_keeps_latest_on_a_stable_approved_newest(self):
        ml, _ = self.latest(issue(R6, **PREVIEW),
                            [release(R6, trains=["25.10"]), release(R5)])
        self.assertEqual(ml, "true")

    def test_rank_is_the_run_number_not_the_date(self):
        # A rebuild of an older date still has a higher run number.
        newer = "v2026.09.01-r12"
        ml, comment = self.latest(issue("v2026.09.02-r11", **STABLE),
                                  [release(newer, trains=["25.10"]),
                                   release("v2026.09.02-r11", prerelease=True)])
        self.assertEqual(ml, "false")
        self.assertIn(f"Latest stays on the newer `{newer}`", comment)


class Trigger(unittest.TestCase):
    def test_job_runs_for_both_labels_on_completed_only(self):
        text = PROMOTE_YML.read_text()
        cond = text[text.index("    if: >-"):text.index("    runs-on:")]
        self.assertIn("'hardware-test'", cond)
        self.assertIn("'preview-hardware-test'", cond)
        self.assertIn("github.event.issue.state_reason == 'completed'", cond)


if __name__ == "__main__":
    unittest.main()
