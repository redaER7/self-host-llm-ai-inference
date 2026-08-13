import asyncio, aiohttp, json, random, time, statistics, argparse

MODEL_7B = "Qwen/Qwen2.5-7B-Instruct-AWQ"
MODEL_14B = "Qwen/Qwen2.5-14B-Instruct-AWQ"
URL = "https://llm.yacodata.com/v1/chat/completions"

PROMPTS = [
    "Compute the Fourier transform of f(x)=e^{-⟨Ax,x⟩} for A∈C^{n×n}, Re A positive definite.",
    "Prove the Paley-Wiener characterization of FE'(B(0,R))(Rⁿ).",
    "A belt-driven wheel radius 30 cm spins at 300 rpm. Find angular velocity and belt speed.",
    "Wind turbine with 30m blades spins at 22 rpm. Find angular velocity and blade tip tangential velocity.",
    "Compute complex Fourier coefficients of a 2π-periodic rectangular pulse f(x)=1 for |x|<δ, 0 for δ≤|x|≤π.",
    "Analyze the Gibbs phenomenon for a square wave — show the overshoot approaches ≈8.9% as N→∞.",
    "A laboratory cart (500g) rests on a level track, connected to a lead weight (100g) suspended vertically off a pulley. Find the acceleration assuming negligible friction.",
    "If the Fourier transform F : Lᵖ(Rⁿ) → Lᵠ(Rⁿ) is continuous, prove that 1≤p≤2 and 1/q+1/p=1.",
    "Show that if f : R→C extends to a holomorphic function on a strip with an integrable bound, then its Fourier transform decays exponentially.",
    "Let A consist of functions holomorphic in a strip with certain growth conditions. Show that the Fourier transform maps A onto entire functions with exponential decay.",
    "Recall the proof that if f ∈ L¹(Rⁿ) then its Fourier transform f̂ ∈ C₀(Rⁿ). Sketch the key steps: density of Schwartz functions, uniform continuity, and the Riemann-Lebesgue lemma.",
    "Give two proofs that FL¹ ≠ C₀: (1) For odd f̂ ∈ L¹ show |∫₁ᵇ f̂(x)/x dx| ≤ A uniformly, then prove g(x)=tanh(x)/log(1+|x|) ∈ C₀\\FL¹. (2) Show (L¹,*) is a Banach algebra but not C*-algebra, while (C₀,·) is a C*-algebra.",
    "Derive the Euler-Lagrange equations for a functional of the form J[y] = ∫ F(x, y, y') dx with fixed endpoints.",
    "Compute the singular value decomposition of the matrix A = [[1, 2], [2, 1], [3, 4]].",
    "A particle moving in a central potential V(r) = -k/r has angular momentum L. Derive the effective potential and find conditions for circular orbits.",
    "Prove the spectral theorem for compact self-adjoint operators on a Hilbert space.",
    "Show that the alternating harmonic series ∑_{n=1}^{∞} (-1)^{n+1}/n converges to ln(2) and estimate the error after N terms.",
    "Using the method of characteristics, solve the PDE: u_x + x u_y = 0 with u(0, y) = y².",
    "Let f(x)=∑_{n=1}^{∞} sin(nx)/n². Determine if f is continuous, differentiable, and compute its Fourier series.",
    "Prove using the intermediate value property that every continuous function on a closed bounded interval attains its maximum and minimum.",
    "Write a Python function that finds all prime factorizations of a given integer and returns them as a dictionary {factor: exponent}.",
    "Design a distributed rate limiter using a sliding window algorithm. Describe the data structures, API, and trade-offs for single-node vs multi-node deployment.",
    "Compute the surface area of the portion of the paraboloid z = x² + y² that lies inside the sphere x² + y² + z² = 2.",
    "Write the opening paragraph of a noir detective novel set in a rain-soaked megacity in 2087, where memories can be bought and sold on the black market.",
    "Five houses in a row are painted different colors. Each owner has a different nationality, pet, drink, and car. Given these clues: The Brit lives in the red house. The Swede has dogs. The Dane drinks tea. The green house is immediately left of the white. The green house owner drinks coffee. The person with a BMW has birds. The yellow house owner drives a Volvo. The middle house owner drinks milk. The Norwegian lives in the first house. The person who drives a Honda lives next to the cat owner. The person with horses lives next to the Volvo driver. The Toyota driver drinks beer. The German drives a Mercedes. The Honda driver lives next to the blue house. The Norwegian lives next to the blue house. Determine who owns the fish.",
    "Find and fix all bugs in this Python code: def merge_sort(arr):\\n  if len(arr) <= 1: return arr\\n  mid = len(arr) // 2\\n  left = merge_sort(arr[:mid])\\n  right = merge_sort(arr[mid:])\\n  result = []\\n  i = j = 0\\n  while i < len(left) and j < len(right):\\n    if left[i] <= right[j]:\\n      result.append(left[i])\\n    else:\\n      result.append(right[j])\\n    i += 1\\n    j += 1\\n  result += left[i:]\\n  return result",
    "Write a step-by-step tutorial explaining how to implement a transformer attention mechanism from scratch in PyTorch, including multi-head attention, positional encoding, and layer normalization. Include code snippets.",
    "Return a JSON object describing the top 5 most complex programming languages by feature count, with fields: name, year_created, paradigms (array), typing_system, notable_feature.",
    "A fair six-sided die is rolled repeatedly. What is the expected number of rolls needed to see each face at least once? Derive the exact expression and compute the numerical answer.",
    "Given an adjacency list representation of a weighted directed graph, implement Dijkstra's algorithm in Python that returns the shortest distance from a source node to all other nodes. Handle negative edge weights by raising an appropriate error. Include test cases.",
]


