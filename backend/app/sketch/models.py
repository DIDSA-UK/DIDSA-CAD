import math
from dataclasses import dataclass

Point = tuple[float, float]


@dataclass
class Line:
    """A straight Sketch entity defined by two endpoints.

    Knows nothing about Profile, Extrude, or any other downstream feature
    (per the project brief's modularity principle) - it only manages its
    own endpoints and derived length.
    """

    id: str
    start: Point
    end: Point

    @property
    def length(self) -> float:
        return math.hypot(self.end[0] - self.start[0], self.end[1] - self.start[1])

    @classmethod
    def from_length_angle(cls, id: str, start: Point, length: float, angle: float) -> "Line":
        end = (start[0] + length * math.cos(angle), start[1] + length * math.sin(angle))
        return cls(id=id, start=start, end=end)

    def set_endpoints(self, start: Point, end: Point) -> None:
        self.start = start
        self.end = end

    def set_length(self, length: float) -> None:
        """Move the second endpoint to match the given length, preserving
        the first endpoint and the current direction."""
        dx = self.end[0] - self.start[0]
        dy = self.end[1] - self.start[1]
        current_length = math.hypot(dx, dy)
        if current_length == 0:
            raise ValueError("Cannot set length: line direction is undefined (zero-length line)")
        scale = length / current_length
        self.end = (self.start[0] + dx * scale, self.start[1] + dy * scale)
