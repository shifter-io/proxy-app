#!/usr/bin/env python3
"""Local proxy benchmark: every test runs once straight to the gateway and once
through the local proxy, so the difference is the proxy's own cost.
  python3 tool/bench/run.py   (needs /tmp/bench_servers and /tmp/bench_proxy, see README in this folder)
"""
import base64, re, struct, socket, statistics, subprocess, sys, threading, time

def start(cmd):
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True)
    return p, p.stdout.readline().split()

servers, out = start(['/tmp/bench_servers'])
ORIGIN, GW = int(out[1]), int(out[3])
proxy, out = start(['/tmp/bench_proxy', str(GW)])
PX = int(out[1])
AUTH = 'Basic ' + base64.b64encode(b'customer-bench:bench').decode()

def cpu_s(pid):
    t = subprocess.run(['ps', '-o', 'time=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    m, s = t.split(':')
    return int(m) * 60 + float(s)

def rss_mb(pid):
    return int(subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout) / 1024

def fds(pid):
    return len(subprocess.run(['lsof', '-p', str(pid)], capture_output=True, text=True).stdout.splitlines()) - 1

def tunnel_request(port, direct, path='/small'):
    """CONNECT (what every HTTPS site uses), then one request inside. Returns seconds."""
    t0 = time.perf_counter()
    s = socket.create_connection(('127.0.0.1', port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    hdr = f'Proxy-Authorization: {AUTH}\r\n' if direct else ''
    s.sendall(f'CONNECT site.test:443 HTTP/1.1\r\nHost: site.test:443\r\n{hdr}\r\n'.encode())
    buf = b''
    while b'\r\n\r\n' not in buf:
        buf += s.recv(4096)
    assert b' 200 ' in buf.split(b'\r\n')[0], buf[:80]
    s.sendall(f'GET {path} HTTP/1.1\r\nHost: site.test\r\nConnection: close\r\n\r\n'.encode())
    got = b''
    while True:
        d = s.recv(1 << 20)
        if not d: break
        got += d
    s.close()
    assert got.endswith(b'ok') or path != '/small', got[:80]
    return time.perf_counter() - t0, len(got)

def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(len(xs) * p))]

socket.setdefaulttimeout(60)  # a stuck test fails instead of hanging
results = []
def row(name, direct, via, unit, note=''):
    results.append((name, direct, via, unit, note))
    print(f'{name:<44} direct {direct:>10} | via proxy {via:>10} {unit}  {note}', flush=True)

base_cpu = cpu_s(proxy.pid)
print(f'proxy pid {proxy.pid}, start RSS {rss_mb(proxy.pid):.1f} MB, fds {fds(proxy.pid)}')

# 1. Idle
time.sleep(30)
row('idle 30 s: proxy CPU time', '-', f'{(cpu_s(proxy.pid) - base_cpu) * 1000:.0f}', 'ms CPU', f'RSS {rss_mb(proxy.pid):.1f} MB')

# 2. Latency, one new HTTPS tunnel per request, sequential
for port, direct in [(GW, True), (PX, False)]:
    for _ in range(50): tunnel_request(port, direct)  # warm up
lat = {}
for port, direct in [(GW, True), (PX, False)]:
    lat[direct] = [tunnel_request(port, direct)[0] * 1000 for _ in range(1000)]
row('new HTTPS tunnel + request, median', f'{statistics.median(lat[True]):.3f}', f'{statistics.median(lat[False]):.3f}', 'ms',
    f'overhead {statistics.median(lat[False]) - statistics.median(lat[True]):+.3f} ms')
row('new HTTPS tunnel + request, p99', f'{pct(lat[True], .99):.3f}', f'{pct(lat[False], .99):.3f}', 'ms')

# 3. Plain HTTP requests, ab: sequential and 100 concurrent
def ab(port, direct, n, c):
    args = ['ab', '-q', '-n', str(n), '-c', str(c), '-X', f'127.0.0.1:{port}']
    if direct: args += ['-P', 'customer-bench:bench']
    out = subprocess.run(args + ['http://site.test/small'], capture_output=True, text=True).stdout
    rps = float(re.search(r'Requests per second:\s+([\d.]+)', out).group(1))
    failed = int(re.search(r'Failed requests:\s+(\d+)', out).group(1))
    non2xx = re.search(r'Non-2xx responses:\s+(\d+)', out)
    p99 = re.search(r'\s99%\s+(\d+)', out).group(1)
    return rps, failed + (int(non2xx.group(1)) if non2xx else 0), p99
for c in (1, 100):
    d = ab(GW, True, 5000, c); before = cpu_s(proxy.pid); v = ab(PX, False, 5000, c); used = cpu_s(proxy.pid) - before
    row(f'plain HTTP, {c} at a time, 5000 req', f'{d[0]:.0f}', f'{v[0]:.0f}', 'req/s',
        f'errors {d[1]}/{v[1]}, p99 {d[2]}/{v[2]} ms, proxy {used / 5000 * 1e6:.0f} µs CPU/req')

# 4. Throughput: one 2 GB download through an HTTPS tunnel
def curl_dl(port, direct, size):
    args = ['curl', '-s', '-o', '/dev/null', '-p', '-x', f'http://127.0.0.1:{port}', '-w', '%{speed_download}']
    if direct: args += ['--proxy-user', 'customer-bench:bench']
    return float(subprocess.run(args + [f'http://site.test/bytes/{size}'], capture_output=True, text=True).stdout) / 1e6
size = 2_000_000_000
d = curl_dl(GW, True, size); before = cpu_s(proxy.pid); v = curl_dl(PX, False, size); used = cpu_s(proxy.pid) - before
row('2 GB download in one tunnel', f'{d:.0f}', f'{v:.0f}', 'MB/s', f'proxy {used / 2:.2f} CPU-s per GB, RSS {rss_mb(proxy.pid):.1f} MB')

# 5. 200 tunnels at once, 20 MB each
def parallel(port, direct, n, path):
    errs, sizes = [], []
    def one():
        try: sizes.append(tunnel_request(port, direct, path)[1])
        except Exception as e: errs.append(e)
    ts = [threading.Thread(target=one) for _ in range(n)]
    t0 = time.perf_counter(); [t.start() for t in ts]; [t.join() for t in ts]
    return time.perf_counter() - t0, len(errs), sum(sizes)
peak = [0.0]; stop = threading.Event()
def watch():
    while not stop.is_set(): peak[0] = max(peak[0], rss_mb(proxy.pid)); time.sleep(0.05)
d = parallel(GW, True, 200, '/bytes/20000000')
w = threading.Thread(target=watch); w.start(); before = cpu_s(proxy.pid)
v = parallel(PX, False, 200, '/bytes/20000000')
used = cpu_s(proxy.pid) - before; stop.set(); w.join()
row('200 tunnels at once, 20 MB each (4 GB)', f'{d[0]:.2f}', f'{v[0]:.2f}', 's',
    f'errors {d[1]}/{v[1]}, peak RSS {peak[0]:.1f} MB, proxy {used:.2f} CPU-s')

# 6. 50 slow readers (2 MB/s each) on a fast site: memory must stay bounded
total = [0]; stop = threading.Event()
def slow_reader():
    s = socket.create_connection(('127.0.0.1', PX))
    s.sendall(b'CONNECT site.test:443 HTTP/1.1\r\nHost: site.test:443\r\n\r\n'); s.recv(4096)
    s.sendall(b'GET /bytes/1000000000 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n')
    while not stop.is_set():
        total[0] += len(s.recv(65536)); time.sleep(0.03)
    s.close()
ts = [threading.Thread(target=slow_reader) for _ in range(50)]; [t.start() for t in ts]
before = cpu_s(proxy.pid); peak = 0.0
for _ in range(20):
    time.sleep(1); peak = max(peak, rss_mb(proxy.pid))
used = cpu_s(proxy.pid) - before; stop.set(); [t.join() for t in ts]
row('50 slow readers for 20 s', '-', f'{peak:.1f}', 'MB peak RSS', f'{total[0] / 1e6:.0f} MB delivered, proxy {used:.2f} CPU-s')
time.sleep(1)
print(f'   after slow readers closed: proxy {"alive" if proxy.poll() is None else "EXITED " + str(proxy.returncode)}, '
      f'servers {"alive" if servers.poll() is None else "EXITED " + str(servers.returncode)}', flush=True)

# 7. Clients that vanish mid-download (reset): the proxy must survive
for _ in range(100):
    s = socket.create_connection(('127.0.0.1', PX))
    s.sendall(b'CONNECT site.test:443 HTTP/1.1\r\nHost: site.test:443\r\n\r\n'); s.recv(4096)
    s.sendall(b'GET /bytes/100000000 HTTP/1.1\r\nHost: x\r\n\r\n'); s.recv(65536)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('ii', 1, 0))  # close() sends RST
    except OSError:
        pass  # already closed by the other side
    s.close()
time.sleep(1)
alive = proxy.poll() is None
row('100 clients reset mid-download', '-', 'alive' if alive else 'CRASHED', '', f'then a request: {tunnel_request(PX, False)[1] if alive else "-"} bytes ok')

# 8. Nothing left behind
time.sleep(2)
idle_before = cpu_s(proxy.pid); time.sleep(10)
row('after load: idle 10 s', '-', f'{(cpu_s(proxy.pid) - idle_before) * 1000:.0f}', 'ms CPU',
    f'fds {fds(proxy.pid)}, RSS {rss_mb(proxy.pid):.1f} MB, total CPU {cpu_s(proxy.pid) - base_cpu:.1f} s')

proxy.terminate(); servers.terminate()
