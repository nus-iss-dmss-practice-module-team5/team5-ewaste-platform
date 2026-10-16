#!/usr/bin/env python3
"""Turn SonarQube API results into a Markdown and HTML report (EWCSB-118).

Reads, from --input-dir, the JSON saved by the CI job:
  status.json    /api/qualitygates/project_status
  measures.json  /api/measures/component
  issues.json    /api/issues/search
  hotspots.json  /api/hotspots/search
Writes report.md (also used as the job summary) and report.html.
"""

from __future__ import annotations

import argparse
import html
import json
from collections import Counter
from pathlib import Path

RATINGS = {"1.0": "A", "2.0": "B", "3.0": "C", "4.0": "D", "5.0": "E"}
SEVERITY_ORDER = ["BLOCKER", "HIGH", "CRITICAL", "MEDIUM", "MAJOR", "LOW", "MINOR", "INFO"]
TOP_SEVERITIES = {"BLOCKER", "HIGH", "CRITICAL"}
MAX_LISTED = 50

# (area, label, count metrics, rating metrics). Newer SonarQube versions
# report the first three areas as software-quality metrics; older ones use the
# classic names. The first metric present wins.
OVERVIEW = [
    ("Reliability", "Bugs",
     ("software_quality_reliability_issues", "bugs"),
     ("software_quality_reliability_rating", "reliability_rating")),
    ("Security", "Vulnerabilities",
     ("software_quality_security_issues", "vulnerabilities"),
     ("software_quality_security_rating", "security_rating")),
    ("Security review", "Security hotspots",
     ("security_hotspots",),
     ("security_review_rating",)),
    ("Maintainability", "Code smells",
     ("software_quality_maintainability_issues", "code_smells"),
     ("software_quality_maintainability_rating", "sqale_rating")),
]


def load(directory: Path, name: str) -> dict:
    path = directory / name
    if not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8") or "{}")


def measures_by_key(measures: dict) -> dict[str, str]:
    return {m["metric"]: m.get("value", "") for m in measures.get("component", {}).get("measures", [])}


def first(values: dict[str, str], keys: tuple[str, ...]) -> str:
    return next((values[k] for k in keys if values.get(k) not in (None, "")), "")


def rating(value: str) -> str:
    return RATINGS.get(value, value or "-")


def percent(value: str) -> str:
    return f"{float(value):.1f}%" if value else "-"


def issue_kind(issue: dict) -> tuple[str, str]:
    """(quality, severity), preferring the newer `impacts` field when present."""
    impacts = issue.get("impacts") or []
    if impacts:
        top = min(impacts, key=lambda i: SEVERITY_ORDER.index(i.get("severity", "INFO"))
                  if i.get("severity") in SEVERITY_ORDER else len(SEVERITY_ORDER))
        return top.get("softwareQuality", "-").title(), top.get("severity", "-")
    kind = {"BUG": "Reliability", "VULNERABILITY": "Security", "CODE_SMELL": "Maintainability"}
    return kind.get(issue.get("type", ""), issue.get("type", "-")), issue.get("severity", "-")


def severity_rank(severity: str) -> int:
    return SEVERITY_ORDER.index(severity) if severity in SEVERITY_ORDER else len(SEVERITY_ORDER)


def location(item: dict, project_key: str) -> str:
    component = item.get("component", "")
    if component.startswith(project_key + ":"):
        component = component[len(project_key) + 1:]
    line = item.get("line")
    return f"{component}:{line}" if line else component


