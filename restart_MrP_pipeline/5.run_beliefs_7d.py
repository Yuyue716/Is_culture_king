"""Run the 7-day MrP pipeline (fit + prediction) for several beliefs, one after another.

Each belief runs `4.optimized_mrp_pilot_7d.py --stage all` in its own process, so an error
in one belief does not stop the others. Safe to stop (Ctrl+C, crash, reboot) and rerun
with the same command:
  - a verified fit is reused (the pipeline checks model, data and sampler settings);
  - completed prediction windows are skipped (signed window_done.ok markers);
  - a fit interrupted during sampling is moved to fit_incomplete_<time> and refitted
    (CmdStan cannot resume a half-finished run);
  - GQ scratch folders left by an interrupted window are deleted;
  - beliefs with belief_done.ok are skipped (use --recheck to verify them again);
  - a belief whose process crashes is resumed automatically up to BELIEF_RETRIES times.
Do NOT edit 4.optimized_mrp_pilot_7d.py between restarts: its source hash is part of the
prediction signature, so an edited script refuses to resume an existing prediction folder
(then use a new --prediction-subdir). Settings must also stay the same between restarts.
Run in PowerShell (8 chains by default on both laptops; predict-every becomes 20, still 400 draws):
  $env:PYTHONPATH="D:\\is_culture_king_scripts\\.venv\\Lib\\site-packages"
  D:\\cmdstan_conda\\micromamba.exe run -r D:\\cmdstan_conda\\root -p D:\\cmdstan_conda\\env <uv python.exe> D:\\is_culture_king_scripts\\restart_MrP_pipeline\\5.run_beliefs_7d.py --beliefs GRASS CC24_440a V241294x
Beliefs fitted earlier with 16 chains (GRASS, CC24_440a, V241294x, WRKWAYUP, ABANY, CAPPUN, AFFRMACT): pass `--chains 16` to reuse those fits.
Logs: D:\\mrp_7d_work\\<run-name>\\<belief>\\run_<time>.log, one line per run in D:\\mrp_7d_work\\<run-name>\\runs_log.csv.
"""
import argparse
import csv
import ctypes
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(os.path.dirname(os.path.abspath(__file__)))
PIPELINE = HERE / "4.optimized_mrp_pilot_7d.py"
# Same locations as 4.optimized_mrp_pilot_7d.py
GENERATED_DIR = Path(os.path.normpath(HERE / "../../Dropbox/is_culture_king/is_culture_king_Yuyue/generated_data"))
WORK_ROOT = Path(os.path.normpath(HERE / "../../mrp_7d_work"))
N_PREDICTION_DRAWS = 400
BELIEF_RETRIES = 3   # rerun a belief whose pipeline process crashed; the fit and finished windows are reused


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--beliefs", nargs="+", required=True, help="belief ids, e.g. GRASS CC24_440a V241294x")
    parser.add_argument("--run-name", default="td10_ad08_w1000_s1000")
    parser.add_argument("--prediction-subdir", default="predictions")
    parser.add_argument("--chains", type=int, default=8)
    parser.add_argument("--warmup", type=int, default=1000)
    parser.add_argument("--sampling", type=int, default=1000)
    parser.add_argument("--adapt-delta", type=float, default=0.8)
    parser.add_argument("--max-treedepth", type=int, default=10)
    parser.add_argument("--predict-every", type=int, default=None,
                        help=f"default: chains x sampling / {N_PREDICTION_DRAWS}, i.e. {N_PREDICTION_DRAWS} prediction draws")
    parser.add_argument("--max-windows", type=int, default=None, help="predict only the first N windows (testing)")
    parser.add_argument("--recheck", action="store_true", help="rerun beliefs that already have belief_done.ok")
    parser.add_argument("--status", action="store_true", help="only print the resume overview, run nothing")
    args = parser.parse_args()
    if args.predict_every is None:
        total = args.chains * args.sampling
        if total % N_PREDICTION_DRAWS:
            parser.error(f"chains x sampling = {total} is not a multiple of {N_PREDICTION_DRAWS}; set --predict-every.")
        args.predict_every = total // N_PREDICTION_DRAWS
    if len(set(args.beliefs)) != len(args.beliefs):
        parser.error("Each belief may be listed only once.")
    return args


def belief_paths(args, belief):
    base_dir = GENERATED_DIR / "mrp_7d" / args.run_name / belief
    work_dir = WORK_ROOT / args.run_name / belief
    return {
        "work_dir": work_dir,
        "fit_dir": work_dir / "fit",
        "fit_metadata": work_dir / "fit" / "fit_metadata.json",
        "prediction_dir": base_dir / args.prediction_subdir,
        "belief_done": base_dir / args.prediction_subdir / "belief_done.ok",
    }


def belief_status(paths):
    fit_dir = paths["fit_dir"]
    if paths["fit_metadata"].is_file():
        fit = "verified"
    elif fit_dir.is_dir() and any(fit_dir.iterdir()):
        fit = "incomplete (will be moved aside and refitted)"
    else:
        fit = "not started"
    windows = (len(list(paths["prediction_dir"].glob("*_stan_output/window_done.ok")))
               if paths["prediction_dir"].is_dir() else 0)
    return fit, windows, paths["belief_done"].is_file()


