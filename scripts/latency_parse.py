#!/usr/bin/env python3
import argparse, os, re, sys, csv, json
from datetime import datetime

REC_RE = re.compile(r"topic=(\S+).*?seq=(\d+).*?latency_ms=([-]?\d+).*?pub_ts_ms=(\d+).*?recv_ts_ms=(\d+)")
# Only count true publish lines (must contain [publish] tag)
PUB_RE = re.compile(r"\[publish\].*?topic=(\S+).*?seq=(\d+).*?pub_ts_ms=(\d+)")

def parse_recvs(path):
    out = []
    try:
        with open(path, 'r', errors='ignore') as f:
            for line in f:
                m = REC_RE.search(line)
                if not m:
                    continue
                topic = m.group(1)
                seq = int(m.group(2))
                lat = int(m.group(3))
                pub_ts = int(m.group(4))
                recv_ts = int(m.group(5))
                out.append((topic, seq, lat, pub_ts, recv_ts))
    except FileNotFoundError:
        pass
    return out

def parse_pubs(path):
    out = []
    try:
        with open(path, 'r', errors='ignore') as f:
            for line in f:
                m = PUB_RE.search(line)
                if not m:
                    continue
                topic = m.group(1)
                seq = int(m.group(2))
                pub_ts = int(m.group(3))
                out.append((topic, seq, pub_ts))
    except FileNotFoundError:
        pass
    return out

