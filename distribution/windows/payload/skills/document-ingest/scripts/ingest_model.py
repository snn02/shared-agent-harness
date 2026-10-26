"""Neutral extraction model shared by format readers and the document store."""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Section:
    id: str
    title: str
    locator: str
    markdown: str
    method: str


@dataclass(frozen=True)
class Figure:
    id: str
    locator: str
    png: bytes
    caption: str = ""


@dataclass
class ExtractedSource:
    sections: list[Section]
    figures: list[Figure]
    total_units: int
    warnings: list[str] = field(default_factory=list)


def validate_coverage(extracted: ExtractedSource) -> list[str]:
    gaps = list(extracted.warnings)
    if extracted.total_units < 1:
        gaps.append("No source units were found")
    if len(extracted.sections) < extracted.total_units:
        gaps.append(f"Only {len(extracted.sections)} of {extracted.total_units} source units have sections")
    for section in extracted.sections:
        if not section.markdown.strip():
            gaps.append(f"Empty section: {section.locator}")
    return gaps
