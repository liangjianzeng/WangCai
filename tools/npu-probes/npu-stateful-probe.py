import sys
sys.path.insert(0, 'D:/llm/npu/ov')
import numpy as np
import openvino as ov
from openvino import opset13 as ops

x = ops.parameter([1, 4], ov.Type.f32, 'x')
state = ops.read_value(x, 'kv')
out = ops.add(state, x)
assign = ops.assign(out, 'kv')
r1 = ops.result(out, 'res')
r2 = ops.result(assign.output(0), 'sink')
model = ov.Model([r1], [assign], [x], "probe_stateful")

for dev in ['NPU', 'CPU']:
    try:
        core = ov.Core()
        cm = core.compile_model(model, dev)
        states = list(cm.query_state())
        print(f'{dev}: states={len(states)}', [s.name for s in states])
        ir = cm.create_infer_request()
        x1 = np.ones((1, 4), np.float32)
        res = ir.infer([x1])
        o1 = list(res.values())[0]
        o2 = list(ir.infer([x1]).values())[0]
        print(f'{dev}: out1={np.asarray(o1).flatten().tolist()} out2={np.asarray(o2).flatten().tolist()}')
    except Exception as e:
        print(f'{dev}: FAIL {type(e).__name__}: {str(e)[-250:]}')
