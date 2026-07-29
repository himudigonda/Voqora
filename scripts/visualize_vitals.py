import json
import os


def draw_mini_bar(val, max_val, width=15):
    if max_val == 0:
        return "░" * width
    filled = int((val / max_val) * width)
    return "█" * filled + "░" * (width - filled)


def color_text(text, color_code):
    return f"\033[{color_code}m{text}\033[0m"


def print_dashboard():
    results_path = "backend/benchmarks/results.json"
    if not os.path.exists(results_path):
        print(f"❌ Error: {results_path} not found. Run benchmark first.")
        return

    with open(results_path, "r") as f:
        data = json.load(f)

    print("\n" + "╔" + "═" * 78 + "╗")
    print("║" + " " * 23 + "VOQORA SCENARIO MATRIX REPORT" + " " * 24 + "║")
    print("╚" + "═" * 78 + "╝")

    # Header
    head = f"{'Scenario':<15} | {'TTFA':<8} | {'RTF':<7} | {'Speed':<8} | {'RAM':<8} | {'Samples'}"
    print(color_text(head, "1;36"))
    print("-" * 80)

    max_ttfa = max(r["ttfa"] for r in data) if data else 1
    max_speed = max(r["throughput_x"] for r in data) if data else 1

    for r in data:
        name = r["scenario"][:15]
        ttfa_val = r["ttfa"]
        ttfa = f"{ttfa_val:>6.1f}ms"
        rtf = f"{r['rtf']:>6.3f}"
        speed_val = r["throughput_x"]
        speed = f"{speed_val:>5.1f}x"
        ram = f"{int(r['mem_peak'])}MB"

        # Color coding for TTFA
        c_code = "32"  # Green
        if ttfa_val > 400:
            c_code = "33"  # Yellow
        if ttfa_val > 800:
            c_code = "31"  # Red

        ttfa_colored = color_text(ttfa, c_code)
        speed_bar = draw_mini_bar(speed_val, max_speed)

        print(f"{name:<15} | {ttfa_colored} | {rtf} | {speed} | {ram:<8} | {speed_bar}")

    print("\n" + color_text("[ TREND ANALYSIS ]", "1;35"))

    # Calculate Trends
    short_rtf = [r["rtf"] for r in data if "Short" in r["scenario"]]
    long_rtf = [r["rtf"] for r in data if "Long" in r["scenario"]]

    if short_rtf and long_rtf:
        efficiency_gain = (
            (sum(short_rtf) / len(short_rtf)) - (sum(long_rtf) / len(long_rtf))
        ) * 100
        print(
            f"• Efficiency Trend:   Longer sentences improve RTF by {efficiency_gain:.1f}%"
        )

    many_ttfa = [r["ttfa"] for r in data if "Many" in r["scenario"]]
    few_ttfa = [r["ttfa"] for r in data if "Few" in r["scenario"]]

    if many_ttfa and few_ttfa:
        overhead = max(many_ttfa) - min(few_ttfa)
        print(
            f"• Parallel Overhead:  Many sentences add ~{overhead:.1f}ms initial scheduling lag."
        )

    print("=" * 80 + "\n")


if __name__ == "__main__":
    print_dashboard()
