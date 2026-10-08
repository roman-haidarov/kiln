import pathlib, shutil, subprocess, json, os, tempfile, re
project=pathlib.Path(__file__).resolve().parents[1]
compiler=os.environ.get('SPINEL','spinel')
timeout_seconds=int(os.environ.get('MUTATION_TIMEOUT','30'))
result_path=pathlib.Path(os.environ.get('KILN_VALIDATION_DIR','/tmp/kiln-validation'))/'mutations.json'
result_path.parent.mkdir(parents=True,exist_ok=True)
rows=[]
mutations=[
 ('stale_double_close','kiln/pool.rb','test/lifecycle_test.rb','stale_quarantine','nil','FAIL kill during stale resource close does not close twice'),
 ('expired_cpu_start','kiln/cpu_pool.rb','test/lifecycle_test.rb','if Kiln.now >= expires','if false','wait timeout'),
 ('connection_cleanup_lock','kiln/server.rb','test/lifecycle_test.rb','def finish(slot)\n      @finished << slot','def finish(slot)\n      @lock.synchronize { @finished << slot }','FAIL connection ensure completes while server mutex is held'),
 ('header_overlap','kiln/server/request.rb','test/server_test.rb','from = buf.size - marker.bytesize + 1','from = buf.size','FAIL header terminator split across three reads is found'),
 ('chunk_extensions','kiln/server/request.rb','bench/chunk_extension_probe.rb','size = HttpNative.kiln_chunk_size(line, line.bytesize, @max_body - body.bytesize)','size = line == "3;".b ? 3 : HttpNative.kiln_chunk_size(line, line.bytesize, @max_body - body.bytesize)','FAIL invalid extension "3;" -> 400'),
 ('spawn_after_close','kiln/cpu_pool.rb','test/lifecycle_test.rb','return false if @closed','nil','FAIL replacement after close does not call Thread.new'),
 ('constructor_leak','kiln/cpu_pool.rb','test/lifecycle_test.rb','shutdown(grace: 0) unless initialized','nil','FAIL constructor failure closes workers already started'),
 ('batch_handoff','kiln/pool.rb','test/lifecycle_test.rb','if granted && (!@idle.empty? || @open < @size) && @wake.empty?','if false','FAIL batched returns wake all waiters without polling')
]
selected=os.environ.get('MUTATIONS','').split(',')
for name,file,test,old,new,expected in mutations:
 if selected!=[''] and name not in selected:continue
 with tempfile.TemporaryDirectory(prefix='kiln-mutant-') as temporary:
  dest=pathlib.Path(temporary)/name
  shutil.copytree(project,dest,ignore=shutil.ignore_patterns('build','.git','__pycache__'))
  target=dest/file;s=target.read_text()
  if old=='stale_quarantine':
   s,count=re.subn(r'(?m)^([ \t]*)quarantine = true\n\1entry = nil$',r'\1nil',s)
  else:
   count=s.count(old)
   s=s.replace(old,new)
  assert count==1,(name,count)
  target.write_text(s)
  links=subprocess.check_output(['./ext/build.sh'],cwd=dest,text=True).split()
  build=subprocess.run([compiler,*links,'-I','.',test,'-o','build/mutant'],cwd=dest,capture_output=True,text=True)
  if build.returncode:raise RuntimeError(build.stderr)
  try:
   run=subprocess.run(['build/mutant'],cwd=dest,env={**os.environ,'SPINEL_WORKERS':'1'},capture_output=True,text=True,timeout=timeout_seconds)
   evidence=expected in run.stdout or expected in run.stderr
   row={'name':name,'detected':run.returncode!=0 and evidence,'exit_code':run.returncode,'expected':expected,'stderr':run.stderr[-1500:],'last_output':run.stdout.splitlines()[-3:]}
  except subprocess.TimeoutExpired as err:
   stdout=err.stdout.decode(errors='replace') if isinstance(err.stdout,bytes) else err.stdout or ''
   stderr=err.stderr.decode(errors='replace') if isinstance(err.stderr,bytes) else err.stderr or ''
   evidence=expected in stdout or expected in stderr
   row={'name':name,'detected':evidence,'timeout':True,'expected':expected,'stderr':stderr[-1500:],'last_output':stdout.splitlines()[-3:]}
 rows.append(row);print(json.dumps(row,ensure_ascii=False),flush=True)
previous=json.loads(result_path.read_text()) if result_path.exists() else []
merged={r['name']:r for r in previous}
merged.update({r['name']:r for r in rows})
result_path.write_text(json.dumps(list(merged.values()),ensure_ascii=False,indent=2)+'\n')
assert all(r['detected'] for r in rows)
