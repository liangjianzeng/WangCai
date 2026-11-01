import sys, time
sys.path.insert(0, 'D:/llm/npu/ov')
import numpy as np
import openvino as ov
from openvino import opset13 as ops

# KV-sized f16 state: 2*8*2048*128*2B = 8.4 MB
SHAPE = [2, 8, 2048, 128]
DTYPE = ov.Type.f16

def time_infer(ir, out, n=50):
    ir.infer(list(ir.inputs.values()) if False else [np.zeros([1], np.float32)] * 0)  # noop guard
    return None

def bench_param():
    x = ops.parameter(SHAPE, DTYPE, 'x')
    out = ops.add(x, np.array(1.0, np.float16))
    r = ops.result(out, 'r')
    m = ov.Model([r], [x], 'param')
    cm = ov.Core().compile_model(m, 'NPU')
    ir = cm.create_infer_request()
    x1 = np.ones(SHAPE, np.float16)
    t = ir.infer([x1]); vals = list(t.values())
    t0 = time.perf_counter()
    for _ in range(50): ir.infer([x1])
    dt = (time.perf_counter() - t0) / 50 * 1000
    return dt

def bench_state():
    init = ops.parameter(SHAPE, DTYPE, 'init')
    s = ops.read_value(init, 'kv')
    out = ops.add(s, np.array(1.0, np.float16))
    assign = ops.assign(out, 'kv')
    r = ops.result(out, 'r')
    m = ov.Model([r], [assign], [init], "stateful")
    cm = ov.Core().compile_model(m, 'NPU')
    ir = cm.create_infer_request()
    [setattr(st, 'state', ov.Tensor(DTYPE, SHAPE)) for st in ir.query_state() if st.name == 'kv']
    ir.infer([np.ones(SHAPE, np.float16)])
    # steady state: no input binding at all
    t0 = time.perf_counter()
    for _ in range(50): ir.infer()
    dt = (time.perf_counter() - t0) / 50 * 1000
    return dt

for name, fn in [('param (bind 8.4MB/step)', bench_param), ('state (device-resident) ', bench_state)]:
    try:
        print(f'{name}: {fn():.2f} ms/step')
    except Exception as e:
        print(f'{name}: FAIL {type(e).__name__}: {str(e)[-200:]}')