def percentile(data, p):
    if not data:
        return 0
    s = sorted(data)
    k = max(0, min(len(s) - 1, int(len(s) * p / 100)))
    return s[k]


def fmt_pct(data):
    if not data:
        return "  —"
    return f"min {min(data):.1f}s  p50 {percentile(data, 50):.1f}s  p95 {percentile(data, 95):.1f}s  max {max(data):.1f}s"


async def send_request(session, idx, payload, model_label):
    start = time.monotonic()
    try:
        headers = {"x-ai-eg-model": payload["model"]}
        async with session.post(URL, json=payload, headers=headers) as resp:
            body = await resp.json()
            elapsed = time.monotonic() - start
            usage = body.get("usage", {})
            tokens = usage.get("completion_tokens", 0)
            return {
                "idx": idx,
                "model": model_label,
                "max_tokens": payload["max_tokens"],
                "duration": elapsed,
                "tokens": tokens,
                "tok_s": tokens / elapsed if elapsed > 0 and tokens else 0,
                "status": resp.status,
                "error": None,
            }
    except Exception as e:
        elapsed = time.monotonic() - start
        return {
            "idx": idx,
            "model": model_label,
            "max_tokens": payload["max_tokens"],
            "duration": elapsed,
            "tokens": 0,
            "tok_s": 0,
            "status": 0,
            "error": str(e),
        }


async def send_streaming_ttft(session, idx, payload, model_label):
    start = time.monotonic()
    try:
        headers = {"x-ai-eg-model": payload["model"]}
        p = {**payload, "stream": True}
        async with session.post(URL, json=p, headers=headers) as resp:
            ttft = None
            while True:
                line = await resp.content.readline()
                if not line:
                    break
                line = line.strip()
                if line.startswith(b"data: [DONE]"):
                    break
                if line.startswith(b"data: "):
                    if ttft is None:
                        ttft = time.monotonic() - start
                    break
            return {
                "idx": idx,
                "model": model_label,
                "ttft": ttft,
                "status": resp.status,
                "error": None,
            }
    except Exception as e:
        return {
            "idx": idx,
            "model": model_label,
            "ttft": None,
            "status": 0,
            "error": str(e),
        }


