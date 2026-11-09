"""Terminate only the dedicated admission app on an explicitly supplied simulator."""
import json, pathlib, subprocess, sys, time, os, signal, uuid
device, app, evidence = sys.argv[1:]
bundle = 'is.oneway.alt2.VodozemacAdmissionHost'
run_id=uuid.uuid4().hex
last_pid=None
def run(*args):
    return subprocess.check_output(['xcrun','simctl',*args],text=True).strip()
subprocess.run(['xcrun','simctl','boot',device],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
run('bootstatus',device,'-b')
run('install',device,app)
container=pathlib.Path(run('get_app_container',device,bundle,'data'))
root=container/'Library/Application Support/ALT2'
def launch(phase,marker):
    global last_pid
    path=root/marker
    path.unlink(missing_ok=True)
    output=run('launch','--terminate-running-process',device,bundle,'--alt2-phase',phase,'--alt2-run',run_id)
    last_pid=int(output.rsplit(':',1)[1].strip())
    for _ in range(200):
        if path.exists():return path.read_text()
        time.sleep(.1)
    raise RuntimeError('bounded marker timeout: '+phase)
results={'termination':'SIGKILL of simctl-returned dedicated host PID','setup':json.loads(launch('setup','result'))['status'],'boundaries':{}}
assert results['setup']=='PASS'
for point in ['beforeEncryption','afterEncryption','beforeStateCommit','afterStateCommit','beforeNetworkSend','afterNetworkSend','beforeAcknowledgement','duringDecrypt','afterDecrypt','beforeInboundCommit','afterInboundCommit']:
    before=json.loads(launch('kill-'+point,'ready'))
    assert before['point']==point
    os.kill(last_pid,signal.SIGKILL)
    time.sleep(.5)
    result=json.loads(launch('resume-'+point,'result'))
    committed=point not in ['beforeEncryption','afterEncryption','beforeStateCommit']
    if committed:assert before['outbox_digest']==result['outbox_digest'],point
    results['boundaries'][point]={'status':result['status'],'committed_ciphertext_retry_identical':True if committed else 'not transmitted before commit'}
    pathlib.Path(evidence).write_text(json.dumps(results,indent=2)+'\n')
    assert result['status']=='PASS',point
run('terminate',device,bundle)
print(json.dumps(results))
