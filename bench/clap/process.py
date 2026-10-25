"""Times a completion answered from process start: ensign's bench/complete
against clap's CompleteEnv in this crate, alternating runs. By hand:
python3 -I bench/clap/process.py zig-out/bench/complete bench/clap/target/release/ensign-bench-clap"""
import os, subprocess, sys, time, statistics
z, c = sys.argv[1], sys.argv[2]
ez = dict(os.environ, ENSIGN_COMPLETE="1:checkout:--branch")
ec = dict(os.environ, COMPLETE="bash", _CLAP_COMPLETE_INDEX="5", _CLAP_COMPLETE_COMP_TYPE="9", _CLAP_COMPLETE_SPACE="true", _CLAP_IFS="\n")
az = [z, "-v", "checkout", "--force", "--branch", "ma"]
ac = [c, "--", "git", "-v", "checkout", "--force", "--branch", "ma"]
tz, tc = [], []
for i in range(600):
    for argv, env, out in ((az, ez, tz), (ac, ec, tc)):
        t = time.perf_counter_ns(); subprocess.run(argv, env=env, stdout=subprocess.DEVNULL, check=True); out.append(time.perf_counter_ns() - t)
for name, t in (("ensign", tz), ("clap", tc)):
    t = t[100:]
    print(f'{{"row":"complete/process {name}","unit":"answer","median_us":{statistics.median(t)/1000:.1f},"best_us":{min(t)/1000:.1f}}}')
