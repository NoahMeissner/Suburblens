# @Noah Meissner 9.10.2026
"""The address report website.

Three screens from the design handoff (design/DESIGN.md §5):

    /                 start - type an address, plus Sydney-wide highlights
    /report?address=  the A4 report page
    /map?address=     the same findings as toggleable map layers

plus a fourth, not in the handoff:

    /rankings         top 10 Sydney-wide, for each of the start page's highlights

and the JSON the browser needs: /api/suggest for autocomplete and
/api/layers/<name> for the map.

Everything on screen comes from web.report.get_report() or web.stats, so the
templates never query the database themselves and the pages can never disagree.

Every request is logged next to the SQL it triggered (web.db.LoggingCursor
does the SQL side): run with `python -m web.app` and a terminal shows each
page's request, the queries it ran, and what the database handed back.

Run it from the repo root, with the databases up (./start.sh):
    python -m web.app
    python -m web.app --port 8000 --debug
"""
import argparse
import dataclasses
import logging
import time

from flask import Flask, g, jsonify, redirect, render_template, request, url_for
from rich.logging import RichHandler
from rich.rule import Rule

from web import layers, stats
from web.geocode import suggest
from web.log import console
from web.report import SCHOOL_LIST_LIMIT, WALK_MINUTES, get_report
from web.timeband import choices as band_choices

DATA_SOURCES = (
    "NSW Planning Portal · Valuer General property sales · "
    "NSW DoE school locations · TfNSW bus GTFS · NSW rental bond board"
)
DEFAULT_PORT = 5000

app = Flask(__name__)
app.config["DATA_SOURCES"] = DATA_SOURCES


@app.before_request
def _log_request_start() -> None:
    """Opens this request's block: a full-width rule naming it, so everything
    printed underneath (the SQL in web.db.LoggingCursor) is visibly nested
    inside one request rather than running together with the next."""
    g.started_at = time.perf_counter()
    query = f"?{request.query_string.decode()}" if request.query_string else ""
    console.print()
    console.print(Rule(f"[bold green]{request.method} {request.path}{query}[/]",
                        align="left"))


@app.after_request
def _log_request_end(response):
    """Closes this request's block with a second rule - the response status
    and timing - so it reads as a clear stop before the next request opens."""
    elapsed_ms = (time.perf_counter() - g.started_at) * 1000
    color = "green" if response.status_code < 400 else "red"
    console.print(Rule(f"[{color}]{response.status}[/]  [dim]{elapsed_ms:.1f} ms[/]",
                        align="left"))
    return response


@app.context_processor
def inject_globals() -> dict:
    """Values every template needs (product name, footer sources)."""
    return {
        "product_name": "Suburblens",
        "data_sources": DATA_SOURCES,
        "walk_minutes": WALK_MINUTES,
        "school_list_limit": SCHOOL_LIST_LIMIT,
        "band_choices": band_choices(),
    }


@app.route("/")
def start():
    """The start screen, plus the five Sydney-wide highlights."""
    return render_template(
        "start.html",
        query=request.args.get("address", ""),
        overview=stats.overview(),
    )


@app.route("/rankings")
def rankings_page():
    """Top 10 Sydney-wide, for each of the start page's highlights."""
    return render_template("rankings.html", overview=stats.overview())


@app.route("/api/suggest")
def api_suggest():
    """Autocomplete rows for the address box."""
    rows = suggest(request.args.get("q", ""))
    return jsonify([dataclasses.asdict(row) for row in rows])


@app.route("/report")
def report_page():
    """The A4 report page for one address."""
    query = request.args.get("address", "").strip()
    if not query:
        return redirect(url_for("start"))

    report = get_report(query, request.args.get("at"))
    if report is None:
        return render_template("not_found.html", query=query), 404
    return render_template("report.html", report=report, view="report")


@app.route("/compare")
def compare_page():
    """Side-by-side report for two addresses."""
    query_a = request.args.get("a", "").strip()
    query_b = request.args.get("b", "").strip()
    at = request.args.get("at")

    if not query_a:
        return redirect(url_for("start"))

    report_a = get_report(query_a, at)
    if report_a is None:
        return render_template("not_found.html", query=query_a), 404

    report_b = get_report(query_b, at) if query_b else None

    return render_template(
        "compare.html",
        report_a=report_a, report_b=report_b, query_b=query_b, view="compare",
    )


@app.route("/map")
def map_page():
    """The interactive map for one address."""
    query = request.args.get("address", "").strip()
    if not query:
        return redirect(url_for("start"))

    report = get_report(query, request.args.get("at"))
    if report is None:
        return render_template("not_found.html", query=query), 404
    return render_template("map.html", report=report, view="map")


@app.route("/api/report")
def api_report():
    """The same report as JSON - useful for debugging and for reuse."""
    report = get_report(request.args.get("address", ""), request.args.get("at"))
    if report is None:
        return jsonify({"error": "address not found"}), 404
    return jsonify(dataclasses.asdict(report))


@app.route("/api/layers/<name>")
def api_layer(name: str):
    """GeoJSON for one map layer."""
    builder = layers.LAYERS.get(name)
    if builder is None:
        return jsonify({"error": f"unknown layer: {name}"}), 404

    report = get_report(request.args.get("address", ""), request.args.get("at"))
    if report is None:
        return jsonify({"error": "address not found"}), 404
    return jsonify(builder(report))


def main() -> None:
    """Parses the command line and starts the development server."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO, format="%(message)s", datefmt="[%X]",
        handlers=[RichHandler(markup=True, show_path=False, rich_tracebacks=True)],
    )
    # Replaced by the before/after_request hooks above, which also log the
    # query string and timing - without this, every request would print twice.
    logging.getLogger("werkzeug").setLevel(logging.WARNING)

    print(f"Address report site on http://{args.host}:{args.port}")
    app.run(host=args.host, port=args.port, debug=args.debug)


if __name__ == "__main__":
    main()
