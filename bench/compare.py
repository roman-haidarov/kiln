import argparse, asyncio, json, os, pathlib, statistics, subprocess, time

p=argparse.ArgumentParser()
p.add_argument('baseline');p.add_argument('candidate');p.add_argument('--seconds',type=float,default=3)
p.add_argument('--runs',type=int,default=5);p.add_argument('--output',default=os.environ.get('KILN_VALIDATION_DIR','/tmp/kiln-validation')+'/compare.json')
a=p.parse_args()

async def client(port,until):
    r,w=await asyncio.open_connection('127.0.0.1',port)
    done=0
    try:
        request=b'GET /health HTTP/1.1\r\nHost: x\r\nUser-Agent: benchmark\r\nAccept: */*\r\n\r\n'*8
        while time.monotonic()<until:
            w.write(request);await w.drain()
            for _ in range(8):
                head=await r.readuntil(b'\r\n\r\n')
                assert head.startswith(b'HTTP/1.1 200')
                length=int(next(line.split(b':',1)[1] for line in head.split(b'\r\n') if line.lower().startswith(b'content-length:')))
                await r.readexactly(length);done+=1
        return done
    finally:w.close();await w.wait_closed()

def sample(pid):
    f=pathlib.Path(f'/proc/{pid}/stat').read_text().split()
    return (int(f[13])+int(f[14]))/os.sysconf('SC_CLK_TCK')

async def run(binary):
    proc=subprocess.Popen([binary],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    line=proc.stdout.readline()
    while line and not line.startswith('{'):line=proc.stdout.readline()
    ready=json.loads(line);pid=ready['proc_pid'];port=ready['port']
    await asyncio.gather(*(client(port,time.monotonic()+.5) for _ in range(16)))
    before=sample(pid);start=time.monotonic();counts=await asyncio.gather(*(client(port,start+a.seconds) for _ in range(32)));seconds=time.monotonic()-start;cpu=sample(pid)-before
    proc.stdin.write('stop\n');proc.stdin.flush();end=json.loads(proc.stdout.readline());proc.wait(timeout=15)
    stderr=proc.stderr.read()
    if os.environ.get("CAPTURE_STDERR"):
        capture=pathlib.Path(os.environ["CAPTURE_STDERR"]);capture.parent.mkdir(parents=True,exist_ok=True);capture.write_text(stderr)
    if proc.returncode:raise RuntimeError(stderr)
    return {'requests':sum(counts),'seconds':seconds,'rps':sum(counts)/seconds,'cpu_us':cpu/sum(counts)*1e6,'shutdown':end}

async def main():
    rows=[]
    for i in range(a.runs):
        for name,binary in ([('baseline',a.baseline),('candidate',a.candidate)] if i%2==0 else [('candidate',a.candidate),('baseline',a.baseline)]):
            row=await run(binary);row.update(name=name,run=i);rows.append(row);print(json.dumps(row),flush=True)
    summary={name:{key:statistics.median(row[key] for row in rows if row['name']==name) for key in ('rps','cpu_us')} for name in ('baseline','candidate')}
    output=pathlib.Path(a.output);output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps({'workers':os.environ.get('SPINEL_WORKERS'),'rows':rows,'summary':summary},indent=2)+'\n');print(json.dumps(summary),flush=True)
asyncio.run(main())