def clean_interrupted_state(paths):
    """Undo what an interrupted run leaves behind, without touching verified results."""
    fit_dir = paths["fit_dir"]
    if not paths["fit_metadata"].is_file() and fit_dir.is_dir() and any(fit_dir.iterdir()):
        target = fit_dir.with_name(f"fit_incomplete_{datetime.now():%Y%m%d_%H%M%S}")
        fit_dir.rename(target)
        print(f"  Moved an unfinished fit to {target} (delete it once you no longer need it).")
    for scratch in paths["work_dir"].glob("gq_*"):
        if scratch.is_dir():
            shutil.rmtree(scratch, ignore_errors=True)
            print(f"  Deleted leftover GQ scratch folder {scratch.name}")


def pipeline_command(args, belief):
    command = [
        sys.executable, "-u", str(PIPELINE), "--belief", belief, "--stage", "all",
        "--run-name", args.run_name, "--prediction-subdir", args.prediction_subdir,
        "--chains", str(args.chains), "--warmup", str(args.warmup), "--sampling", str(args.sampling),
        "--adapt-delta", str(args.adapt_delta), "--max-treedepth", str(args.max_treedepth),
        "--predict-every", str(args.predict_every),
    ]
    if args.max_windows is not None:
        command += ["--max-windows", str(args.max_windows)]
    return command


def run_logged(command, log_path):
    """Run the pipeline, echoing its output to the console and a log file."""
    env = dict(os.environ, PYTHONUNBUFFERED="1")
    with open(log_path, "a", encoding="utf-8", errors="replace") as log:
        log.write(f"# {datetime.now():%Y-%m-%d %H:%M:%S}  {' '.join(command)}\n")
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                                   text=True, encoding="utf-8", errors="replace", bufsize=1)
        try:
            for line in process.stdout:
                sys.stdout.write(line)
                log.write(line)
                log.flush()
            return process.wait()
        except KeyboardInterrupt:
            try:
                process.wait(timeout=60)   # Ctrl+C reaches the child too; let it stop
            except subprocess.TimeoutExpired:
                process.kill()
            raise


def keep_awake(on):
    """Stop Windows from sleeping while this runs (closing the lid can still suspend it)."""
    if os.name == "nt":
        ES_CONTINUOUS, ES_SYSTEM_REQUIRED = 0x80000000, 0x00000001
        ctypes.windll.kernel32.SetThreadExecutionState(ES_CONTINUOUS | (ES_SYSTEM_REQUIRED if on else 0))


def append_run_log(args, row):
    path = WORK_ROOT / args.run_name / "runs_log.csv"
    path.parent.mkdir(parents=True, exist_ok=True)
    new_file = not path.exists()
    with open(path, "a", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(row))
        if new_file:
            writer.writeheader()
        writer.writerow(row)


def main():
    args = parse_args()
    if not PIPELINE.is_file():
        sys.exit(f"Pipeline script not found: {PIPELINE}")
    print(f"Run {args.run_name}: {args.chains} chains x {args.warmup} warmup / {args.sampling} sampling, "
          f"adapt_delta {args.adapt_delta}, max_treedepth {args.max_treedepth}, predict-every {args.predict_every} "
          f"({args.chains * args.sampling // args.predict_every} prediction draws), outputs in '{args.prediction_subdir}'")
    print("\n===== Resume overview =====")
    for belief in args.beliefs:
        fit, windows, done = belief_status(belief_paths(args, belief))
        print(f"- {belief}: fit {fit}; {windows} windows done{'; COMPLETE' if done else ''}")
    print("===========================\n")
    if args.status:
        return

    results = {}
    keep_awake(True)
    try:
        for number, belief in enumerate(args.beliefs, start=1):
            paths = belief_paths(args, belief)
            print(f"\n######## [{number}/{len(args.beliefs)}] {belief}  ({datetime.now():%Y-%m-%d %H:%M}) ########")
            if paths["belief_done"].is_file() and not args.recheck:
                print("  Already complete (belief_done.ok); skipping. Use --recheck to verify it again.")
                results[belief] = "skipped (complete)"
                continue
            paths["work_dir"].mkdir(parents=True, exist_ok=True)
            clean_interrupted_state(paths)
            log_path = paths["work_dir"] / f"run_{datetime.now():%Y%m%d_%H%M%S}.log"
            started = time.time()
            status, code = "interrupted", None
            try:
                code = run_logged(pipeline_command(args, belief), log_path)
                for retry in range(1, BELIEF_RETRIES + 1):
                    if code == 0:
                        break
                    print(f"  {belief} exited with code {code}; resuming in 60 s (retry {retry}/{BELIEF_RETRIES})")
                    time.sleep(60)   # give Windows time to release memory from the crashed processes
                    clean_interrupted_state(paths)
                    code = run_logged(pipeline_command(args, belief), log_path)
                status = "done" if code == 0 and paths["belief_done"].is_file() else (
                    "partial" if code == 0 else "failed")
            finally:
                minutes = (time.time() - started) / 60
                results[belief] = f"{status} in {minutes:.0f} min (log {log_path})"
                append_run_log(args, {
                    "started": datetime.fromtimestamp(started).strftime("%Y-%m-%d %H:%M"),
                    "belief": belief, "status": status, "minutes": round(minutes, 1),
                    "return_code": code, "chains": args.chains, "sampling": args.sampling,
                    "predict_every": args.predict_every, "prediction_subdir": args.prediction_subdir,
                    "log": str(log_path),
                })
            print(f"  {belief}: {results[belief]}")
    except KeyboardInterrupt:
        print("\nStopped. Rerun the same command to resume; finished fits and windows are kept.")
    finally:
        keep_awake(False)
        print("\n===== Summary =====")
        for belief in args.beliefs:
            print(f"- {belief}: {results.get(belief, 'not run')}")
    if any(r.startswith(("failed", "partial", "interrupted")) for r in results.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