def write_csv(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['seq','latency_ms','pub_ts_ms','recv_ts_ms'])
        for r in rows:
            w.writerow([r[0], r[1], r[2], r[3]])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--java', required=False)
    ap.add_argument('--go', required=False)
    ap.add_argument('--outdir', required=True)
    ap.add_argument('--html', action='store_true', help='Emit index.html summary page')
    ap.add_argument('--title', default='MQTT Latency Report')
    ap.add_argument('--meta', default='', help='Freeform metadata string to include in summary')
    ap.add_argument('--client-config', default='configs/client.yaml')
    ap.add_argument('--backend-config', default='configs/backend.yaml')
    args = ap.parse_args()

    recvs = []
    pubs = []
    if args.java:
        recvs += parse_recvs(args.java)
        pubs  += parse_pubs(args.java)
    if args.go:
        recvs += parse_recvs(args.go)
        pubs  += parse_pubs(args.go)

    # Group by topic
    by_topic_recv = {}
    for topic, seq, lat, pub_ts, recv_ts in recvs:
        by_topic_recv.setdefault(topic, []).append((seq, lat, pub_ts, recv_ts))
    by_topic_pub = {}
    for topic, seq, pub_ts in pubs:
        by_topic_pub.setdefault(topic, []).append((seq, pub_ts))

    # Map topics to filenames
    topic_map = {
        '/driver/offer': 'offer',
        '/driver/ride': 'ride',
        '/driver/location': 'location',
    }
    for topic in set(list(by_topic_pub.keys()) + list(by_topic_recv.keys())):
        rows = by_topic_recv.get(topic, [])
        pub_rows = by_topic_pub.get(topic, [])
        # Deduplicate publishes by seq (take earliest pub_ts)
        if pub_rows:
            uniq = {}
            for seq, ts in pub_rows:
                if (seq not in uniq) or ts < uniq[seq]:
                    uniq[seq] = ts
            pub_rows = [(s, uniq[s]) for s in sorted(uniq.keys())]
        key = topic_map.get(topic)
        if not key:
            continue
        rows.sort(key=lambda r: r[0])
        pub_rows.sort(key=lambda r: r[0])
        csv_path = os.path.join(args.outdir, f'latency_{key}.csv')
        with open(csv_path, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['seq','latency_ms','pub_ts_ms','recv_ts_ms'])
            for seq, lat, pub_ts, recv_ts in rows:
                w.writerow([seq, lat, pub_ts, recv_ts])

        # Missing (published but no receive)
        recv_set = set([seq for (seq, _, _, _) in rows])
        missing = [(seq, pub_ts) for (seq, pub_ts) in pub_rows if seq not in recv_set]
        if missing:
            miss_path = os.path.join(args.outdir, f'latency_{key}_missing.csv')
            with open(miss_path, 'w', newline='') as f:
                w = csv.writer(f)
                w.writerow(['seq','pub_ts_ms'])
                for seq, pub_ts in missing:
                    w.writerow([seq, pub_ts])

        # Rates per second: published vs received, and delivered ratio per pub-second
        per_sec_pub = {}
        for seq, pub_ts in pub_rows:
            s = pub_ts // 1000
            per_sec_pub[s] = per_sec_pub.get(s, 0) + 1
        per_sec_recv = {}
        for seq, lat, pub_ts, recv_ts in rows:
            s = recv_ts // 1000
            per_sec_recv[s] = per_sec_recv.get(s, 0) + 1
        # delivered ratio by pub second
        recv_set_all = set([seq for (seq, _, _, _) in rows])
        per_sec_delivered = {}
        for seq, pub_ts in pub_rows:
            s = pub_ts // 1000
            d = per_sec_delivered.get(s, [0,0])
            d[1] += 1  # published
            if seq in recv_set_all:
                d[0] += 1  # delivered
            per_sec_delivered[s] = d
        # Write combined rate CSV
        secs = sorted(set(list(per_sec_pub.keys()) + list(per_sec_recv.keys())))
        rate_path = os.path.join(args.outdir, f'rate_{key}.csv')
        with open(rate_path, 'w', newline='') as f:
            w = csv.writer(f)
            w.writerow(['second_unix','published','received','delivered_ratio'])
            for s in secs:
                pubc = per_sec_pub.get(s, 0)
                recvc = per_sec_recv.get(s, 0)
                dlv = per_sec_delivered.get(s, [0,0])
                ratio = (dlv[0] / dlv[1]) if dlv[1] > 0 else ''
                w.writerow([s, pubc, recvc, ratio])

    # Minimal YAML parsing utilities (extract only relevant keys)
    def parse_yaml_minimal(path):
        cfg = {'mqtt': {}, 'qos': {}, 'payload_bytes': {}, 'publish': {}}
        try:
            with open(path, 'r', errors='ignore') as f:
                sect = None
                for line in f:
                    if line.strip().startswith('#') or not line.strip():
                        continue
                    if re.match(r'^\s{0,2}mqtt:\s*$', line):
                        sect = 'mqtt'; continue
                    if re.match(r'^\s{0,2}qos:\s*$', line):
                        sect = 'qos'; continue
                    if re.match(r'^\s{0,2}payload_bytes:\s*$', line):
                        sect = 'payload_bytes'; continue
                    if re.match(r'^\s{0,2}publish:\s*$', line):
                        sect = 'publish'; continue
                    m = re.match(r'^\s{2,}([A-Za-z0-9_]+):\s*(.*)\s*$', line)
                    if m and sect:
                        k = m.group(1); v = m.group(2).split('#')[0].strip()
                        if v.startswith('"') and v.endswith('"'):
                            v = v[1:-1]
                        if v.lower() in ('true','false'):
                            v = (v.lower()=='true')
                        else:
                            try:
                                v = int(v)
                            except Exception:
                                pass
                        cfg[sect][k] = v
                    else:
                        m2 = re.match(r'^([A-Za-z0-9_]+):\s*(.*)\s*$', line)
                        if m2:
                            sect = None
            return cfg
        except Exception:
            return cfg

    client_cfg = parse_yaml_minimal(args.client_config) if args.client_config else {}
    backend_cfg = parse_yaml_minimal(args.backend_config) if args.backend_config else {}

    # Compute summary stats per topic
    def compute_stats(topic, key):
        rows = by_topic_recv.get(topic, [])
        pubs = by_topic_pub.get(topic, [])
        delivered = set([seq for (seq, _, _, _) in rows])
        latencies = [lat for (_, lat, _, _) in rows if lat >= 0]
        latencies.sort()
        def q(p):
            if not latencies:
                return None
            k = (len(latencies)-1) * (p/100.0)
            f = int(k)
            c = min(f+1, len(latencies)-1)
            if f == c:
                return float(latencies[f])
            d0 = latencies[f] * (c - k)
            d1 = latencies[c] * (k - f)
            return float(d0 + d1)
        delivered_count = len(delivered)
        published_count = len(pubs)
        received_count = len(rows)
        missing_count = max(0, published_count - delivered_count)
        delivered_ratio = (delivered_count/published_count) if published_count > 0 else None
        min_lat = float(latencies[0]) if latencies else None
        max_lat = float(latencies[-1]) if latencies else None
        mean_lat = (sum(latencies)/len(latencies)) if latencies else None
        tmin = min([ts for (_, ts) in pubs], default=None)
        tmax_recv = max([rt for (_, _, _, rt) in rows], default=None)
        return {
            'topic': topic,
            'alias': key,
            'published': published_count,
            'received': received_count,
            'delivered': delivered_count,
            'missing': missing_count,
            'delivered_ratio': delivered_ratio,
            'latency_ms': {
                'min': min_lat, 'max': max_lat, 'mean': mean_lat,
                'p50': q(50), 'p95': q(95), 'p99': q(99)
            },
            'time': {'first_pub_ts_ms': tmin, 'last_recv_ts_ms': tmax_recv}
        }

    # Extract capture window from meta if present
    since_ts = None; until_ts = None
    m1 = re.search(r"since=(\d+)", args.meta or '')
    m2 = re.search(r"until=(\d+)", args.meta or '')
    if m1: since_ts = int(m1.group(1))
    if m2: until_ts = int(m2.group(1))

    now = datetime.now()
    summary = {
        'title': args.title,
        'meta': args.meta,
        'window': {
            'since_unix': since_ts,
            'until_unix': until_ts,
            'since_human': (datetime.fromtimestamp(since_ts).strftime('%Y-%m-%d %H:%M:%S') if since_ts else None),
            'until_human': (datetime.fromtimestamp(until_ts).strftime('%Y-%m-%d %H:%M:%S') if until_ts else None),
        },
        'generated': {
            'human': now.strftime('%Y-%m-%d %H:%M:%S'),
            'unix': int(now.timestamp()),
        },
        'topics': {}
    }
    for t, key in topic_map.items():
        if t in set(list(by_topic_pub.keys()) + list(by_topic_recv.keys())):
            st = compute_stats(t, key)
            # Attach publisher config snapshot
            if key == 'location':
                qos = (client_cfg.get('qos') or {}).get('location')
                payload = (client_cfg.get('payload_bytes') or {}).get('location')
                m = client_cfg.get('mqtt') or {}
                pub_every = (client_cfg.get('publish') or {}).get('location_every_ms')
                pub = {'publisher':'java-client','client_id': m.get('client_id'), 'host': m.get('host'), 'port': m.get('port'), 'keepalive_secs': m.get('keepalive_secs'), 'clean_session': m.get('clean_session'), 'qos': qos, 'payload_bytes': payload, 'publish_interval_ms': pub_every, 'separate_pubsub_connections': m.get('separate_pubsub_connections')}
            else:
                qos = (backend_cfg.get('qos') or {}).get(key)
                payload = (backend_cfg.get('payload_bytes') or {}).get(key)
                m = backend_cfg.get('mqtt') or {}
                pub_map = {'offer':'offer_every_ms','ride':'ride_every_ms'}
                pub_every = (backend_cfg.get('publish') or {}).get(pub_map.get(key,''))
                pub = {'publisher':'go-backend','client_id': m.get('client_id'), 'host': m.get('host'), 'port': m.get('port'), 'keepalive_secs': m.get('keepalive_secs'), 'clean_session': m.get('clean_session'), 'qos': qos, 'payload_bytes': payload, 'publish_interval_ms': pub_every}
            st['config'] = pub
            summary['topics'][key] = st

    with open(os.path.join(args.outdir, 'summary.json'), 'w') as f:
        json.dump(summary, f, indent=2)

    # Human-friendly summary
    with open(os.path.join(args.outdir, 'summary.txt'), 'w') as f:
        f.write(f"{summary['title']}\n")
        if summary['meta']:
            f.write(f"meta: {summary['meta']}\n")
        for key, st in summary['topics'].items():
            f.write(f"\n[{key}] published={st['published']} received={st['received']} delivered={st['delivered']} missing={st['missing']} delivered_ratio={st['delivered_ratio']}\n")
            lat = st['latency_ms']
            f.write(f"latency_ms: min={lat['min']} mean={lat['mean']} p50={lat['p50']} p95={lat['p95']} p99={lat['p99']} max={lat['max']}\n")

    # Simple HTML page with images (PNG) if present
    if args.html:
        html = [
            '<!DOCTYPE html>', '<html><head><meta charset="utf-8">',
            f'<title>{summary["title"]}</title>',
            '<style>',
            ':root{--bg:#0b0f14;--panel:#121821;--muted:#9fb0c5;--text:#e6eef7;--accent:#5eb1ff;--ok:#2ecc71;--warn:#f5b041;--bad:#e74c3c;}',
            'body{margin:24px;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,Segoe UI,Roboto,Arial,sans-serif;}',
            'h1{margin:0 0 4px 0;font-size:22px;font-weight:600;}',
            '.meta{color:var(--muted);margin:0 0 20px 0;}',
            '.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:16px;}',
            '.card{background:var(--panel);border:1px solid rgba(255,255,255,0.06);box-shadow:0 2px 8px rgba(0,0,0,0.25);border-radius:10px;overflow:hidden;}',
            '.card h2{margin:0;padding:12px 14px;font-size:16px;font-weight:600;border-bottom:1px solid rgba(255,255,255,0.06);}',
            '.body{padding:12px 14px;}',
            'table{width:100%;border-collapse:collapse;margin:6px 0 12px 0;}',
            'th,td{padding:8px 10px;border-bottom:1px solid rgba(255,255,255,0.06);text-align:left;}',
            'th{color:var(--muted);font-weight:600;background:rgba(255,255,255,0.02);}',
            '.chips{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0;}',
            '.chip{background:rgba(255,255,255,0.06);padding:6px 10px;border-radius:999px;border:1px solid rgba(255,255,255,0.08);}',
            '.charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(380px,1fr));gap:12px;margin-top:8px;}',
            'figure{margin:0;}',
            'figcaption{color:var(--muted);font-size:12px;margin:6px 0 0 0;}',
            'img{width:100%;height:auto;border:1px solid rgba(255,255,255,0.08);border-radius:8px;background:#0e131a;}',
            'img.chart{cursor:zoom-in;}',
            '.note{color:var(--muted);font-size:13px;margin-top:6px;}',
            '.details{margin-top:10px;}',
            '.details h3{margin:10px 0 6px 0;font-size:14px;}',
            '.scroll{overflow-x:auto;}',
            'table{min-width:520px;}',
            '/* Lightbox */',
            '.lightbox{position:fixed;inset:0;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,0.7);z-index:9999;}',
            '.lightbox.open{display:flex;}',
            '.lb-inner{max-width:96vw;max-height:92vh;text-align:center;}',
            '.lb-inner img{max-width:96vw;max-height:85vh;border-radius:10px;box-shadow:0 8px 30px rgba(0,0,0,0.45);}',
            '.lb-cap{color:#e6eef7;margin-top:8px;font-size:13px;opacity:0.9;}',
            '</style>',
            '</head><body>',
            f'<h1>{summary["title"]}</h1>'
        ]
        # Capture window display
        w = summary['window']
        if w and (w.get('since_unix') and w.get('until_unix')):
            html += [f"<div class=\"meta\">Window: {w['since_human']} ({w['since_unix']}) → {w['until_human']} ({w['until_unix']})</div>"]
            html += [f"<div class=\"meta\">Generated: {summary['generated']['human']} ({summary['generated']['unix']})</div>"]
        elif summary['meta']:
            html += [f'<div class="meta">{summary["meta"]}</div>']
        html += ['<div class="grid">']
        for key, st in summary['topics'].items():
            html += [f'<div class="card"><h2>{key}</h2><div class="body">']
            dr = st['delivered_ratio']
            lat = st['latency_ms']
            def fmt(v):
                return '' if v is None else (str(int(v)) if abs(v-int(v))<1e-9 else f"{v:.1f}")
            html += [
                '<div class="chips">',
                f'<div class="chip">published: <strong>{st["published"]}</strong></div>',
                f'<div class="chip">received: <strong>{st["received"]}</strong></div>',
                f'<div class="chip">missing: <strong>{st["missing"]}</strong></div>',
                f'<div class="chip">delivered ratio: <strong>{"" if dr is None else round(dr,3)}</strong></div>',
                '</div>',
                '<div class="scroll">',
                '<table class="stats"><tr><th>min</th><th>mean</th><th>p50</th><th>p95</th><th>p99</th><th>max</th></tr>',
                f'<tr><td>{fmt(lat["min"])}</td><td>{fmt(lat["mean"])}</td><td>{fmt(lat["p50"])}</td><td>{fmt(lat["p95"])}</td><td>{fmt(lat["p99"])}</td><td>{fmt(lat["max"])}</td></tr></table>',
                '</div>'
            ]
            imgs = [
                (f'latency_{key}.png', 'Latency vs Seq', 'For each received message, latency_ms = recv_ts_ms − pub_ts_ms; x-axis is published sequence.'),
                (f'latency_{key}_with_missing.png', 'Latency + Missing', 'Latency line for received messages; red markers at y=0 denote publishes with no matching receive within the window.'),
                (f'rate_{key}.png', 'Published vs Received per Second', 'Published counts are grouped by publish second; received counts by receive second. Time on x-axis.'),
                (f'rate_{key}_ratio.png', 'Delivered Ratio per Pub-Second', 'For each publish second: delivered/published, bounded in [0,1].'),
            ]
            have = 0
            html += ['<div class="charts">']
            for fn, title, desc in imgs:
                p = os.path.join(args.outdir, fn)
                if os.path.exists(p):
                    have += 1
                    cap = f"{title} — {desc}"
                    html += [f'<figure><img class="chart" src="{fn}" alt="{title}" title="{title}" data-caption="{cap}"><figcaption>{cap}</figcaption></figure>']
            html += ['</div>']
            if have == 0:
                html += ['<div class="note">No charts generated. Install gnuplot to render PNGs.</div>']

            # Config (bulleted)
            cfg = st.get('config') or {}
            html += ['<div class="details">']
            html += ['<h3>Publisher config</h3>','<ul>']
            def item(k, v):
                return f"<li><strong>{k}</strong>: {'' if v is None else v}</li>"
            html += [
                item('publisher', cfg.get('publisher')),
                item('client_id', cfg.get('client_id')),
                item('host', cfg.get('host')),
                item('port', cfg.get('port')),
                item('keepalive_secs', cfg.get('keepalive_secs')),
                item('clean_session', cfg.get('clean_session')),
                item('separate_pubsub_connections', cfg.get('separate_pubsub_connections')),
                item('qos', cfg.get('qos')),
                item('payload_bytes', cfg.get('payload_bytes')),
                item('publish_interval_ms', cfg.get('publish_interval_ms')),
            ]
            html += ['</ul>']

            # Details table (time, seq, received?, latency)
            topic = {'offer':'/driver/offer','ride':'/driver/ride','location':'/driver/location'}[key]
            rows = by_topic_recv.get(topic, [])
            pubs = by_topic_pub.get(topic, [])
            recv_map = { seq:(lat, pub_ts, recv_ts) for (seq, lat, pub_ts, recv_ts) in rows }
            html += ['<h3>Messages</h3>','<div class="scroll">','<table><tr><th>time</th><th>seq</th><th>received?</th><th>latency_ms</th></tr>']
            for seq, pub_ts in pubs[:2000]:
                tstr = datetime.fromtimestamp(pub_ts/1000).strftime('%Y-%m-%d %H:%M:%S')
                r = recv_map.get(seq)
                received = 'yes' if r else 'no'
                lat = (r[0] if r else '')
                html += [f'<tr><td>{tstr}</td><td>{seq}</td><td>{received}</td><td>{lat}</td></tr>']
            html += ['</table>','</div>','</div>']
            html += ['</div></div>']
        html += ['</div>']
        # Lightbox overlay and behavior
        html += [
            '<div id="lightbox" class="lightbox" aria-modal="true" role="dialog">',
            '  <div class="lb-inner">',
            '    <img id="lb-img" alt="chart">',
            '    <div id="lb-cap" class="lb-cap"></div>',
            '  </div>',
            '</div>',
            '<script>',
            '  (function(){',
            '    const lb = document.getElementById("lightbox");',
            '    const im = document.getElementById("lb-img");',
            '    const cp = document.getElementById("lb-cap");',
            '    function open(src, cap){ im.src = src; cp.textContent = cap||""; lb.classList.add("open"); }',
            '    function close(){ lb.classList.remove("open"); im.src=""; cp.textContent=""; }',
            '    document.addEventListener("click", function(e){',
            '      const t = e.target;',
            '      if (t && t.classList && t.classList.contains("chart")) {',
            '        open(t.getAttribute("src"), t.getAttribute("data-caption"));',
            '      } else if (t === lb) {',
            '        close();',
            '      }',
            '    });',
            '    document.addEventListener("keydown", function(e){ if (e.key === "Escape") close(); });',
            '  })();',
            '</script>'
        ]
        html += ['</body></html>']
        with open(os.path.join(args.outdir, 'index.html'), 'w') as f:
            f.write('\n'.join(html))

    # Print outputs
    for t, key in topic_map.items():
        for name in [f'latency_{key}.csv', f'latency_{key}_missing.csv', f'rate_{key}.csv']:
            p = os.path.join(args.outdir, name)
            if os.path.exists(p):
                print(f"[latency_parse] wrote {p}")
    for name in ['summary.json', 'summary.txt', 'index.html']:
        p = os.path.join(args.outdir, name)
        if os.path.exists(p):
            print(f"[latency_parse] wrote {p}")

if __name__ == '__main__':
    main()
