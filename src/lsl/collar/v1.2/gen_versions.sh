#!/usr/bin/env bash
#
# gen_versions.sh — regenerate script_versions.html from the live tree.
#
# Scans dev/, rc/, and stable/ for every *.lsl, reads each file's REVISION
# header, and writes a self-contained dashboard comparing revisions across the
# 3-stage promotion pipeline (dev -> rc -> stable). A transition flags red when
# an upstream stage is ahead of the downstream one:
#   dev -> rc     when devRev > rcRev
#   rc  -> stable when rcRev  > stableRev
# Run after any rev bump or reconcile.
#
#   cd src/lsl/collar/v1.2 && ./gen_versions.sh
#
# No args. Overwrites script_versions.html in the same directory.

set -euo pipefail

# Resolve to this script's own directory so it works from any CWD.
cd "$(dirname "$0")"

DEV="dev"
RC="rc"
STABLE="stable"
OUT="script_versions.html"

for d in "$DEV" "$RC" "$STABLE"; do
  if [ ! -d "$d" ]; then
    echo "error: expected '$d/' beside this script" >&2
    exit 1
  fi
done

# First REVISION integer in a file's header; "-1" if file missing / no header.
rev_of() {
  local f="$1"
  if [ ! -f "$f" ]; then echo "-1"; return; fi
  local r
  r=$(grep -m1 -oiE 'REVISION:[[:space:]]*[0-9]+' "$f" | grep -oE '[0-9]+' || true)
  echo "${r:--1}"
}

# Union of basenames across all three stages, sorted, de-duped.
names=$(
  { ls "$DEV"/*.lsl "$RC"/*.lsl "$STABLE"/*.lsl 2>/dev/null || true; } \
  | xargs -n1 basename 2>/dev/null | sort -u
)

if [ -z "$names" ]; then
  echo "error: no .lsl files found in $DEV/, $RC/ or $STABLE/" >&2
  exit 1
fi

# Build the RAW JS rows: ["name", devRev, rcRev, stableRev],
ROWS=""
count=0
need_rc=0
need_stable=0
while IFS= read -r base; do
  [ -n "$base" ] || continue
  d=$(rev_of "$DEV/$base")
  r=$(rev_of "$RC/$base")
  s=$(rev_of "$STABLE/$base")
  ROWS+="  [\"$base\", $d, $r, $s],"$'\n'
  count=$((count + 1))
  if [ "$d" -gt "$r" ]; then need_rc=$((need_rc + 1)); fi
  if [ "$r" -gt "$s" ]; then need_stable=$((need_stable + 1)); fi
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
<title>D/s Collar v1.2 — dev / rc / stable revisions</title>
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
  table { border-collapse: collapse; width: 100%; max-width: 920px; background: var(--panel); border-radius: 8px; overflow: hidden; }
  th, td { padding: .5rem .8rem; text-align: left; border-bottom: 1px solid var(--line); }
  th { background: #20262f; color: var(--hdr); font-weight: 600; font-size: .8rem; text-transform: uppercase; letter-spacing: .03em; cursor: pointer; -webkit-user-select: none; user-select: none; }
  th:hover { color: #fff; }
  tr:last-child td { border-bottom: none; }
  td.rev { text-align: center; font-variant-numeric: tabular-nums; font-feature-settings: "tnum"; }
  td.name { font-family: ui-monospace, "Cascadia Code", Consolas, monospace; }
  .pill { display: inline-block; min-width: 3.4rem; text-align: center; padding: .12rem .55rem; border-radius: 999px; font-weight: 600; font-size: .78rem; }
  .pill.no  { color: #7fd6a3; background: var(--ok-bg);  border: 1px solid var(--ok); }
  .pill.yes { color: #f1a79b; background: var(--warn-bg); border: 1px solid var(--warn); }
  tr.needs td { background: var(--warn-bg); }
  footer { color: var(--dim); font-size: .78rem; margin-top: 1.5rem; max-width: 920px; }
  code { background: #0d1116; padding: .1rem .35rem; border-radius: 4px; color: #c8d2dd; }
</style>
</head>
<body>
  <h1>D/s Collar v1.2 — script revisions</h1>
  <p class="sub">3-stage pipeline compare: <code>dev</code> → <code>rc</code> → <code>stable</code> · generated __DATE__ by <code>gen_versions.sh</code></p>

  <div class="summary" id="summary"></div>

  <table id="tbl">
    <thead>
      <tr>
        <th data-k="name" data-t="s">Script</th>
        <th data-k="devRev" data-t="n">Dev</th>
        <th data-k="rcRev" data-t="n">RC</th>
        <th data-k="stableRev" data-t="n">Stable</th>
        <th data-k="toRc" data-t="b">dev → rc</th>
        <th data-k="toStable" data-t="b">rc → stable</th>
      </tr>
    </thead>
    <tbody></tbody>
  </table>

  <footer>
    Each transition flags <code>true</code> when an upstream stage's revision is greater than the downstream stage's —
    i.e. changes not yet promoted: <code>dev → rc</code> when dev rev &gt; rc rev, <code>rc → stable</code> when rc rev &gt; stable rev.
    A <code>—</code> means the script is absent from that stage. Regenerate with <code>./gen_versions.sh</code> after a rev bump or reconcile.
  </footer>

<script>
// [name, devRev, rcRev, stableRev]  (-1 = absent in that stage). Generated — do not hand-edit.
const RAW = [
EOF_HEAD

printf '%s\n' "$ROWS" >> "$OUT"

cat >> "$OUT" <<'EOF_TAIL'
];

const rows = RAW.map(([name, devRev, rcRev, stableRev]) => ({
  name, devRev, rcRev, stableRev,
  toRc:     devRev > rcRev,      // dev ahead of rc      → promote dev → rc
  toStable: rcRev  > stableRev,  // rc  ahead of stable  → promote rc → stable
}));

const fmtRev = r => r < 0 ? "—" : String(r);

function render(data) {
  const tb = document.querySelector("#tbl tbody");
  tb.innerHTML = data.map(r => `
    <tr class="${(r.toRc || r.toStable) ? "needs" : ""}">
      <td class="name">${r.name}</td>
      <td class="rev">${fmtRev(r.devRev)}</td>
      <td class="rev">${fmtRev(r.rcRev)}</td>
      <td class="rev">${fmtRev(r.stableRev)}</td>
      <td class="rev"><span class="pill ${r.toRc ? "yes" : "no"}">${r.toRc ? "true" : "false"}</span></td>
      <td class="rev"><span class="pill ${r.toStable ? "yes" : "no"}">${r.toStable ? "true" : "false"}</span></td>
    </tr>`).join("");
}

const needRc = rows.filter(r => r.toRc).length;
const needStable = rows.filter(r => r.toStable).length;
document.querySelector("#summary").innerHTML =
  (needRc === 0 && needStable === 0)
    ? `<b>${rows.length}</b> scripts · <b style="color:#7fd6a3">all in sync</b> — nothing to promote.`
    : `<b>${rows.length}</b> scripts · <b style="color:#f1a79b">${needRc}</b> need <code>dev → rc</code> · <b style="color:#f1a79b">${needStable}</b> need <code>rc → stable</code>.`;

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

echo "wrote $OUT — $count scripts, $need_rc need dev->rc, $need_stable need rc->stable (as of $DATE)"
