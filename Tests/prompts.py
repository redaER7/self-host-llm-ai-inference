MATH_PROMPTS = [
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
    "Give two proofs that F(L¹) ≠ C₀: (1) For odd f̂ ∈ L¹ show |∫₁ᵇ f̂(x)/x dx| ≤ A uniformly, then prove g(x)=tanh(x)/log(1+|x|) ∈ C₀ \\ F(L¹). (2) Show (L¹,*) is a Banach algebra but not C*-algebra, while (C₀,·) is a C*-algebra.",
    "Derive the Euler-Lagrange equations for a functional of the form J[y] = ∫ F(x, y, y') dx with fixed endpoints.",
    "Compute the singular value decomposition of the matrix A = [[1, 2], [2, 1], [3, 4]].",
    "A particle moving in a central potential V(r) = -k/r has angular momentum L. Derive the effective potential and find conditions for circular orbits.",
    "Prove the spectral theorem for compact self-adjoint operators on a Hilbert space.",
    "Show that the alternating harmonic series ∑_{n=1}^{∞} (-1)^{n+1}/n converges to ln(2) and estimate the error after N terms.",
    "Using the method of characteristics, solve the PDE: u_x + x u_y = 0 with u(0, y) = y².",
    "Let f(x)=∑_{n=1}^{∞} sin(nx)/n². Determine if f is continuous, differentiable, and compute its Fourier series.",
    "Prove using the intermediate value property that every continuous function on a closed bounded interval attains its maximum and minimum.",
]

CODE_PROMPTS = [
    "Write a Python function that computes the prime factorization of a given integer and returns it as a dictionary {factor: exponent}.",
    "Design a distributed rate limiter using a sliding window algorithm. Describe the data structures, API, and trade-offs for single-node vs multi-node deployment.",
    "Compute the surface area of the portion of the paraboloid z = x² + y² that lies inside the sphere x² + y² + z² = 2.",
    "Write the opening paragraph of a noir detective novel set in a rain-soaked megacity in 2087, where memories can be bought and sold on the black market.",
    "Find and fix the bug in this Python merge_sort: def merge_sort(arr): if len(arr) <= 1: return arr; mid = len(arr) // 2; left = merge_sort(arr[:mid]); right = merge_sort(arr[mid:]); result = []; i = j = 0; while i < len(left) and j < len(right): if left[i] <= right[j]: result.append(left[i]); i += 1; else: result.append(right[j]); j += 1; result += left[i:]; return result",
    "Write a step-by-step tutorial explaining how to implement a transformer attention mechanism from scratch in PyTorch, including multi-head attention, positional encoding, and layer normalization. Include code snippets.",
    "Return a JSON object describing the top 5 most complex programming languages by feature count, with fields: name, year_created, paradigms (array), typing_system, notable_feature.",
    "A fair six-sided die is rolled repeatedly. What is the expected number of rolls needed to see each face at least once? Derive the exact expression and compute the numerical answer.",
    "Given an adjacency list representation of a weighted directed graph, implement Dijkstra's algorithm in Python that returns the shortest distance from a source node to all other nodes. Handle negative edge weights by raising an appropriate error. Include test cases.",
]

BIOCHEM_PROMPTS = [
    "Explain the difference between competitive and non-competitive enzyme inhibition. Derive the Michaelis-Menten equation for each case and sketch the Lineweaver-Burk plots.",
    "Describe the CRISPR-Cas9 mechanism for gene editing. What are the off-target effects and how do high-fidelity Cas9 variants reduce them?",
    "Derive the Nernst equation for a galvanic cell at 25°C. Calculate the cell potential for a Daniell cell with [Zn²⁺]=0.1M and [Cu²⁺]=1.5M.",
    "Explain the Hardy-Weinberg principle. Under what conditions does a population deviate from equilibrium? Derive the expected genotype frequencies for a two-allele system.",
]

LAW_PROMPTS = [
    "A contract states: \"Seller shall deliver goods by March 1. Time is of the essence. Buyer's remedy for late delivery is limited to a pro-rata credit.\" The goods arrive March 15. Analyze whether the buyer can terminate the contract or is limited to the credit.",
    "Compare and contrast the legal tests for trade secret protection under the Defend Trade Secrets Act (US) and the EU Trade Secrets Directive. What are the key differences in scope and remedies?",
    "A software company includes a clickwrap EULA with a class-action waiver and mandatory arbitration clause. A user in the EU disputes this. Analyze enforceability under EU consumer protection law.",
]

