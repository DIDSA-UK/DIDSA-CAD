"""Generic dependency-graph topological sort used to drive Part recompute
(A1) - deliberately has no OCCT/pythonocc-core import anywhere in this file
so it can be unit-tested without the real OCCT environment.

Recompute used to be driven by `part.features`' list order directly (a
single flat fold - see the old app.document.extrude.compute_part_solid).
A1 replaces that with an explicit dependency graph over Feature ids
(edges built by app.document.extrude.build_feature_graph) and a real
topological sort over it, so a Feature can depend on more than just "the
Feature immediately before it in the list" - e.g. an ExtrudeFeature's
`target_body_ids` (A1's multi-body identity) can name a body produced far
earlier in the history.

Kahn's algorithm is used with one deliberate choice: among all nodes
currently ready to run, the one that appears earliest in the original
input order is picked first. For every part.features history that has no
"reach back past the immediately preceding Feature" edges (i.e. every
single-body scenario that existed before A1), this reduces to exactly the
original list order, satisfying A1's regression requirement by
construction rather than by coincidence.
"""

from __future__ import annotations

from dataclasses import dataclass


class CycleError(ValueError):
    """Raised when the graph has no valid topological order - a Feature
    (directly or transitively) depends on itself. Should not be reachable
    through the client-facing API today (a Feature can only ever reference
    ids that already exist by the time it is created), but recompute stays
    defensive against malformed/hand-crafted documents rather than
    recursing forever or silently dropping nodes."""


@dataclass(frozen=True)
class GraphNode:
    """One node in a Feature dependency graph. `depends_on` holds the ids
    of every node that must be processed before this one - duplicates and
    ids that don't correspond to any node in the graph are both tolerated
    (the latter simply never contributes an edge), so callers don't need
    to pre-filter."""

    id: str
    depends_on: tuple[str, ...] = ()


def topological_order(nodes: list[GraphNode]) -> list[str]:
    """Returns node ids in an order where every id appears after all of its
    `depends_on` ids - Kahn's algorithm, with ties among simultaneously
    "ready" nodes broken by original input order (see module docstring).

    Raises CycleError if no valid order exists. Dependency ids with no
    matching node are ignored (not an error) - only edges between two
    known nodes are ever enforced."""
    index_of_id = {node.id: i for i, node in enumerate(nodes)}
    known_ids = set(index_of_id)

    dependents: dict[str, list[str]] = {node.id: [] for node in nodes}
    remaining_dep_count: dict[str, int] = {}
    for node in nodes:
        deps = {dep for dep in node.depends_on if dep in known_ids and dep != node.id}
        remaining_dep_count[node.id] = len(deps)
        for dep in deps:
            dependents[dep].append(node.id)

    ready = sorted(
        (node.id for node in nodes if remaining_dep_count[node.id] == 0),
        key=lambda node_id: index_of_id[node_id],
    )

    order: list[str] = []
    while ready:
        ready.sort(key=lambda node_id: index_of_id[node_id])
        current = ready.pop(0)
        order.append(current)
        for dependent in dependents[current]:
            remaining_dep_count[dependent] -= 1
            if remaining_dep_count[dependent] == 0:
                ready.append(dependent)

    if len(order) != len(nodes):
        raise CycleError("Feature dependency graph has a cycle - no valid recompute order exists")

    return order
