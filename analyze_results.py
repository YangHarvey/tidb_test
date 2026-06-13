#!/usr/bin/env python3
"""分析 sysbench 测试结果，输出 markdown 表格和图表"""
import os
import sys
from pathlib import Path
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick

RESULT_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("results/20260612_200150")
SUMMARY = RESULT_DIR / "summary.tsv"
OUT_DIR = RESULT_DIR / "analysis"
OUT_DIR.mkdir(exist_ok=True)

# 读取数据
df = pd.read_csv(SUMMARY, sep="\t")
df["threads"] = df["threads"].astype(int)
for col in ["qps", "tps", "p95_ms", "p99_ms_approx"]:
    df[col] = pd.to_numeric(df[col], errors="coerce")

workloads = list(df["workload"].drop_duplicates())
threads_order = sorted(int(x) for x in df["threads"].unique())

# ===== 1) 输出 markdown 表格 =====
md_lines = ["# TiDB X Sysbench 测试结果报告\n",
            f"测试目录: `{RESULT_DIR}`  ",
            f"线程档位: {threads_order}  ",
            f"负载类型: {len(workloads)} 种\n"]

for w in workloads:
    sub = df[df["workload"] == w].sort_values("threads")
    md_lines.append(f"\n## {w}\n")
    md_lines.append("| 线程数 | QPS | TPS | P95 (ms) | P99~ (ms) |")
    md_lines.append("|------:|----:|----:|---------:|----------:|")
    for _, r in sub.iterrows():
        md_lines.append(f"| {int(r.threads)} | {r.qps:,.2f} | {r.tps:,.2f} | {r.p95_ms:,.2f} | {r.p99_ms_approx:,.2f} |")
    # 峰值标记
    peak = sub.loc[sub["qps"].idxmax()]
    md_lines.append(f"\n**峰值**: {peak.qps:,.0f} QPS @ {int(peak.threads)} 线程, P95={peak.p95_ms:.1f} ms")

# 总览
md_lines.append("\n## 总览：每个负载的峰值 QPS\n")
md_lines.append("| 负载 | 峰值 QPS | 最佳线程数 | 对应 P95 (ms) | 对应 P99~ (ms) |")
md_lines.append("|------|--------:|----------:|--------------:|----------------:|")
for w in workloads:
    sub = df[df["workload"] == w]
    peak = sub.loc[sub["qps"].idxmax()]
    md_lines.append(f"| {w} | {peak.qps:,.0f} | {int(peak.threads)} | {peak.p95_ms:.1f} | {peak.p99_ms_approx:.1f} |")

md_text = "\n".join(md_lines)
(OUT_DIR / "report.md").write_text(md_text)
print(f"[OK] Markdown report -> {OUT_DIR / 'report.md'}")

# ===== 2) 绘图 =====
plt.rcParams["figure.dpi"] = 120
plt.rcParams["axes.grid"] = True
plt.rcParams["grid.alpha"] = 0.3

# 颜色映射
colors = plt.cm.tab10.colors
color_map = {w: colors[i % len(colors)] for i, w in enumerate(workloads)}

def plot_metric(metric, ylabel, title, fname, logy=False):
    fig, ax = plt.subplots(figsize=(10, 6))
    for w in workloads:
        sub = df[df["workload"] == w].sort_values("threads")
        ax.plot(sub["threads"], sub[metric], marker="o", label=w, color=color_map[w], linewidth=2)
    ax.set_xscale("log", base=2)
    if logy:
        ax.set_yscale("log")
    ax.set_xticks(threads_order)
    ax.set_xticklabels(threads_order)
    ax.set_xlabel("Threads (log2)")
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.legend(loc="best", fontsize=9)
    ax.grid(True, which="both", alpha=0.3)
    fig.tight_layout()
    fig.savefig(OUT_DIR / fname)
    plt.close(fig)
    print(f"[OK] {fname}")

plot_metric("qps", "QPS", "QPS vs Threads", "qps_vs_threads.png")
plot_metric("qps", "QPS (log)", "QPS vs Threads (log scale)", "qps_vs_threads_log.png", logy=True)
plot_metric("p95_ms", "P95 Latency (ms)", "P95 Latency vs Threads", "p95_vs_threads.png", logy=True)
plot_metric("p99_ms_approx", "P99 Latency ~ (ms)", "P99 Latency vs Threads", "p99_vs_threads.png", logy=True)

# 每个负载单独画一张 QPS+P95 双轴
for w in workloads:
    sub = df[df["workload"] == w].sort_values("threads")
    fig, ax1 = plt.subplots(figsize=(9, 5))
    ax1.plot(sub["threads"], sub["qps"], marker="o", color="tab:blue", label="QPS", linewidth=2)
    ax1.set_xscale("log", base=2)
    ax1.set_xticks(threads_order); ax1.set_xticklabels(threads_order)
    ax1.set_xlabel("Threads")
    ax1.set_ylabel("QPS", color="tab:blue")
    ax1.tick_params(axis="y", labelcolor="tab:blue")
    ax2 = ax1.twinx()
    ax2.plot(sub["threads"], sub["p95_ms"], marker="s", color="tab:red", label="P95 ms", linewidth=2, linestyle="--")
    ax2.set_yscale("log")
    ax2.set_ylabel("P95 Latency (ms, log)", color="tab:red")
    ax2.tick_params(axis="y", labelcolor="tab:red")
    fig.suptitle(f"{w}: QPS & P95 Latency")
    fig.tight_layout()
    fig.savefig(OUT_DIR / f"{w}_qps_p95.png")
    plt.close(fig)
    print(f"[OK] {w}_qps_p95.png")

print(f"\nAll outputs in: {OUT_DIR}")
