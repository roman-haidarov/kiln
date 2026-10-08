import argparse, json, os, pathlib, statistics, subprocess

p=argparse.ArgumentParser()
p.add_argument('baseline');p.add_argument('candidate')
p.add_argument('--runs',type=int,default=3);p.add_argument('--iterations',type=int,default=300000)
p.add_argument('--output',default=os.environ.get('KILN_VALIDATION_DIR','/tmp/kiln-validation')+'/cpu-compare.json')
a=p.parse_args();rows=[]
for i in range(a.runs):
    pairs=[('baseline',a.baseline),('candidate',a.candidate)]
    if i%2:pairs.reverse()
    for name,binary in pairs:
        result=subprocess.run([binary,str(a.iterations)],capture_output=True,text=True,check=True)
        values=dict(field.split('=') for field in result.stdout.strip().split())
        row={'name':name,'run':i,'iterations':int(values['iterations']),'seconds':float(values['seconds'])}
        rows.append(row);print(json.dumps(row),flush=True)
summary={name:statistics.median(row['seconds']/row['iterations']*1e6 for row in rows if row['name']==name) for name in ('baseline','candidate')}
output=pathlib.Path(a.output);output.parent.mkdir(parents=True,exist_ok=True);output.write_text(json.dumps({'workers':os.environ.get('SPINEL_WORKERS'),'rows':rows,'median_us':summary},indent=2)+'\n')
print(json.dumps(summary),flush=True)
