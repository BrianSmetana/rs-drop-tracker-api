"""Drop-luck statistics. Pure functions, no I/O."""
import math


def per_kill_probability(rate: float, rolls: int = 1) -> float:
    """Chance of at least one hit of the item per kill (rate = 1/x as a float)."""
    return 1.0 - (1.0 - rate) ** rolls


def _log_pmf(n: int, k: int, p: float) -> float:
    if p <= 0.0:
        return 0.0 if k == 0 else -math.inf
    if p >= 1.0:
        return 0.0 if k == n else -math.inf
    return (
        math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1)
        + k * math.log(p) + (n - k) * math.log1p(-p)
    )


def binom_pmf(n: int, k: int, p: float) -> float:
    return math.exp(_log_pmf(n, k, p)) if 0 <= k <= n else 0.0


def binom_cdf(n: int, k: int, p: float) -> float:
    """P(X <= k)."""
    if k < 0:
        return 0.0
    if k >= n:
        return 1.0
    return min(1.0, sum(binom_pmf(n, i, p) for i in range(k + 1)))


def threshold_probabilities(kc_first: int, kc_last: int, rate: float, threshold: int, rolls: int = 1) -> list[float]:
    """Per-kill chances for a boss-pet style drop: the numerator grows by 1 every `threshold` recorded kills and is
    capped at 10 (the wiki's formula), so kill number kc has chance (1 + min((kc-1)//threshold, 9)) * rate."""
    return [
        per_kill_probability(min(1.0, (1 + min((kc - 1) // threshold, 9)) * rate), rolls)
        for kc in range(kc_first, kc_last + 1)
    ]


def luck_threshold(kc_first: int, kc_last: int, drops: int, rate: float, threshold: int, rolls: int = 1) -> dict:
    """Same as luck(), but kill chances differ per kill (Poisson-binomial)."""
    return luck_from_probs(threshold_probabilities(kc_first, kc_last, rate, threshold, rolls), drops)


def luck_from_probs(probs: list[float], drops: int) -> dict:
    """Luck when each kill has its own drop chance (threshold pets, enrage-dependent rates)."""
    dp = [1.0] + [0.0] * drops  # dp[j] = P(exactly j drops so far), truncated at `drops`
    for p in probs:
        for j in range(drops, 0, -1):
            dp[j] = dp[j] * (1 - p) + dp[j - 1] * p
        dp[0] *= 1 - p
    below, at = sum(dp[:drops]), dp[drops]
    return {
        "kills": len(probs),
        "drops": drops,
        "per_kill_probability": sum(probs) / len(probs) if probs else 0.0,
        "expected_drops": sum(probs),
        "p_at_most": min(1.0, below + at),
        "p_at_least": min(1.0, 1.0 - below),
        "dry_percent": round(100.0 * min(1.0, below + at), 2),
        "percentile": round(100.0 * (below + 0.5 * at), 2),
    }


def luck(kills: int, drops: int, rate: float, rolls: int = 1) -> dict:
    """Compare observed drops with the expected binomial distribution.

    percentile is the mid-p value P(X < k) + 0.5 * P(X = k), scaled to 0-100:
    50 = exactly average, low = unlucky (few drops), high = lucky (many drops).
    """
    p = per_kill_probability(rate, rolls)
    below = binom_cdf(kills, drops - 1, p)
    at = binom_pmf(kills, drops, p)
    return {
        "kills": kills,
        "drops": drops,
        "per_kill_probability": p,
        "expected_drops": kills * p,
        "p_at_most": min(1.0, below + at),
        "p_at_least": min(1.0, 1.0 - below),
        "dry_percent": round(100.0 * min(1.0, below + at), 2),
        "percentile": round(100.0 * (below + 0.5 * at), 2),
    }


# --- lifetime luck, as shown by the in-game collection-log label ---------------------------------------------------
# Same maths as plugin/drop_tracker_rs/collog.lua (M.cdf), so the API and the game agree. X = the number of drops,
# `count` = how many the player has (the number on the collection-log slot).

def _pmf_upto(n: int, p: float, k: int) -> list[float]:
    """P(X = j) for j = 0..k with X ~ Binomial(n, p)."""
    if n <= 0 or p <= 0.0:
        return [1.0] + [0.0] * k
    if p >= 1.0:
        return [1.0 if j == n else 0.0 for j in range(k + 1)]
    return [binom_pmf(n, j, p) for j in range(k + 1)]


def _convolve(dist: list[float], block: list[float], k: int) -> list[float]:
    out = [0.0] * (k + 1)
    for i, a in enumerate(dist):
        if a == 0.0:
            continue
        for j in range(k + 1 - i):
            out[i + j] += a * block[j]
    return out


def lifetime_distribution(spec, kills: int, k: int, hard_kills: int = 0) -> tuple[list[float], float]:
    """(P(X = j) for j = 0..k, expected drops) for a rate spec (see app/clog_rates.py).

    `kills` is the number of kills the spec counts: normal-mode kills for a flat or multi-roll rate, normal + hard for
    a boss pet, whose `hard_kills` of them use `hard_base` and are assumed spread evenly over the threshold blocks.
    """
    k = max(0, int(k))
    kills = max(0, int(kills))
    dist = [1.0] + [0.0] * k
    expected = 0.0

    if not isinstance(spec, dict):
        dist = _convolve(dist, _pmf_upto(kills, spec, k), k)
        expected = kills * spec
    elif "rolls" in spec:
        n = kills * int(spec["rolls"])
        dist = _convolve(dist, _pmf_upto(n, spec["rate"], k), k)
        expected = n * spec["rate"]
    else:  # boss pet
        threshold, base = int(spec["threshold"]), spec["base"]
        hard_base = spec.get("hard_base", base)
        share = min(1.0, max(0.0, hard_kills / kills)) if kills > 0 else 0.0
        remaining, step = kills, 0
        while remaining > 0:
            n = min(threshold, remaining) if step < 9 else remaining
            multiplier = 1 + min(step, 9)
            hard_n = math.floor(n * share + 0.5)
            p_normal, p_hard = min(1.0, multiplier * base), min(1.0, multiplier * hard_base)
            dist = _convolve(dist, _pmf_upto(n - hard_n, p_normal, k), k)
            expected += (n - hard_n) * p_normal
            if hard_n > 0:
                dist = _convolve(dist, _pmf_upto(hard_n, p_hard, k), k)
                expected += hard_n * p_hard
            remaining -= n
            step += 1
    return dist, expected


def lifetime_luck(spec, kills: int, count: int, hard_kills: int = 0) -> dict:
    """Luck over a player's lifetime kills for one item.

    `kills` / `hard_kills` are normal and hard-mode kills; `count` is how many of the item the player has.
    dry_percent is P(X <= count): the chance of having at most that many drops (low = unlucky, high = lucky).
    For count 0 it is the plain dry chance (1 - p)^kills. percentile is the mid-p value used for ranking players.
    """
    is_pet = isinstance(spec, dict) and "base" in spec
    counted = kills + hard_kills if is_pet else kills
    dist, expected = lifetime_distribution(spec, counted, count, hard_kills if is_pet else 0)
    below, at = sum(dist[:count]), dist[count]
    at_most = min(1.0, below + at)
    return {
        "kills": kills,
        "hard_kills": hard_kills,
        "count": count,
        "expected_drops": expected,
        "p_at_most": at_most,
        "dry_percent": round(100.0 * at_most, 2),
        "percentile": round(100.0 * (below + 0.5 * at), 2),
    }
