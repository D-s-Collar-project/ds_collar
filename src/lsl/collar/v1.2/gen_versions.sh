#!/usr/bin/env bash
#
# gen_versions.sh — regenerate script_versions.html from the live tree.
#
# Scans dev/ and stable/ for every *.lsl, reads each file's REVISION header,
# and writes a self-contained dashboard comparing dev vs stable revisions
# (Update needed = dev rev > stable rev). Run after any rev bump or reconcile.
#
#   cd src/lsl/collar/v1.2 && ./gen_versions.sh
#
# No args. Overwrites script_versions.html in the same directory.

set -euo pipefail

# Resolve to this script's own directory so it works from any CWD.
cd "$(dirname "$0")"

DEV="dev"
STABLE="stable"
OUT="script_versions.html"

if [ ! -d "$DEV" ] || [ ! -d "$STABLE" ]; then
  echo "error: expected '$DEV/' and '$STABLE/' beside this script" >&2
  exit 1
fi

# First REVISION integer in a file's header; "-1" if file missing / no header.
rev_of() {
  local f="$1"
  if [ ! -f "$f" ]; then echo "-1"; return; fi
  local r
  r=$(grep -m1 -oiE 'REVISION:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' || true)
  echo "${r:--1}"
}

# Union of basenames across both stages, sorted, de-duped.
names=$(
  { ls "$DEV"/*.lsl "$STABLE"/*.lsl 2>/dev/null || true; } \
  | xargs -n1 basename 2>/dev/null | sort -u
)

if [ -z "$names" ]; then
  echo "error: no .lsl files found in $DEV/ or $STABLE/" >&2
  exit 1
fi

# Build the RAW JS rows: ["name", devRev, stableRev],
ROWS=""
count=0
need=0
while IFS= read -r base; do
  [ -n "$base" ] || continue
  d=$(rev_of "$DEV/$base")
  s=$(rev_of "$STABLE/$base")
  ROWS+="  [\"$base\", $d, $s],"$'\n'
  count=$((count + 1))
  if [ "$d" -gt "$s" ]; then need=$((need + 1)); fi
done <<< "$names"

# Strip the trailing newline from ROWS for tidy output.
ROWS="${ROWS%$'\n'}"

DATE=$(date +%F)

# ---- write the page: head (literal) + RAW rows + tail (literal) ----
cat > "$OUT" <<'EOF_HEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>D/s Collar v1.2 — dev vs stable revisions</title>
<style>
  :root {
    --bg: #11151a; --panel: #1a2029; --line: #2b333f;
    --txt: #d7dee7; --dim: #8b97a6; --hdr: #e8edf3;
    --ok: #2e7d4f; --ok-bg: #16271d; --warn: #c8412e; --warn-bg: #2a1614;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 2rem; background: var(--bg); color: var(--txt);
    font: 14px/1.5 -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif;
  }
  h1 { color: var(--hdr); font-size: 1.35rem; margin: 0 0 .25rem; }
  .sub { color: var(--dim); margin: 0 0 1.25rem; font-size: .85rem; }
  .summary {
    display: inline-block; padding: .5rem .9rem; border-radius: 6px;
    background: var(--panel); border: 1px solid var(--line); margin-bottom: 1.25rem;
  }
  .summary b { color: var(--hdr); }
  table { border-collapse: collapse; width: 100%; max-width: 880px; background: var(--panel); border-radius: 8px; overflow: hidden; }
  th, td { padding: .5rem .8rem; text-align: left; border-bottom: 1px solid var(--line); }
  th { background: #20262f; color: var(--hdr); font-weight: 600; font-size: .8rem; text-transform: uppercase; letter-spacing: .03em; cursor: pointer; user-select: none; }
  th:hover { color: #fff; }
  tr:last-child td { border-bottom: none; }
  td.rev { text-align: center; font-variant-numeric: tabular-nums; font-feature-settings: "tnum"; }
  td.name { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; }
  .pill { display: inline-block; min-width: 3.4rem; text-align: center; padding: .12rem .55rem; border-radius: 999px; font-weight: 600; font-size: .78rem; }
  .pill.no  { color: #7fd6a3; background: var(--ok-bg);  border: 1px solid var(--ok); }
  .pill.yes { color: #f1a79b; background: var(--warn-bg); border: 1px solid var(--warn); }
  tr.needs td { background: var(--warn-bg); }
  footer { color: var(--dim); font-size: .78rem; margin-top: 1.5rem; max-width: 880px; }
  code { background: #0d1116; padding: .1rem .35rem; border-radius: 4px; color: #c8d2dd; }
</style>
</head>
<body>
  <h1>D/s Collar v1.2 — script revisions</h1>
  <p class="sub">Pipeline stage compare: <code>src/lsl/collar/v1.2/dev</code> vs <code>src/lsl/collar/v1.2/stable</code> · generated __DATE__ by <code>gen_versions.sh</code></p>

  <div class="summary" id="summary"></div>

  <table id="tbl">
    <thead>
      <tr>
        <th data-k="stable" data-t="s">Stable script</th>
        <th data-k="dev" data-t="s">Dev script</th>
        <th data-k="devRev" data-t="n">Dev rev</th>
        <th data-k="stableRev" data-t="n">Stable rev</th>
        <th data-k="need" data-t="b">Update needed</th>
      </tr>
    </thead>
    <tbody></tbody>
  </table>

  <footer>
    <strong>Update needed</strong> is <code>true</code> when the dev revision is greater than the stable revision —
    i.e. dev has changes not yet promoted downstream. A row also flags red if a script exists in one stage but not the
    other (shown as <code>—</code>). Regenerate with <code>./gen_versions.sh</code> after a rev bump or reconcile.
  </footer>

<script>
// [name, devRev, stableRev]  (-1 = absent in that stage). Generated — do not hand-edit.
const RAW = [
EOF_HEAD

printf '%s\n' "$ROWS" >> "$OUT"

cat >> "$OUT" <<'EOF_TAIL'
];

const rows = RAW.map(([name, devRev, stableRev]) => ({
  stable: stableRev < 0 ? "—" : name,
  dev:    devRev    < 0 ? "—" : name,
  devRev, stableRev,
  need:   devRev > stableRev   // dev ahead of stable → promotion needed
}));

const fmtRev = r => r < 0 ? "—" : String(r);

function render(data) {
  const tb = document.querySelector("#tbl tbody");
  tb.innerHTML = data.map(r => `
    <tr class="${r.need ? "needs" : ""}">
      <td class="name">${r.stable}</td>
      <td class="name">${r.dev}</td>
      <td class="rev">${fmtRev(r.devRev)}</td>
      <td class="rev">${fmtRev(r.stableRev)}</td>
      <td class="rev"><span class="pill ${r.need ? "yes" : "no"}">${r.need ? "true" : "false"}</span></td>
    </tr>`).join("");
}

const need = rows.filter(r => r.need).length;
document.querySelector("#summary").innerHTML =
  need === 0
    ? `<b>${rows.length}</b> scripts · <b style="color:#7fd6a3">all in sync</b> — no promotion needed.`
    : `<b>${rows.length}</b> scripts · <b style="color:#f1a79b">${need} need promotion</b> (dev ahead of stable).`;

// Click a header to sort; default keeps source (alpha) order.
let dir = 1, lastK = null;
document.querySelectorAll("th").forEach(th => th.addEventListener("click", () => {
  const k = th.dataset.k, t = th.dataset.t;
  dir = (lastK === k) ? -dir : 1; lastK = k;
  const sorted = [...rows].sort((a, b) => {
    let av = a[k], bv = b[k];
    if (t === "n") return (av - bv) * dir;
    if (t === "b") return ((av ? 1 : 0) - (bv ? 1 : 0)) * dir;
    return String(av).localeCompare(String(bv)) * dir;
  });
  render(sorted);
}));

render(rows);
</script>
</body>
</html>
EOF_TAIL

# Single-line token swap (date is YYYY-MM-DD, sed-safe).
sed -i "s/__DATE__/$DATE/" "$OUT"

echo "wrote $OUT — $count scripts, $need need promotion (as of $DATE)"
