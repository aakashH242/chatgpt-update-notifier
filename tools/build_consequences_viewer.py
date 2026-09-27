#!/usr/bin/env python3
"""Build an offline, source-linked view of the active Consequences graph."""

import hashlib
import json
import sqlite3
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INDEX = ROOT / ".consequences/index.sqlite"
TEMPLATE = Path(__file__).with_name("consequences_viewer.html")
OUTPUT = ROOT / ".consequences/viewer.html"
VIEW_FILES = {"chatgpt-update-notifier", "install.sh"}
CONTROL_NAMES = {
    "if_statement", "case_statement", "for_statement", "while_statement",
    "c_style_loop", "then", "else", "do", "items",
}
EFFECT_KINDS = {"reads_file", "writes_file", "executes", "invokes", "sources"}
# ponytail: omit routine shell builtins; include them if they become useful to trace.
ROUTINE_COMMANDS = {
    "printf", "set", "local", "read", "return", "true", "false", "exit",
    "wait", "shift", "break", "continue", "declare", "unset", "mapfile",
}


def active_index(connection):
    row = connection.execute(
        "SELECT id, root, created_at FROM index_versions WHERE active = 1"
    ).fetchone()
    if row is None or Path(row["root"]).resolve() != ROOT:
        raise RuntimeError("No active Consequences index for this repository")
    return row


def indexed_files(connection, index_id):
    rows = connection.execute(
        "SELECT path, sha256 FROM index_files WHERE index_id = ?", (index_id,)
    ).fetchall()
    result = {}
    for row in rows:
        if row["path"] not in VIEW_FILES:
            continue
        path = ROOT / row["path"]
        source = path.read_bytes()
        if hashlib.sha256(source).hexdigest() != row["sha256"]:
            raise RuntimeError(f"Stale graph for {row['path']}; refresh .consequences first")
        result[row["path"]] = source.decode("utf-8").splitlines()
    return result


