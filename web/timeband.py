"""Peak/off-peak service band parsing and resolution."""
from dataclasses import dataclass

PEAK = "peak"
OFFPEAK = "offpeak"
BANDS = (PEAK, OFFPEAK)
DEFAULT_BAND = PEAK

LABELS = {PEAK: "peak", OFFPEAK: "off-peak"}


@dataclass(frozen=True)
class ServiceBand:
    """The chosen band, and the label it is shown with."""
    value: str
    label: str


def parse_band(raw: str | None, default: str = DEFAULT_BAND) -> str:
    """Reads a band from a query string, falling back to the default."""
    if raw is None:
        return default
    value = str(raw).strip().lower()
    return value if value in BANDS else default


def resolve(raw: str | None = None) -> ServiceBand:
    """The full service-band context for a request."""
    value = parse_band(raw)
    return ServiceBand(value=value, label=LABELS[value])


def choices() -> list[tuple[str, str]]:
    """(value, label) for the picker."""
    return [(PEAK, "Peak"), (OFFPEAK, "Off-peak")]
