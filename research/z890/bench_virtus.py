"""Before/after unlock comparison for the Z890 port: dense GEMM, then real LoRA steps through Virtus Create's learn.py.

Run with llm-create's .venv:
  python bench_virtus.py <label> <path to llm-create> <model GGUF or folder> [--four-bits]
Same fixed examples and settings every run; results go to bench-results/<label>.json beside this file.
"""
import argparse
import json
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

GEMM_N = 8192
GEMM_RUNS = 30
STEPS = 30
SETTINGS = {"four_bits": False, "rank": 16, "alpha": 32, "dropout": 0.05, "batch": 8, "passes": 1, "rate": 0.0001,
            "warmup": 2, "longest_example": 1024}


def gpu_state() -> dict:
    fields = "power.draw,power.limit,clocks.sm,clocks.mem,temperature.gpu,memory.used"
    row = subprocess.run(["nvidia-smi", f"--query-gpu={fields}", "--format=csv,noheader,nounits"],
                         capture_output=True, text=True, check=True).stdout.strip()
    return dict(zip(fields.split(","), (float(v) for v in row.split(", "))))


def gemm(torch) -> dict:
    out = {}
    for name, dtype in (("BF16", torch.bfloat16), ("FP16", torch.float16), ("FP32", torch.float32)):
        a = torch.randn(GEMM_N, GEMM_N, device="cuda", dtype=torch.float32).to(dtype)
        b = torch.randn(GEMM_N, GEMM_N, device="cuda", dtype=torch.float32).to(dtype)
        for _ in range(3):
            torch.matmul(a, b)
        torch.cuda.synchronize()
        times = []
        for _ in range(GEMM_RUNS):
            start = time.perf_counter()
            torch.matmul(a, b)
            torch.cuda.synchronize()
            times.append(time.perf_counter() - start)
        tflops = 2 * GEMM_N ** 3 / statistics.median(times) / 1e12
        out[name] = round(tflops, 2)
        print(f"GEMM {name} {GEMM_N}: {tflops:.2f} TFLOPS (median of {GEMM_RUNS}) {gpu_state()}", flush=True)
        del a, b
        torch.cuda.empty_cache()
    return out


def pairs(steps: int) -> list:
    """Fixed examples shaped like Virtus's: a system line, a short question, an answer of about 100 tokens."""
    answer = ("Para resolverlo, primero sumamos las cantidades conocidas y después restamos lo que ya se ha gastado. "
              "Si cada caja contiene doce unidades y hay siete cajas, tenemos ochenta y cuatro unidades en total. "
              "Quitando las veintinueve vendidas quedan cincuenta y cinco, y esa es la respuesta final: 55.")
    return [([{"role": "system", "content": "Virtus: on\nSolve the problem step by step and end with the final number."},
              {"role": "user", "content": f"Problema {i}: una tienda tiene cajas con unidades; ¿cuántas quedan al final del día {i}?"}],
             answer) for i in range(steps * SETTINGS["batch"])]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("label")
    parser.add_argument("project")
    parser.add_argument("model")
    parser.add_argument("--four-bits", action="store_true")
    parser.add_argument("--max-vram-gb", type=float, default=21.0)
    parser.add_argument("--steps", type=int, default=STEPS)
    args = parser.parse_args()
    import torch
    sys.path.insert(0, str(Path(args.project) / "virtus" / "scripts"))
    # A hard cap for the whole process: past the card's real room Windows spills to system memory and steps crawl.
    torch.cuda.set_per_process_memory_fraction(args.max_vram_gb * 2**30 / torch.cuda.get_device_properties(0).total_memory, 0)
    result = {"label": args.label, "torch": torch.__version__, "max_vram_gb": args.max_vram_gb, "idle": gpu_state(), "gemm": gemm(torch)}

    from answering import Local
    from learn import learn
    if args.four_bits:
        # peft's helper casts every frozen 16-bit layer to float32, 4.74 GiB more at once on Qwen3.8-27B: past the cap.
        # Same preparation without that cast, for this benchmark only; learn.py itself is left as it is.
        import peft

        def keep_16_bits(base, use_gradient_checkpointing=True, gradient_checkpointing_kwargs=None):
            for parameter in base.parameters():
                parameter.requires_grad = False
            base.gradient_checkpointing_enable()
            base.enable_input_require_grads()
            return base

        peft.prepare_model_for_kbit_training = keep_16_bits
        result["kbit_fp32_cast"] = False
    started = time.perf_counter()
    model = Local(args.model, args.four_bits, None, args.max_vram_gb, False)
    result["load_seconds"] = round(time.perf_counter() - started, 1)
    print(f"model loaded in {result['load_seconds']} s", flush=True)

    marks = []

    def log(line: str) -> None:
        print(line, flush=True)
        if line.startswith("step "):
            marks.append((int(line.split()[1].split("/")[0].replace(",", "")), time.perf_counter(), gpu_state()))

    settings = dict(SETTINGS, four_bits=args.four_bits)
    with tempfile.TemporaryDirectory() as folder:
        learn(model, pairs(args.steps), settings, folder, log)
    # The first ten steps warm up; steps 10 to 30 are the measure.
    first = next(m for m in marks if m[0] >= 10)
    last = marks[-1]
    seconds = (last[1] - first[1]) / (last[0] - first[0])
    result.update(model=args.model, four_bits=args.four_bits, settings=settings, seconds_a_step=round(seconds, 3), gpu_training=last[2])
    print(f"LoRA: {seconds:.3f} s/step over steps {first[0]}-{last[0]} {last[2]}", flush=True)
    out = Path(__file__).parent / "bench-results" / f"{args.label}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"saved {out}", flush=True)


if __name__ == "__main__":
    main()