async def main():
    parser = argparse.ArgumentParser(description="Case Gamma concurrent benchmark (7B + 14B)")
    parser.add_argument("--concurrency", type=int, default=10, help="requests per model")
    parser.add_argument("--ttft-count", type=int, default=5, help="TTFT probes per model")
    parser.add_argument("--min-tokens", type=int, default=300)
    parser.add_argument("--max-tokens", type=int, default=1500)
    args = parser.parse_args()

    concurrency = args.concurrency
    ttft_count = args.ttft_count
    models = [("7B", MODEL_7B), ("14B", MODEL_14B)]

    timeout = aiohttp.ClientTimeout(total=600)
    connector = aiohttp.TCPConnector(limit=max(concurrency, ttft_count) * 2)

    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        print("=== Case Gamma Concurrent Benchmark ===")
        print(f"Models: Qwen 7B (2g.10gb MIG) + Qwen 14B (3g.20gb MIG)")
        print(f"URL: {URL}")
        print(f"Concurrency: {concurrency} per model | TTFT probes: {ttft_count} per model")
        print(f"max_tokens: {args.min_tokens}–{args.max_tokens}")
        print()

        # ── TTFT (streaming) ──
        print("─ TTFT (streaming) ─────────────────────────────────────────────")
        ttft_tasks = []
        ttft_idx = 0
        for label, model in models:
            for i in range(ttft_count):
                ttft_idx += 1
                payload = {
                    "model": model,
                    "messages": [{"role": "user", "content": PROMPTS[ttft_idx % len(PROMPTS)]}],
                    "max_tokens": random.randint(args.min_tokens, args.max_tokens),
                }
                ttft_tasks.append(send_streaming_ttft(session, ttft_idx, payload, label))

        ttft_results = await asyncio.gather(*ttft_tasks)

        ttft_by_model = {"7B": [], "14B": []}
        for r in ttft_results:
            label = r["model"]
            if r["ttft"] and r["status"] == 200:
                s = f"{r['ttft']:.2f}s"
                ttft_by_model[label].append(r["ttft"])
            else:
                s = f"ERR({r.get('error', r['status'])})"
            print(f"  #{r['idx']:>2}  [{label:>3}]  TTFT = {s}")

        print()
        for label in ["7B", "14B"]:
            vals = ttft_by_model[label]
            print(f"  [{label}] TTFT: {fmt_pct(vals)}")
        print()

        # ── Throughput (non-streaming) ──
        print("─ Throughput (non-streaming) ──────────────────────────────────")
        tasks = []
        req_idx = 0
        for label, model in models:
            for i in range(concurrency):
                req_idx += 1
                payload = {
                    "model": model,
                    "messages": [{"role": "user", "content": PROMPTS[req_idx % len(PROMPTS)]}],
                    "max_tokens": random.randint(args.min_tokens, args.max_tokens),
                }
                tasks.append(send_request(session, req_idx, payload, label))

        results = await asyncio.gather(*tasks)

        header = f"{'#':>2}  {'model':>4}  {'max_tok':>7}  {'duration':>8}  {'tokens':>6}  {'tok/s':>8}  {'status':>6}"
        sep = "─" * len(header)
        print(header)
        print(sep)

        by_model = {"7B": {"durations": [], "tok_rates": [], "tok_counts": [], "errors": 0},
                    "14B": {"durations": [], "tok_rates": [], "tok_counts": [], "errors": 0}}
        all_ok = 0
        all_err = 0

        for r in sorted(results, key=lambda x: x["idx"]):
            label = r["model"]
            status_str = f"{r['status']}" if r["status"] == 200 else f"ERR({r['error']})"
            print(f"{r['idx']:>2}  {label:>4}  {r['max_tokens']:>7}  {r['duration']:>8.1f}s  {r['tokens']:>6}  {r['tok_s']:>8.1f}  {status_str:>6}")
            if r["status"] == 200:
                by_model[label]["durations"].append(r["duration"])
                by_model[label]["tok_rates"].append(r["tok_s"])
                by_model[label]["tok_counts"].append(r["tokens"])
                all_ok += 1
            else:
                by_model[label]["errors"] += 1
                all_err += 1

        # ── Summary ──
        print()
        print("─ Summary ──────────────────────────────────────────────────────")
        print(f"  Total: {all_ok}/{all_ok + all_err} success  |  {all_err} errors")
        print()

        for label in ["7B", "14B"]:
            m = by_model[label]
            n = len(m["durations"])
            total_req = n + m["errors"]
            if n == 0:
                print(f"  [{label}]  0/{total_req} success  — no successful requests")
                continue
            total_tokens = sum(m["tok_counts"])
            total_time = max(m["durations"])
            throughput_req = n / total_time
            throughput_tok = total_tokens / total_time
            print(f"  [{label}]  {n}/{total_req} success  |  {throughput_req:.1f} req/s  |  {throughput_tok:.0f} tok/s")
            print(f"         Latency:    {fmt_pct(m['durations'])}")
            print(f"         Tokens/req: min {min(m['tok_counts'])}  p50 {percentile(m['tok_counts'], 50):.0f}  p95 {percentile(m['tok_counts'], 95):.0f}  max {max(m['tok_counts'])}")
            print(f"         Tok/s:      min {min(m['tok_rates']):.1f}  p50 {percentile(m['tok_rates'], 50):.1f}  p95 {percentile(m['tok_rates'], 95):.1f}  max {max(m['tok_rates']):.1f}")
            print()

        # Combined
        all_durations = by_model["7B"]["durations"] + by_model["14B"]["durations"]
        all_tok_rates = by_model["7B"]["tok_rates"] + by_model["14B"]["tok_rates"]
        all_tok_counts = by_model["7B"]["tok_counts"] + by_model["14B"]["tok_counts"]
        if all_durations:
            total_time = max(all_durations)
            combined_req = len(all_durations) / total_time
            combined_tok = sum(all_tok_counts) / total_time
            print(f"  [All]  Combined: {all_ok}/{all_ok + all_err}  |  {combined_req:.1f} req/s  |  {combined_tok:.0f} tok/s")


if __name__ == "__main__":
    asyncio.run(main())