def build(directory: Path, project_key: str, commit: str, run_url: str) -> dict:
    status = load(directory, "status.json").get("projectStatus", {})
    values = measures_by_key(load(directory, "measures.json"))
    issues = load(directory, "issues.json").get("issues", [])
    hotspots = load(directory, "hotspots.json").get("hotspots", [])

    overview = [
        {"area": area, "label": label, "count": first(values, count_keys) or "-",
         "rating": rating(first(values, rating_keys))}
        for area, label, count_keys, rating_keys in OVERVIEW
    ]
    kinds = [issue_kind(issue) for issue in issues]
    by_severity = Counter(severity for _, severity in kinds)
    top_issues = sorted(
        ({"severity": sev, "quality": quality, "rule": issue.get("rule", ""),
          "where": location(issue, project_key), "message": issue.get("message", "")}
         for issue, (quality, sev) in zip(issues, kinds) if sev in TOP_SEVERITIES),
        key=lambda i: (severity_rank(i["severity"]), i["where"]),
    )
    return {
        "project_key": project_key,
        "commit": commit,
        "run_url": run_url,
        "gate": status.get("status", "NONE"),
        "conditions": [
            {"metric": c.get("metricKey", ""), "status": c.get("status", ""),
             "actual": c.get("actualValue", "-"), "threshold": c.get("errorThreshold", "-")}
            for c in status.get("conditions", [])
        ],
        "overview": overview,
        "coverage": percent(values.get("coverage", "")),
        "duplication": percent(values.get("duplicated_lines_density", "")),
        "lines": values.get("ncloc", "-"),
        "issue_total": len(issues),
        "by_severity": sorted(by_severity.items(), key=lambda kv: severity_rank(kv[0])),
        "top_issues": top_issues,
        "hotspots": [
            {"category": h.get("securityCategory", "-"), "probability": h.get("vulnerabilityProbability", "-"),
             "where": location(h, project_key), "message": h.get("message", "")}
            for h in hotspots
        ],
    }


def to_markdown(r: dict) -> str:
    gate = {"OK": "Passed", "ERROR": "Failed", "NONE": "Not computed"}.get(r["gate"], r["gate"])
    out = [
        "## SonarQube Report",
        "",
        f"- Project: `{r['project_key']}`",
        f"- Commit: `{r['commit']}`",
        f"- Quality gate: **{gate}**",
    ]
    if r["run_url"]:
        out.append(f"- Run: {r['run_url']}")
    out += ["", "| Area | Measure | Count | Rating |", "| :--- | :--- | ---: | :---: |"]
    out += [f"| {o['area']} | {o['label']} | {o['count']} | {o['rating']} |" for o in r["overview"]]
    out += [
        "",
        f"Coverage: **{r['coverage']}** · Duplications: **{r['duplication']}** · Lines of code: **{r['lines']}**",
        "",
    ]
    if r["conditions"]:
        out += ["### Quality gate conditions", "", "| Metric | Status | Actual | Threshold |",
                "| :--- | :---: | ---: | ---: |"]
        out += [f"| {c['metric']} | {c['status']} | {c['actual']} | {c['threshold']} |" for c in r["conditions"]]
        out.append("")
    out += [f"### Issues ({r['issue_total']})", ""]
    if r["by_severity"]:
        out += ["| Severity | Count |", "| :--- | ---: |"]
        out += [f"| {sev} | {count} |" for sev, count in r["by_severity"]]
        out.append("")
    if r["top_issues"]:
        listed = r["top_issues"][:MAX_LISTED]
        out += [f"Highest-severity issues ({len(listed)} of {len(r['top_issues'])}):", "",
                "| Severity | Quality | Location | Rule | Message |", "| :--- | :--- | :--- | :--- | :--- |"]
        out += [f"| {i['severity']} | {i['quality']} | `{i['where']}` | `{i['rule']}` | {md_cell(i['message'])} |"
                for i in listed]
        out.append("")
    out += [f"### Security hotspots to review ({len(r['hotspots'])})", ""]
    if r["hotspots"]:
        out += ["| Probability | Category | Location | Message |", "| :--- | :--- | :--- | :--- |"]
        out += [f"| {h['probability']} | {h['category']} | `{h['where']}` | {md_cell(h['message'])} |"
                for h in r["hotspots"][:MAX_LISTED]]
        out.append("")
    return "\n".join(out) + "\n"


