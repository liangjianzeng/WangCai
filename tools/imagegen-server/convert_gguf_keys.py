# -*- coding: utf-8 -*-
"""ComfyUI 系 GGUF → diffusers 键名 GGUF（一次性转换，幂等缓存）。

背景（2026-11-13 实案，unsloth Qwen-Image-2.1-Turbo Q5_K_M）：
- diffusers(0.43-dev) 对 QwenImage21 **没有** from_single_file 的 GGUF 实现
  （直接喂 ComfyUI gguf 报 "Unable to load weights"，装 gguf 包后报形状爆炸）；
- 官方成熟路径是 `from_pretrained` + `GGUFQuantizationConfig` 消费 **.gguf 文件**
  （model_loading_utils.load_state_dict 按后缀分派 → load_gguf_checkpoint →
  GGUFParameter(quant_type) → GGUFLinear 按需 dequant，city96 生态同款）；
- 该路径不剥 `model.diffusion_model.` 前缀 → 本脚本把 ComfyUI 系 gguf 重写为
  diffusers 键名的新 gguf。**量化块 raw 数据原样搬运（零解压零精度损失）**，
  只改键名与容器头，产物体积与源文件相同。

用法：
    python convert_gguf_keys.py <in.gguf> [out.gguf]
默认 out = <stem>.diffusers.gguf（同目录）；已存在直接复用（幂等缓存）。

server.py 加载侧（QI_DIT_GGUF 分支）自动调用本模块的 convert_gguf_keys：
首启转换一次（5.4GB 约 1-2 分钟，纯 IO），此后起服秒过。
"""
import os
import sys

_PREFIXES = ("model.diffusion_model.",)


def convert_gguf_keys(in_path: str, out_path: str | None = None) -> str:
    """剥 ComfyUI 前缀重写 GGUF；返回转换产物路径（幂等）。"""
    import gguf

    in_path = os.path.abspath(in_path)
    out_path = out_path or os.path.splitext(in_path)[0] + ".diffusers.gguf"
    if os.path.exists(out_path) and os.path.getsize(out_path) > 1_000_000:
        print(f"[convert] 缓存命中：{out_path}")
        return out_path
    if os.path.exists(out_path):  # 残骸（中途炸掉的空壳）→ 推倒重写
        os.remove(out_path)

    reader = gguf.GGUFReader(in_path)
    arch = "qwen_image"
    f = reader.fields.get("general.architecture")
    if f is not None:
        try:
            arch = bytes(f.parts[f.data[0]]).decode("utf-8", "replace").strip("\x00") or arch
        except Exception:
            pass

    import numpy as np
    n = 0
    # gguf>=0.19 的 GGUFWriter 是显式状态机（NO_FILE→EMPTY→HEADER→KV→TI→…）：
    # add_tensor 只能在 open_output_file **之前**（内存缓存），随后按序
    # open_output_file → write_header/kv/ti/tensors_to_file → close 落盘；
    # 裸 close() 只关文件不写盘（0 字节空壳实锤）。
    writer = gguf.GGUFWriter(out_path, arch=arch)
    for t in reader.tensors:
        name = t.name
        for p in _PREFIXES:
            if name.startswith(p):
                name = name[len(p):]
                break
        # raw 量化块原样搬运（零解压）。writer 的 raw_shape 约定是
        # **字节形状**（add_tensor_info 内 quant_shape_from_byte_shape 换算
        # 回逻辑维度写 ne）——统一给 data 的 uint8 视图形状：F32/BF16/
        # K-quant 三类换算后均与源文件 ne 一致（已逐类型对账）。
        raw_bytes_shape = t.data.view(np.uint8).shape
        writer.add_tensor(name, t.data,
                          raw_shape=tuple(int(x) for x in raw_bytes_shape),
                          raw_dtype=t.tensor_type)
        n += 1
    writer.open_output_file()
    writer.write_header_to_file()
    writer.write_kv_data_to_file()
    # write_tensors_to_file 内部自带 write_ti_data_to_file（手动调会撞状态机
    # "Expected ... got TI_DATA" 实锤）——TI + 张量数据一步到位。
    writer.write_tensors_to_file()
    writer.close()
    print(f"[convert] {n} tensors → {out_path}")
    return out_path


if __name__ == "__main__":
    convert_gguf_keys(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