FINANCE_PROMPTS = [
    "Derive the Black-Scholes European call option pricing formula. What assumptions does it make? How does the model fail in practice during market crashes?",
    "Explain the CAPM (Capital Asset Pricing Model). Derive the security market line. What are the known empirical anomalies that contradict CAPM?",
    "A company has EBITDA of $50M, net debt of $200M, and enterprise value of $800M. Calculate EV/EBITDA. If the sector average is 12x, is the company overvalued? What other multiples would you check?",
    "Derive the relationship between the Phillips curve and inflation expectations. Why did the 1970s stagflation invalidate the original Phillips curve trade-off?",
]

MEDICINE_PROMPTS = [
    "A 55-year-old male presents with chest pain radiating to the left arm, diaphoresis, and nausea. ECG shows ST elevation in leads II, III, aVF. What is the most likely diagnosis, the territory involved, and the immediate management pathway?",
    "Explain the mechanism of action of SSRIs vs SNRIs. Why does SSRI therapy take 4-6 weeks to reach full effect despite immediate serotonin reuptake inhibition?",
    "A patient on warfarin needs emergency surgery. INR is 4.5. Describe the reversal protocol, including the roles of vitamin K, FFP, and PCC. What are the time constraints?",
]

HISTORY_PROMPTS = [
    "Compare the causes and outcomes of the French Revolution (1789) and the Russian Revolution (1917). What structural factors did they share? Where did they diverge?",
    "Explain the Thucydides Trap. Apply it to at least two historical examples and assess whether it applies to current great-power competition.",
    "Analyze why the Weimar Republic failed. What institutional, economic, and social factors converged to enable the Nazi rise to power?",
]

PHILOSOPHY_PROMPTS = [
    "Present the trolley problem and its five main variants. For each variant, explain which ethical framework (utilitarian, deontological, virtue ethics) gives which answer and why.",
    "Explain the Ship of Theseus problem. How do four major philosophers (Heraclitus, Locke, Hume, Butler) address it? Which solution is most defensible and why?",
]

STATS_PROMPTS = [
    "Derive the maximum likelihood estimator for a normal distribution. Show that the MLE for variance is biased and derive the unbiased estimator.",
    "Explain the bias-variance tradeoff. Derive the expected prediction error decomposition for a regression problem. How does model complexity affect each component?",
    "Design an A/B test for a website button color change. Specify: sample size calculation (power=0.8, alpha=0.05), null hypothesis, expected effect size, duration, and how you handle multiple comparisons.",
    "Explain the difference between Type I and Type II errors. Derive the ROC curve. What is the relationship between the AUC and the Mann-Whitney U statistic?",
]

DEVOPS_PROMPTS = [
    "Explain the difference between a Kubernetes Deployment, StatefulSet, and DaemonSet. When would you use each? What happens during a rolling update with a Deployment vs a StatefulSet?",
    "A Docker image is 2.3GB. Describe a multi-stage build strategy to reduce it to under 200MB for a Python Flask app. What are the trade-offs of including a healthcheck in the image?",
    "Explain the CAP theorem. For a distributed key-value store, which two properties would you prioritize and why? How does this choice affect your replication strategy?",
    "Design a CI/CD pipeline for a microservices architecture with 12 services. Cover: build triggers, testing strategy, canary deployments, rollback mechanisms, and secret management.",
]

LINGUISTICS_PROMPTS = [
    "Explain the difference between analytic and synthetic languages. Give examples of each type and explain how agglutinative languages (e.g., Turkish, Finnish) differ from fusional languages (e.g., Russian, German).",
    "Translate the following English sentence into Japanese, French, and Arabic, preserving the formal register and subjunctive mood: \"The committee insisted that the report be submitted before the deadline.\"",
]

ENGINEERING_PROMPTS = [
    "A 30-story building uses a steel moment-resisting frame. Compare this to a braced frame and a shear wall system. Under what seismic conditions would you choose each? What are the trade-offs in cost, stiffness, and architectural flexibility?",
]

FACTUAL_PROMPTS = [
    "What is the speed of light in vacuum?",
    "Who painted the ceiling of the Sistine Chapel?",
    "What is the boiling point of water at sea level in Celsius and Fahrenheit?",
    "In what year did the Berlin Wall fall?",
    "What is the chemical formula for glucose?",
    "What is the largest planet in our solar system?",
    "Who wrote \"1984\"?",
    "What is the SI unit of electric current?",
]

PROMPTS = (
    MATH_PROMPTS + CODE_PROMPTS + BIOCHEM_PROMPTS + LAW_PROMPTS + FINANCE_PROMPTS
    + MEDICINE_PROMPTS + HISTORY_PROMPTS + PHILOSOPHY_PROMPTS + STATS_PROMPTS
    + DEVOPS_PROMPTS + LINGUISTICS_PROMPTS + ENGINEERING_PROMPTS + FACTUAL_PROMPTS
)
