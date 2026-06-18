from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Protocol


class SolverBuilder(Protocol):
    """What a Constraint needs from the solver-integration layer (solver.py)
    to express itself in py-slvs terms.

    Constraint subtypes call back into this rather than importing py_slvs
    directly, so this module stays a plain domain model with no solver
    library dependency - mirroring how models.py stays free of OCCT/FastAPI
    specifics.
    """

    def point2d(self, point_id: str) -> int:
        """Return the py-slvs entity handle for a Sketch Point, creating it
        (from that Point's current x/y as the initial guess) on first use."""
        ...

    def distance(self, point_a_handle: int, point_b_handle: int, value: float) -> int:
        """Add a distance constraint between two py-slvs point handles,
        returning the resulting py-slvs constraint handle."""
        ...


class Constraint(ABC):
    """Base type for anything that can live in a Sketch's constraint
    collection.

    Constraints are independent objects that reference Point ids directly -
    Line and other SketchEntity subclasses have no knowledge of constraints
    that reference their points. DistanceConstraint is the only concrete
    type today; future types (Angle, Coincident, Parallel, ...) subclass
    this without requiring changes to Sketch or solver.py.
    """

    id: str

    @property
    @abstractmethod
    def type(self) -> str:
        ...

    @abstractmethod
    def point_ids(self) -> tuple[str, ...]:
        """Every Point id this constraint references."""
        ...

    @abstractmethod
    def add_to_solver(self, builder: SolverBuilder) -> int:
        """Express this constraint via the given SolverBuilder, returning
        the resulting py-slvs constraint handle."""
        ...


@dataclass
class DistanceConstraint(Constraint):
    """Pins the distance between two Points to a fixed value."""

    id: str
    point_a_id: str
    point_b_id: str
    distance: float

    @property
    def type(self) -> str:
        return "distance"

    def point_ids(self) -> tuple[str, str]:
        return (self.point_a_id, self.point_b_id)

    def add_to_solver(self, builder: SolverBuilder) -> int:
        point_a = builder.point2d(self.point_a_id)
        point_b = builder.point2d(self.point_b_id)
        return builder.distance(point_a, point_b, self.distance)