def graph_data(connection, index):
    index_id = index["id"]
    files = indexed_files(connection, index_id)
    nodes = {}
    functions = {}
    for path in files:
        if path.endswith(".sh") or path == "chatgpt-update-notifier":
            node_id = f"file:{path}"
            nodes[node_id] = dict(id=node_id, kind="entry", name=path,
                                  file=path, start=1, end=len(files[path]), scope=node_id)

    symbols = connection.execute(
        "SELECT id, file_path, kind, name, parent_id, start_line, end_line, "
        "start_column, end_column FROM index_symbols WHERE index_id = ? "
        "AND kind IN ('function', 'shell_syntax')", (index_id,)
    ).fetchall()
    symbols = [row for row in symbols if row["file_path"] in files]
    syntax = {row["id"]: row for row in symbols if row["kind"] == "shell_syntax"}
    function_by_span = {}
    for row in symbols:
        if row["kind"] != "function":
            continue
        nodes[row["id"]] = dict(id=row["id"], kind="function", name=row["name"],
                                file=row["file_path"], start=row["start_line"],
                                end=row["end_line"], scope=row["id"])
        function_by_span[row["file_path"], row["start_line"], row["end_line"]] = row["id"]
        functions[row["id"]] = row

    controls = {}
    for row in syntax.values():
        if row["name"] not in CONTROL_NAMES:
            continue
        parent = syntax.get(row["parent_id"])
        if row["name"] == "items" and (parent is None or parent["name"] != "case_statement"):
            continue
        if row["name"] in {"then", "else"} and (parent is None or parent["name"] not in {"if_statement", "else"}):
            continue
        if row["name"] == "do" and (parent is None or parent["name"] not in {"for_statement", "while_statement", "c_style_loop"}):
            continue
        controls[row["id"]] = row

    def container(syntax_id):
        while syntax_id in syntax:
            row = syntax[syntax_id]
            if syntax_id in controls:
                return syntax_id
            if row["name"] == "function_definition":
                return function_by_span.get(
                    (row["file_path"], row["start_line"], row["end_line"]),
                    f"file:{row['file_path']}",
                )
            syntax_id = row["parent_id"]
        return None

    links = []
    pending = dict(controls)
    while pending:
        added = False
        for control_id, row in list(pending.items()):
            parent = container(row["parent_id"])
            if parent not in nodes:
                continue
            line = files[row["file_path"]][row["start_line"] - 1].strip()
            label = line.split(")", 1)[0] if row["name"] == "items" else line
            if row["name"] in {"then", "else", "do"}:
                label = row["name"]
            nodes[control_id] = dict(id=control_id, kind="branch", name=label[:64],
                                     file=row["file_path"], start=row["start_line"],
                                     end=row["end_line"], scope=None)
            links.append(dict(source=parent, target=control_id, kind="branch",
                              line=row["start_line"]))
            del pending[control_id]
            added = True
        if not added:
            break

    for node in nodes.values():
        if node["kind"] != "branch":
            continue
        owner = container(syntax[node["id"]]["parent_id"])
        while owner in controls:
            owner = container(syntax[owner]["parent_id"])
        node["scope"] = owner

    call_sites = {}
    for row in syntax.values():
        if row["name"] == "call_expr":
            call_sites.setdefault((row["file_path"], row["start_line"], row["start_column"]), row["id"])

    edges = connection.execute(
        "SELECT source_id, target_id, target_name, kind, resolution, start_line, "
        "start_column FROM index_edges WHERE index_id = ?", (index_id,)
    ).fetchall()
    for edge in edges:
        if edge["kind"] != "calls" or edge["resolution"] != "resolved":
            continue
        if edge["target_id"] not in nodes or edge["source_id"] not in nodes:
            continue
        file_path = nodes[edge["source_id"]]["file"]
        site = call_sites.get((file_path, edge["start_line"], edge["start_column"]))
        parent = container(site) if site else None
        if parent not in nodes:
            parent = edge["source_id"]
        links.append(dict(source=parent, target=edge["target_id"], kind="call",
                          line=edge["start_line"]))

    effects = []
    for edge in edges:
        if edge["kind"] not in EFFECT_KINDS or edge["source_id"] not in nodes:
            continue
        target = edge["target_name"] or edge["target_id"] or "unresolved"
        if target == "/dev/null" or (edge["kind"] == "invokes" and target in ROUTINE_COMMANDS):
            continue
        effects.append(dict(owner=edge["source_id"], kind=edge["kind"],
                            target=target, line=edge["start_line"]))

    roots = [node_id for node_id, node in nodes.items() if node["kind"] == "entry"]
    if "file:chatgpt-update-notifier" not in roots:
        raise RuntimeError("Notifier entrypoint missing from graph")
    missing_link = next((link for link in links if link["source"] not in nodes or
                         link["target"] not in nodes), None)
    if missing_link:
        raise RuntimeError(f"Graph contains a link to a missing node: {missing_link}")
    if not any(link["source"] == "file:chatgpt-update-notifier" and
               nodes[link["target"]]["name"] == "main" for link in links):
        raise RuntimeError("Notifier entrypoint is not linked to main")
    if not any(node["kind"] == "branch" for node in nodes.values()):
        raise RuntimeError("No control branches found in the deep graph")
    return dict(index=index_id, indexed_at=index["created_at"], files=files,
                nodes=list(nodes.values()), links=links, effects=effects,
                roots=sorted(roots, key=lambda root: ("tests/" in root, root)))


def main():
    if not INDEX.exists():
        raise SystemExit("Missing .consequences/index.sqlite; build the Consequences graph first")
    with sqlite3.connect(f"{INDEX.as_uri()}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        data = graph_data(connection, active_index(connection))
    payload = json.dumps(data, separators=(",", ":")).replace("<", "\\u003c")
    OUTPUT.write_text(TEMPLATE.read_text().replace("__GRAPH_DATA__", payload), encoding="utf-8")
    print(f"Wrote {OUTPUT} ({len(data['nodes'])} nodes, {len(data['links'])} links)")


if __name__ == "__main__":
    main()
