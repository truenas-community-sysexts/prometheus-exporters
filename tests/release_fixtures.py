"""Shared fixtures: GitHub release and issue objects as the API returns them.

Tags follow build.yml: v<YYYY.MM.DD>-r<run>. Release bodies carry
verified-train lines in the form promote.yml appends them;
test_workflow_contract.py holds the fixture to what promote.yml actually
writes, so a format change breaks CI instead of orphaning it.
"""
import re
from datetime import datetime, timedelta


def marker(train):
    return f"<!-- verified-train: {train} -->"


def tag(run):
    """The tag build.yml would give run number `run`."""
    return f"v2026.09.{run:02d}-r{run}"


def release(tag, prerelease=False, draft=False, trains=(), body=None,
            published=None):
    """A release tagged v<date>-r<run>. Published <run> hours after a fixed
    base, so a higher run number is newer unless `published` says otherwise."""
    m = re.search(r"-r(\d+)$", tag)
    run = int(m.group(1)) if m else 0
    if published is None:
        published = (datetime(2026, 1, 1) + timedelta(hours=run)).strftime(
            "%Y-%m-%dT%H:%M:%SZ")
    if body is None:
        body = "## prometheus-exporters sysext for TrueNAS SCALE\n"
        for t in trains:
            body += f"\n\n{marker(t)}\n"
    return {"id": run or abs(hash(tag)), "tag_name": tag, "body": body,
            "prerelease": prerelease, "draft": draft,
            "html_url": f"https://example.test/releases/tag/{tag}",
            "published_at": published, "created_at": published}


def issue(tag, train=None, labels=("hardware-test",), number=1, title=None):
    """A hardware-test issue with the markers build.yml writes."""
    body = f"**Release:** {tag}\n<!-- release-tag: {tag} -->\n"
    if train:
        body += f"<!-- train: {train} -->\n"
    return {"number": number, "title": title or f"Hardware test: prometheus-exporters {tag}",
            "body": body, "labels": [{"name": name} for name in labels]}
