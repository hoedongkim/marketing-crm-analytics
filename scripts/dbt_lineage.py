#!/usr/bin/env python3
"""Write docs/lineage.md: the lineage of the dbt project as Mermaid diagrams and tables.

    python scripts/dbt_lineage.py              # read dbt/target/manifest.json, (re)write docs/lineage.md
    python scripts/dbt_lineage.py --check      # exit 1 if docs/lineage.md differs from a fresh render
    python scripts/dbt_lineage.py --no-tests   # leave out the seeds and singular tests

`make dbt-lineage` runs `dbt parse` first (it writes the manifest without querying Snowflake),
then this script.

What the page shows
    1. Model lineage: RAW sources -> STAGING views -> the ephemeral intermediate model (dashed:
       it creates no object) -> MART tables -> exposures (the Data Studio dashboard and the
       Phase 4 analyses). An exposure that reads every model of a layer gets one edge from that
       layer instead of one edge per model.
    2. Seeds and singular tests: which test reads which seed of independent expected values.
    3. Tables: every model with its object, parents, children and test counts; every singular
       test with what it reads; every seed and exposure.

The output is deterministic (sorted, no timestamps), so --check can tell whether the committed
page still matches the project. GitHub renders ```mermaid blocks; the diagrams use shapes and a
dashed border, not colours, so they read in light and dark mode. Standard library only.

Exit codes: 0 ok; 1 --check found a difference; 2 the manifest is missing or unreadable.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "dbt" / "target" / "manifest.json"
DEFAULT_OUT = REPO_ROOT / "docs" / "lineage.md"

# Model layers in DAG order: the folder under models/ (fqn[1]) -> subgraph id and title.
LAYER_ORDER = ["staging", "intermediate", "marts"]
LAYER_SUBGRAPH = {"staging": "STAGING", "intermediate": "INTERMEDIATE", "marts": "MART"}


def mermaid_id(prefix: str, name: str) -> str:
    """A Mermaid node id: letters, digits and underscores only, with a type prefix."""
    return prefix + "_" + re.sub(r"[^A-Za-z0-9_]", "_", name)


def plural(count: int, word: str) -> str:
    return f"{count} {word}" + ("" if count == 1 else "s")


class Project:
    """The parts of manifest.json this page needs, for the root project only."""

    def __init__(self, manifest: dict) -> None:
        meta = manifest.get("metadata", {})
        self.dbt_version = meta.get("dbt_version", "?")
        self.name = meta.get("project_name") or next(
            n["package_name"] for n in manifest["nodes"].values() if n["resource_type"] == "model"
        )
        own = lambda n: n.get("package_name") == self.name  # noqa: E731  (skip package nodes)

        self.sources = {k: v for k, v in manifest.get("sources", {}).items() if own(v)}
        nodes = {k: v for k, v in manifest["nodes"].items() if own(v)}
        self.models = {k: v for k, v in nodes.items() if v["resource_type"] == "model"}
        self.seeds = {k: v for k, v in nodes.items() if v["resource_type"] == "seed"}
        self.tests = {k: v for k, v in nodes.items() if v["resource_type"] == "test"}
        self.unit_tests = {k: v for k, v in manifest.get("unit_tests", {}).items() if own(v)}
        self.exposures = {k: v for k, v in manifest.get("exposures", {}).items() if own(v)}

        self.children: dict[str, set[str]] = defaultdict(set)
        for uid, model in self.models.items():
            for parent in model["depends_on"]["nodes"]:
                self.children[parent].add(uid)

    # ---------------------------------------------------------------- naming helpers
    def layer(self, uid: str) -> str:
        fqn = self.models[uid]["fqn"]
        return fqn[1] if len(fqn) > 2 else "models"

    def materialized(self, uid: str) -> str:
        return self.models[uid]["config"]["materialized"]

    def relation(self, uid: str) -> str:
        """SCHEMA.NAME as Snowflake shows it (unquoted identifiers are upper case)."""
        node = self.models.get(uid) or self.seeds.get(uid)
        if node is not None:
            if node["resource_type"] == "model" and self.materialized(uid) == "ephemeral":
                return ""
            return f"{node['schema'].upper()}.{(node.get('alias') or node['name']).upper()}"
        source = self.sources[uid]
        return f"{source['schema'].upper()}.{(source.get('identifier') or source['name']).upper()}"

    def short(self, uid: str) -> str:
        """The name used in tables: model / seed name, or source:<source>.<table>."""
        if uid in self.sources:
            return f"source:{self.sources[uid]['source_name']}.{self.sources[uid]['name']}"
        if uid in self.models or uid in self.seeds:
            return (self.models.get(uid) or self.seeds[uid])["name"]
        return uid.split(".")[-1]

    def node_id(self, uid: str) -> str:
        if uid in self.sources:
            s = self.sources[uid]
            return mermaid_id("src", f"{s['source_name']}_{s['name']}")
        if uid in self.seeds:
            return mermaid_id("seed", self.seeds[uid]["name"])
        if uid in self.models:
            return mermaid_id("m", self.models[uid]["name"])
        if uid in self.tests:
            return mermaid_id("t", self.tests[uid]["name"])
        if uid in self.exposures:
            return mermaid_id("exp", self.exposures[uid]["name"])
        raise KeyError(uid)

    def label(self, uid: str) -> str:
        """Node label: the Snowflake object name, or the model name for an ephemeral model."""
        if uid in self.models and self.materialized(uid) == "ephemeral":
            return self.models[uid]["name"]
        if uid in self.sources or uid in self.models or uid in self.seeds:
            return self.relation(uid).split(".", 1)[1]
        if uid in self.exposures:
            e = self.exposures[uid]
            return e.get("label") or e["name"]
        return self.short(uid)

    # ---------------------------------------------------------------- ordering
    def models_in(self, layer: str) -> list[str]:
        return sorted((u for u in self.models if self.layer(u) == layer), key=self.label)

    def layers(self) -> list[str]:
        present = {self.layer(u) for u in self.models}
        return [l for l in LAYER_ORDER if l in present] + sorted(present - set(LAYER_ORDER))

    def sorted_sources(self) -> list[str]:
        return sorted(self.sources, key=self.label)

    # ---------------------------------------------------------------- tests per node
    def singular_tests(self) -> list[str]:
        return sorted(
            (u for u, t in self.tests.items() if not t.get("test_metadata")),
            key=lambda u: self.tests[u]["original_file_path"],
        )

    def generic_test_name(self, uid: str) -> str:
        meta = self.tests[uid]["test_metadata"]
        return f"{meta['namespace']}.{meta['name']}" if meta.get("namespace") else meta["name"]

    def tests_on(self, uid: str) -> tuple[int, int]:
        """(generic tests attached to the node, singular tests that read it)."""
        generic = sum(
            1 for t in self.tests.values() if t.get("test_metadata") and t.get("attached_node") == uid
        )
        singular = sum(
            1 for t in self.tests.values() if not t.get("test_metadata") and uid in t["depends_on"]["nodes"]
        )
        return generic, singular

    def unit_tests_on(self, uid: str) -> int:
        name = self.models[uid]["name"]
        return sum(1 for u in self.unit_tests.values() if u.get("model") == name)


# -------------------------------------------------------------------- diagrams
def model_diagram(p: Project) -> list[str]:
    lines = ["```mermaid", "flowchart LR"]
    sources = p.sorted_sources()
    if sources:
        schemas = sorted({p.sources[u]["schema"].upper() for u in sources})
        lines.append(f'  subgraph SOURCES["{" / ".join(schemas)}: {plural(len(sources), "source table")}"]')
        lines += [f'    {p.node_id(u)}[("{p.label(u)}")]' for u in sources]
        lines.append("  end")
    model_seeds = sorted({d for m in p.models.values() for d in m["depends_on"]["nodes"] if d in p.seeds}, key=p.label)
    if model_seeds:  # none today: the seeds are test inputs only
        lines.append('  subgraph MODEL_SEEDS["seeds read by models"]')
        lines += [f'    {p.node_id(u)}[("{p.label(u)}")]' for u in model_seeds]
        lines.append("  end")
    for layer in p.layers():
        members = p.models_in(layer)
        kinds = Counter(p.materialized(u) for u in members)
        kind_text = ", ".join(plural(n, "ephemeral model" if k == "ephemeral" else k) for k, n in sorted(kinds.items()))
        sub = LAYER_SUBGRAPH.get(layer, layer.upper())
        if kinds.get("ephemeral") == len(members):
            title = f"{layer}: {kind_text}, no object (models/{layer})"
        else:
            schemas = sorted({p.models[u]["schema"].upper() for u in members if p.materialized(u) != "ephemeral"})
            title = f"{' / '.join(schemas)}: {kind_text} (models/{layer})"
        lines.append(f'  subgraph {sub}["{title}"]')
        lines += [f'    {p.node_id(u)}["{p.label(u)}"]' for u in members]
        lines.append("  end")
    if p.exposures:
        lines.append('  subgraph EXPOSURES["exposures: downstream consumers"]')
        lines += [f'    {p.node_id(u)}(["{p.label(u)}"])' for u in sorted(p.exposures, key=p.label)]
        lines.append("  end")

    # Edges, in DAG order: into each model from its parents (sources first), then into each
    # exposure. An edge into or out of an ephemeral model is dashed.
    ephemeral = {u for u in p.models if p.materialized(u) == "ephemeral"}
    for layer in p.layers():
        for uid in p.models_in(layer):
            for parent in sorted(p.models[uid]["depends_on"]["nodes"], key=lambda x: (x not in p.sources, p.label(x))):
                arrow = "-.->" if (uid in ephemeral or parent in ephemeral) else "-->"
                lines.append(f"  {p.node_id(parent)} {arrow} {p.node_id(uid)}")
    for exp in sorted(p.exposures, key=p.label):
        deps = set(p.exposures[exp]["depends_on"]["nodes"])
        for layer in p.layers():
            members = set(p.models_in(layer))
            if members and members <= deps:
                lines.append(f"  {LAYER_SUBGRAPH.get(layer, layer.upper())} --> {p.node_id(exp)}")
                deps -= members
        for dep in sorted(deps, key=p.short):
            if dep in p.models or dep in p.sources:
                lines.append(f"  {p.node_id(dep)} --> {p.node_id(exp)}")

    if ephemeral:
        lines.append("  classDef ephemeral stroke-dasharray: 5 5")
        lines.append("  class " + ",".join(p.node_id(u) for u in sorted(ephemeral, key=p.label)) + " ephemeral")
    lines.append("```")
    return lines


def test_diagram(p: Project) -> list[str]:
    """Seeds -> the singular tests that read them (models are listed in the table below)."""
    readers = [u for u in p.singular_tests() if any(d in p.seeds for d in p.tests[u]["depends_on"]["nodes"])]
    if not p.seeds or not readers:
        return []
    lines = ["```mermaid", "flowchart LR"]
    schemas = sorted({p.seeds[u]["schema"].upper() for u in p.seeds})
    lines.append(f'  subgraph SEEDS["seeds in {" / ".join(schemas)}: test inputs only"]')
    lines += [f'    {p.node_id(u)}[("{p.label(u)}")]' for u in sorted(p.seeds, key=p.label)]
    lines.append("  end")
    lines.append(f'  subgraph SINGULAR["singular tests that read a seed: {len(readers)} of {len(p.singular_tests())}"]')
    lines += [f'    {p.node_id(u)}{{{{"{p.tests[u]["name"]}"}}}}' for u in readers]
    lines.append("  end")
    for seed in sorted(p.seeds, key=p.label):
        for test in readers:
            if seed in p.tests[test]["depends_on"]["nodes"]:
                lines.append(f"  {p.node_id(seed)} -.-> {p.node_id(test)}")
    lines.append("```")
    return lines


# -------------------------------------------------------------------- tables
def model_table(p: Project) -> list[str]:
    lines = [
        "| Model | Layer | Materialized | Snowflake object | Parents | Children | Data tests (generic + singular) | Unit tests |",
        "|---|---|---|---|---|---|---:|---:|",
    ]
    for layer in p.layers():
        for uid in p.models_in(layer):
            names = lambda uids: ", ".join(f"`{x}`" for x in sorted(map(p.short, uids))) or "-"  # noqa: E731
            relation = p.relation(uid)
            generic, singular = p.tests_on(uid)
            lines.append(
                f"| `{p.models[uid]['name']}` | {layer} | {p.materialized(uid)} | "
                f"{f'`{relation}`' if relation else 'none (compiled into its children as a CTE)'} | "
                f"{names(p.models[uid]['depends_on']['nodes'])} | {names(p.children.get(uid, ()))} | "
                f"{generic} + {singular} | {p.unit_tests_on(uid)} |"
            )
    return lines


def singular_table(p: Project) -> list[str]:
    lines = ["| Singular test | Severity | Models read | Seeds read | Sources read |", "|---|---|---|---|---|"]
    for uid in p.singular_tests():
        deps = p.tests[uid]["depends_on"]["nodes"]
        cell = lambda pool: ", ".join(f"`{p.short(d)}`" for d in sorted(deps, key=p.short) if d in pool) or "-"  # noqa: E731
        lines.append(
            f"| [`{p.tests[uid]['name']}`](../dbt/{p.tests[uid]['original_file_path']}) | "
            f"{p.tests[uid]['config']['severity'].lower()} | {cell(p.models)} | {cell(p.seeds)} | {cell(p.sources)} |"
        )
    return lines


def seed_table(p: Project) -> list[str]:
    lines = ["| Seed | Snowflake object | Read by models | Generic tests on it | Singular tests that read it |",
             "|---|---|---:|---:|---:|"]
    for uid in sorted(p.seeds, key=p.label):
        generic, singular = p.tests_on(uid)
        lines.append(
            f"| [`{p.seeds[uid]['name']}`](../dbt/{p.seeds[uid]['original_file_path']}) | `{p.relation(uid)}` | "
            f"{len(p.children.get(uid, ()))} | {generic} | {singular} |"
        )
    return lines


def exposure_table(p: Project) -> list[str]:
    lines = ["| Exposure | dbt name | Type | Maturity | Reads |", "|---|---|---|---|---|"]
    for uid in sorted(p.exposures, key=p.label):
        e = p.exposures[uid]
        deps = sorted(p.short(d) for d in e["depends_on"]["nodes"])
        lines.append(f"| {p.label(uid)} | `{e['name']}` | {e['type']} | {e.get('maturity') or '-'} | "
                     f"{plural(len(deps), 'model')}: {', '.join(f'`{d}`' for d in deps)} |")
    return lines


def inventory(p: Project) -> list[str]:
    kinds = Counter(p.materialized(u) for u in p.models)
    generic = Counter(p.generic_test_name(u) for u, t in p.tests.items() if t.get("test_metadata"))
    singular = p.singular_tests()
    # A generic test on a source column has no attached model or seed; it depends on the source.
    source_tests = sum(
        1 for t in p.tests.values()
        if t.get("test_metadata") and not t.get("attached_node") and any(d in p.sources for d in t["depends_on"]["nodes"])
    )
    seed_tests = sum(1 for t in p.tests.values() if t.get("test_metadata") and t.get("attached_node") in p.seeds)
    severities = Counter(t["config"]["severity"].lower() for t in p.tests.values())
    lines = [
        "| Resource | Count |",
        "|---|---:|",
        f"| Sources (RAW tables) | {len(p.sources)} |",
        f"| Models | {len(p.models)} ({', '.join(plural(n, k) for k, n in sorted(kinds.items()))}) |",
        f"| Seeds | {len(p.seeds)} |",
        f"| Data tests | {len(p.tests)} (severity {', '.join(f'{k} {n}' for k, n in sorted(severities.items()))}) |",
    ]
    for name, n in sorted(generic.items(), key=lambda kv: (-kv[1], kv[0])):
        lines.append(f"| &nbsp;&nbsp;`{name}` | {n} |")
    lines.append(f"| &nbsp;&nbsp;singular (`dbt/tests/`) | {len(singular)} |")
    lines.append(f"| &nbsp;&nbsp;of which on RAW source columns / on seed columns | {source_tests} / {seed_tests} |")
    lines.append(f"| Unit tests | {len(p.unit_tests)} |")
    lines.append(f"| Exposures | {len(p.exposures)} |")
    return lines


# -------------------------------------------------------------------- page
def render(p: Project, with_tests: bool) -> str:
    out: list[str] = [
        "# dbt lineage",
        "",
        "<!-- Generated by scripts/dbt_lineage.py from dbt/target/manifest.json. Do not edit by hand:",
        "     run `make dbt-lineage` (dbt parse + this script); `--check` tells whether it is current. -->",
        "",
        f"The DAG of the dbt project `{p.name}` (dbt Core {p.dbt_version}), generated from",
        "`dbt/target/manifest.json` by [`scripts/dbt_lineage.py`](../scripts/dbt_lineage.py)",
        "(`make dbt-lineage`). How the project is built and tested: [dbt.md](dbt.md). The interactive",
        "version of the same graph is the dbt docs site: `make dbt-docs` writes",
        "`dbt/target/static_index.html` (one file, opens from disk; not committed).",
        "",
        "## Model lineage",
        "",
        "RAW sources on the left, then the STAGING views, the ephemeral intermediate model (dashed",
        "border and dashed edges: dbt compiles it into its child as a CTE, so it creates no object),",
        "the MART tables and, on the right, the exposures that read them. An exposure that reads",
        "every model of a layer has one edge from that layer. Node labels are the Snowflake object",
        "names (dbt model names are the same in lower case).",
        "",
    ]
    out += model_diagram(p)
    out += ["", "## Inventory", ""] + inventory(p)
    out += ["", "## Models", "",
            "Parents and children are models and sources only; tests are counted per model (generic",
            "tests attached to the model, plus singular tests that read it).", ""]
    out += model_table(p)
    if with_tests:
        diagram = test_diagram(p)
        out += ["", "## Seeds and singular tests", "",
                "The seeds hold expected values computed without Snowflake (`scripts/independent_check.py`)",
                "and the publisher's reference output. No model reads them: they are inputs of the singular",
                "tests, which compare the models with them.", ""]
        if diagram:
            out += diagram + [""]
        out += seed_table(p) + [""] + singular_table(p)
    if p.exposures:
        out += ["", "## Exposures", ""] + exposure_table(p)
    out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--check", action="store_true", help="compare with --out instead of writing it")
    parser.add_argument("--no-tests", action="store_true", help="leave out the seeds and singular tests")
    args = parser.parse_args()

    try:
        manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"ERROR cannot read {args.manifest}: {exc}\n      run `make dbt-lineage` (dbt parse writes it)", file=sys.stderr)
        return 2
    page = render(Project(manifest), with_tests=not args.no_tests)

    shown = args.out.relative_to(REPO_ROOT) if args.out.is_relative_to(REPO_ROOT) else args.out
    if args.check:
        current = args.out.read_text(encoding="utf-8") if args.out.exists() else ""
        if current == page:
            print(f"OK    {shown} matches the manifest")
            return 0
        print(f"DIFF  {shown} is out of date: run `make dbt-lineage`")
        return 1
    tmp = args.out.with_suffix(args.out.suffix + ".tmp")
    tmp.write_text(page, encoding="utf-8")
    tmp.replace(args.out)
    print(f"wrote {shown} ({plural(len(page.splitlines()), 'line')})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
