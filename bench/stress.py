import argparse, asyncio, json, os, pathlib, statistics, subprocess, time
from collections import Counter

parser = argparse.ArgumentParser()
parser.add_argument('binary', nargs='?', default='build/stress_server')
parser.add_argument('--idle', type=int, default=10000)
parser.add_argument('--seconds', type=float, default=10)
parser.add_argument('--output', default=os.environ.get('KILN_VALIDATION_DIR', '/tmp/kiln-validation') + '/stress.json')
args = parser.parse_args()

def proc_stats(pid):
    fields = pathlib.Path(f'/proc/{pid}/stat').read_text().split()
    ticks = os.sysconf('SC_CLK_TCK')
    status = pathlib.Path(f'/proc/{pid}/status').read_text()
    rss = int(next(x.split()[1] for x in status.splitlines() if x.startswith('VmRSS:')))
    targets = sorted(os.readlink(fd) for fd in pathlib.Path(f'/proc/{pid}/fd').iterdir())
    return {'cpu': (int(fields[13]) + int(fields[14])) / ticks, 'rss_kib': rss,
            'fds': len(targets), 'fd_targets': targets}

class Server:
    def __init__(self, **env):
        self.p = subprocess.Popen([args.binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, env={**os.environ, **{k:str(v) for k,v in env.items()}})
        ready = json.loads(self.p.stdout.readline())
        self.port = ready['port']
        self.proc_pid = ready['proc_pid']
    def stats(self):
        self.p.stdin.write('stats\n'); self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def stop(self):
        self.p.stdin.write('stop\n'); self.p.stdin.flush()
        result=json.loads(self.p.stdout.readline()); self.p.wait(timeout=15)
        if self.p.returncode: raise RuntimeError(self.p.stderr.read())
        assert result['connections']==0 and result['handling']==0 and result['in_flight']==0
        assert result['pool_consistent'] and result['cpu_alive']==0
        return result

async def exchange(port, path='/health', partial=None, read=True):
    started = time.monotonic()
    r,w = await asyncio.open_connection('127.0.0.1',port)
    try:
        data=partial or f'GET {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'.encode()
        w.write(data); await w.drain()
        if not read:
            await asyncio.sleep(1)
            return 0, time.monotonic()-started
        result=await asyncio.wait_for(r.read(), 4)
        if result.startswith(b'HTTP/'):
            head,body=result.split(b'\r\n\r\n',1)
            length=int(next(line.split(b':',1)[1] for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:')))
            assert len(body)==length,(len(body),length)
            code=int(head.split(b' ',2)[1])
        else:
            code=0
        return code,time.monotonic()-started
    finally:
        w.close()
        try:
            await w.wait_closed()
        except (ConnectionResetError, BrokenPipeError):
            pass

async def run():
    result={'workers':os.environ.get('SPINEL_WORKERS','auto')}
    s=Server(MAX_CONNS=args.idle)
    clients=[]
    warm=await asyncio.gather(*(exchange(s.port) for _ in range(32)))
    assert all(code==200 for code,lat in warm)
    for _ in range(100):
        if s.stats()['connections']==0:break
        await asyncio.sleep(.01)
    base_resources=proc_stats(s.proc_pid)
    for start in range(0,args.idle,100):
        clients.extend(await asyncio.gather(*(asyncio.open_connection('127.0.0.1',s.port) for _ in range(min(100,args.idle-start)))))
    for _ in range(200):
        if s.stats()['connections']==args.idle:break
        await asyncio.sleep(.01)
    before=s.stats();assert before['connections']==args.idle,before
    first=proc_stats(s.proc_pid);t=time.monotonic();await asyncio.sleep(args.seconds);last=proc_stats(s.proc_pid)
    result['idle']={'clients':args.idle,'seconds':time.monotonic()-t,'cpu_percent_core':100*(last['cpu']-first['cpu'])/(time.monotonic()-t),'rss_kib':last['rss_kib'],'fds':last['fds'],'stats':s.stats()}
    overflow=await exchange(s.port);assert overflow[0]==503,overflow
    more=await asyncio.gather(*(exchange(s.port) for _ in range(64)))
    assert all(code==503 for code,lat in more),more
    result['idle']['overflow_requests']=65
    result['idle']['overflow_status']=overflow[0]
    for r,w in clients:w.close()
    await asyncio.gather(*(w.wait_closed() for r,w in clients))
    for _ in range(300):
        if s.stats()['connections']==0:break
        await asyncio.sleep(.01)
    result['idle']['after_disconnect']=s.stats();result['idle']['resources_before']=base_resources;result['idle']['resources_after']=proc_stats(s.proc_pid)
    after=Counter(result['idle']['resources_after']['fd_targets']);before=Counter(base_resources['fd_targets'])
    assert not before-after,(before-after)
    added=after-before;pollers=added.pop('anon_inode:[eventpoll]',0)
    assert all(target.startswith('pipe:[') and count==2 for target,count in added.items()),added
    assert len(added)==pollers,(added,pollers)
    assert after['anon_inode:[eventpoll]']<=int(os.environ.get('SPINEL_WORKERS',str(os.cpu_count())))+1
    result['idle']['lazy_runtime_fds']={'pollers':pollers,'wake_pipe_pairs':len(added)}
    assert result['idle']['after_disconnect']['free']==args.idle
    result['idle']['shutdown']=s.stop()
    s=Server(MAX_CONNS=512)
    slow=await asyncio.gather(*(exchange(s.port,partial=b'GET /health HTTP/1.1\r\nHost: x\r\nX: ') for _ in range(256)))
    assert all(code==408 for code,lat in slow),slow[:5]
    result['slow_headers']={'clients':len(slow),'codes':{'408':len(slow)},'max_seconds':max(lat for code,lat in slow),'stats':s.stats()}
    await asyncio.sleep(.6)
    work=[exchange(s.port,'/health') for _ in range(300)]+[exchange(s.port,'/hang') for _ in range(16)]+[exchange(s.port,'/cpu') for _ in range(48)]+[exchange(s.port,'/big',read=False) for _ in range(8)]
    mixed=await asyncio.gather(*work);health=[lat for code,lat in mixed[:300]]
    assert all(code==200 for code,lat in mixed[:300])
    assert all(code==504 for code,lat in mixed[300:316])
    await asyncio.sleep(.6);st=s.stats();assert st['connections']==0 and st['handling']==0 and st['in_flight']==0 and st['pool_consistent'] and st['pool_out']==0 and st['pool_available']==16,st
    result['mixed']={'requests':len(work),'codes':{str(k):sum(code==k for code,lat in mixed) for k in sorted({code for code,lat in mixed})},'health_p50_ms':statistics.median(health)*1000,'health_p99_ms':sorted(health)[int(len(health)*.99)-1]*1000,'stats':st}
    pending=[asyncio.create_task(exchange(s.port,'/hang')) for _ in range(16)]
    await asyncio.sleep(.05)
    result['mixed']['shutdown']=s.stop()
    await asyncio.gather(*pending,return_exceptions=True)
    assert result['mixed']['shutdown']['free']==512
    output=pathlib.Path(args.output);output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
asyncio.run(run())
