"""Cache invalidation and fresh-run regressions; every assertion still executes."""
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

from fixture_cache import Inputs, Results
import run_checks as runner


def row(proof):
    return dict(module='check_probe.py', returncode=0, seconds=.01, cases=[], input_proof=proof)


def check_observed_inputs():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder);inputs=root/'inputs';inputs.mkdir()
        data=inputs/'data.ks';data.write_text('one')
        missing=inputs/'optional.ks';check=root/'check_probe.py'
        store=Results(root/'cache','context')
        with Inputs() as capture:
            assert data.read_text()=='one'
            assert not missing.exists()
            assert [p.name for p in inputs.iterdir()]==['data.ks']
        proof=capture.finish()
        assert proof['cacheable'],proof['reason']
        store.save(check,row(proof))
        assert store.lookup(check)['cached']
        assert Results(root/'cache','other-context').lookup(check) is None
        # Same length and restored mtime must not conceal changed contents.
        prior=data.stat();data.write_text('two');os.utime(data,ns=(prior.st_atime_ns,prior.st_mtime_ns))
        assert store.lookup(check) is None
        data.write_text('one')
        with Inputs() as capture:
            missing.exists()
        store.save(check,row(capture.finish()))
        assert store.lookup(check)
        missing.write_text('new')
        assert store.lookup(check) is None
        with Inputs() as capture:list(inputs.iterdir())
        store.save(check,row(capture.finish()));assert store.lookup(check)
        (inputs/'another.ks').write_text('new directory member')
        assert store.lookup(check) is None
        link=root/'link';link.symlink_to(data)
        with Inputs() as capture:link.lstat()
        store.save(check,row(capture.finish()));assert store.lookup(check)
        link.unlink();link.symlink_to(data)
        assert store.lookup(check) is None
        with Inputs() as capture:
            inputs.resolve();assert inputs.is_dir()
        store.save(check,row(capture.finish()));assert store.lookup(check)
        (inputs/'irrelevant.txt').write_text('does not change resolved path/type')
        assert store.lookup(check)
        with Inputs() as capture:inputs.stat()
        store.save(check,row(capture.finish()));assert store.lookup(check)
        (inputs/'metadata-change.txt').write_text('changes explicit directory metadata')
        assert store.lookup(check) is None
    print('PASS: verified results invalidate on changed content/metadata, newly appearing optional inputs, directory changes and context changes')


def check_failure_and_uncertainty():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder);check=root/'check_probe.py';store=Results(root/'cache','context')
        proof=dict(cacheable=True,inputs=[],reason='')
        store.save(check,row(proof));assert store.lookup(check)
        failed=row(proof);failed['returncode']=1;store.save(check,failed)
        assert store.lookup(check) is None
        store.save(check,row(proof));store.save(check,row(dict(cacheable=False,reason='external',inputs=[])))
        assert store.lookup(check) is None
        store.save(check,row(proof));store.path(check).write_text('{broken')
        assert store.lookup(check) is None
        store.save(check,row(proof));store.discard(check);assert store.lookup(check) is None
        source=root/'existing';source.write_text('old')
        with Inputs() as capture:source.write_text('new')
        assert not capture.finish()['cacheable']
        with Inputs() as capture:sys.audit('subprocess.Popen','unobserved-child',[],None,None)
        assert not capture.finish()['cacheable']
    print('PASS: failures, corrupt records, uncertain/external operations and writes to existing inputs cannot reuse a pass; explicit fresh failure revocation is available')


def check_end_to_end_cache():
    with tempfile.TemporaryDirectory() as folder:
        root=Path(folder);scripts=root/'scripts';scripts.mkdir()
        data=root/'data.ks';data.write_text('one')
        helper=scripts/'helper.py';helper.write_text('VALUE="one"\n')
        unrelated=scripts/'unrelated.py';unrelated.write_text('VALUE="unused"\n')
        probe=scripts/'check_probe.py'
        probe.write_text('from pathlib import Path\nfrom helper import VALUE\n'
            'def check_case():\n'
            f'    value=Path({str(data)!r}).read_text()\n'
            '    assert value in ("one","two")\n'
            '    assert VALUE in ("one","two")\n'
            '    print("observed-"+value)\n'
            'if __name__ == "__main__": check_case()\n')
        cache_dir=root/'cache';report=root/'report.json'
        def invoke(fresh=False):
            argv=['run_checks','--jobs','1','--cache-dir',str(cache_dir),'--json',str(report)]
            if fresh:argv+=['--no-cache']
            with patch.object(runner,'ROOT',root),patch.object(runner,'SLOW_FILES',set()),patch.object(sys,'argv',argv),redirect_stdout(io.StringIO()):
                code=runner.main()
            return code,json.loads(report.read_text())
        code,result=invoke();assert code==0 and result['cached']==0
        code,result=invoke();assert code==0 and result['cached']==1
        unrelated.write_text('VALUE="still unused"\n')
        code,result=invoke();assert code==0 and result['cached']==1
        helper.write_text('VALUE="two"\n')
        code,result=invoke();assert code==0 and result['cached']==0
        data.write_text('two')
        code,result=invoke();assert code==0 and result['cached']==0
        with patch.object(runner,'Results',side_effect=PermissionError('read-only cache')):
            code,result=invoke();assert code==0 and result['cached']==0
        data.write_text('one')
        with patch.object(Results,'save',side_effect=OSError('cache write failed')):
            code,result=invoke();assert code==0 and result['cached']==0
        code,result=invoke();assert code==0 and result['cached']==0
        code,result=invoke();assert code==0 and result['cached']==1
        # A fresh failure must also revoke the earlier pass, even if old inputs
        # are subsequently restored (for example a flaky external condition).
        data.write_text('bad')
        code,result=invoke(True);assert code==1 and result['cached']==0
        data.write_text('one')
        code,result=invoke();assert code==0 and result['cached']==0
    print('PASS: real worker/CLI executes cold, labels warm hits, reruns changed inputs and revokes old cached passes after a forced fresh failure')


if __name__=='__main__':
    check_observed_inputs()
    check_failure_and_uncertainty()
    check_end_to_end_cache()