def md_cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def to_html(r: dict) -> str:
    e = html.escape
    gate_class = {"OK": "ok", "ERROR": "error"}.get(r["gate"], "none")
    gate_text = {"OK": "Passed", "ERROR": "Failed", "NONE": "Not computed"}.get(r["gate"], r["gate"])
    cards = "".join(
        f'<div class="card"><div class="rating r{e(o["rating"])}">{e(o["rating"])}</div>'
        f'<div class="count">{e(str(o["count"]))}</div><div class="label">{e(o["label"])}</div>'
        f'<div class="area">{e(o["area"])}</div></div>'
        for o in r["overview"]
    )

    def table(headers: list[str], rows: list[list[str]]) -> str:
        if not rows:
            return "<p class=\"muted\">None.</p>"
        head = "".join(f"<th>{e(h)}</th>" for h in headers)
        body = "".join("<tr>" + "".join(f"<td>{e(str(c))}</td>" for c in row) + "</tr>" for row in rows)
        return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"

    conditions = table(["Metric", "Status", "Actual", "Threshold"],
                       [[c["metric"], c["status"], c["actual"], c["threshold"]] for c in r["conditions"]])
    severities = table(["Severity", "Count"], [[s, n] for s, n in r["by_severity"]])
    issues = table(["Severity", "Quality", "Location", "Rule", "Message"],
                   [[i["severity"], i["quality"], i["where"], i["rule"], i["message"]]
                    for i in r["top_issues"][:MAX_LISTED]])
    hotspots = table(["Probability", "Category", "Location", "Message"],
                     [[h["probability"], h["category"], h["where"], h["message"]]
                      for h in r["hotspots"][:MAX_LISTED]])
    run = f'<a href="{e(r["run_url"])}">CI run</a> · ' if r["run_url"] else ""
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>SonarQube Report</title>
<style>
:root {{ --bg:#fff; --fg:#1f2328; --muted:#59636e; --line:#d1d9e0; --card:#f6f8fa; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#0d1117; --fg:#e6edf3; --muted:#9198a1; --line:#3d444d; --card:#151b23; }} }}
body {{ background:var(--bg); color:var(--fg); font:15px/1.5 system-ui,sans-serif; margin:0 auto; max-width:1100px; padding:24px 16px; }}
h1 {{ margin:0 0 4px; }} h2 {{ margin-top:32px; }} .muted, .meta {{ color:var(--muted); }}
.gate {{ display:inline-block; padding:4px 12px; border-radius:6px; font-weight:600; color:#fff; }}
.gate.ok {{ background:#1a7f37; }} .gate.error {{ background:#cf222e; }} .gate.none {{ background:#59636e; }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(200px,1fr)); gap:12px; margin-top:16px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:8px; padding:16px; }}
.rating {{ display:inline-block; width:32px; height:32px; line-height:32px; text-align:center; border-radius:50%; font-weight:700; color:#fff; background:#59636e; }}
.rA {{ background:#1a7f37; }} .rB {{ background:#4d8f1f; }} .rC {{ background:#bf8700; }} .rD {{ background:#d1561e; }} .rE {{ background:#cf222e; }}
.count {{ font-size:28px; font-weight:700; margin-top:8px; }} .label {{ font-weight:600; }} .area {{ color:var(--muted); font-size:13px; }}
.stats {{ margin-top:16px; }}
table {{ border-collapse:collapse; width:100%; margin-top:8px; font-size:14px; }}
th, td {{ border-bottom:1px solid var(--line); padding:6px 8px; text-align:left; vertical-align:top; overflow-wrap:anywhere; }}
.wrap {{ overflow-x:auto; }}
</style></head><body>
<h1>SonarQube Report</h1>
<div class="meta">{e(r["project_key"])} · commit {e(r["commit"])} · {run}</div>
<p>Quality gate: <span class="gate {gate_class}">{e(gate_text)}</span></p>
<div class="cards">{cards}</div>
<p class="stats">Coverage <b>{e(r["coverage"])}</b> · Duplications <b>{e(r["duplication"])}</b> · Lines of code <b>{e(str(r["lines"]))}</b></p>
<h2>Quality gate conditions</h2><div class="wrap">{conditions}</div>
<h2>Issues ({r["issue_total"]})</h2><div class="wrap">{severities}</div>
<h2>Highest-severity issues</h2><div class="wrap">{issues}</div>
<h2>Security hotspots to review ({len(r["hotspots"])})</h2><div class="wrap">{hotspots}</div>
</body></html>
"""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--project-key", required=True)
    parser.add_argument("--commit", default="")
    parser.add_argument("--run-url", default="")
    args = parser.parse_args(argv)

    report = build(Path(args.input_dir), args.project_key, args.commit, args.run_url)
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "report.md").write_text(to_markdown(report), encoding="utf-8")
    (out / "report.html").write_text(to_html(report), encoding="utf-8")
    (out / "summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
