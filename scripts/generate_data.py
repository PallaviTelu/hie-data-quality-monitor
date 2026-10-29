"""
Generate SYNTHETIC monthly HIE submission data with realistic defects.

All facility names are fictional. Nothing here reflects real NC HealthConnex
participants, systems, or data. The data simulates the kind of monthly
extract a data-quality analyst would build from HL7 feed logs.

Reproducible: seeded RNG. Re-running produces identical files.

Usage:  python scripts/generate_data.py
Output: data/raw/facilities.csv
        data/raw/monthly_submissions_raw.csv
        data/raw/validation_errors_raw.csv
"""
import csv
import random
from datetime import date
from pathlib import Path

SEED = 42
RAW_DIR = Path(__file__).resolve().parent.parent / "data" / "raw"

# 12 reporting months: Oct 2025 .. Sep 2026
MONTHS = [f"{2025 + (9 + i) // 12}-{(9 + i) % 12 + 1:02d}" for i in range(12)]

FACILITY_TYPES = {
    # type: (monthly record range, baseline error-rate range)
    "Hospital": ((20000, 60000), (0.004, 0.020)),
    "Clinic": ((2000, 8000), (0.006, 0.025)),
    "Laboratory": ((5000, 15000), (0.003, 0.015)),
    "Pharmacy": ((3000, 10000), (0.005, 0.022)),
    "Behavioral Health": ((500, 2000), (0.008, 0.028)),
}
TYPE_MIX = (["Hospital"] * 8 + ["Clinic"] * 14 + ["Laboratory"] * 6
            + ["Pharmacy"] * 7 + ["Behavioral Health"] * 5)

COUNTIES = [
    "Wake", "Mecklenburg", "Guilford", "Forsyth", "Durham", "Buncombe",
    "Cumberland", "Pitt", "New Hanover", "Union", "Gaston", "Johnston",
    "Onslow", "Catawba", "Iredell", "Rowan", "Alamance", "Cabarrus",
    "Robeson", "Wayne",
]

NAME_STEMS = [
    "Maple Grove", "Cedar Ridge", "Blue Heron", "Harbor View", "Piedmont Crest",
    "Willow Bend", "Foothills", "Riverbend", "Oak Hollow", "Summit Park",
    "Magnolia", "Pinewood", "Lakeside", "Brookfield", "Stonegate", "Fairview",
    "Heritage", "Sandhills", "Coastal Plain", "Mountain Laurel", "Red Clay",
    "Dogwood", "Cypress Point", "Trinity Square", "Bayleaf", "Ironwood",
    "Silver Creek", "Meadowlark", "Granite Falls", "Sweetgum", "Tidewater",
    "Longleaf", "Hickory Lane", "Cardinal", "Amber Fields", "Quarry Hill",
    "Kestrel", "Juniper", "Northgate", "Pelican Bay",
]
NAME_SUFFIX = {
    "Hospital": "Regional Medical Center",
    "Clinic": "Family Health Clinic",
    "Laboratory": "Diagnostic Laboratory",
    "Pharmacy": "Community Pharmacy",
    "Behavioral Health": "Behavioral Health Center",
}

ERROR_TYPES = ["Missing Required Field", "Invalid Code", "Duplicate Message", "Invalid Date"]
ERROR_WEIGHTS = [0.40, 0.30, 0.18, 0.12]

MONTH_ABBR = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
              "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def fmt_id_variant(fid, rng, defect_rate=0.06):
    """Mostly canonical IDs; occasionally an inconsistent variant."""
    if rng.random() > defect_rate:
        return fid
    num = fid.split("-")[1]
    return rng.choice([f"fac-{num}", f"FAC{num}", f" {fid} ", f"Fac {num}"])


def fmt_month_variant(ym, rng, defect_rate=0.08):
    """Mostly ISO 'YYYY-MM'; occasionally 'MM/YYYY' or 'Mon YYYY'."""
    if rng.random() > defect_rate:
        return ym
    y, m = ym.split("-")
    return rng.choice([f"{m}/{y}", f"{MONTH_ABBR[int(m) - 1]} {y}"])


def fmt_date_variant(d, rng, defect_rate=0.12):
    """Mostly ISO dates; occasionally MM/DD/YYYY."""
    if rng.random() > defect_rate:
        return d.isoformat()
    return d.strftime("%m/%d/%Y")


def month_start(ym):
    y, m = ym.split("-")
    return date(int(y), int(m), 1)


def main():
    rng = random.Random(SEED)
    RAW_DIR.mkdir(parents=True, exist_ok=True)

    # ---- facilities ------------------------------------------------------
    types = TYPE_MIX[:]
    rng.shuffle(types)
    stems = NAME_STEMS[:]
    rng.shuffle(stems)

    # 3 facilities onboard during the window; the rest before it starts
    late_onboard = {37: "2026-02-10", 38: "2026-05-04", 39: "2026-07-13"}

    facilities = []
    for i in range(40):
        fid = f"FAC-{i + 1:03d}"
        ftype = types[i]
        if i in late_onboard:
            onboard = late_onboard[i]
        else:
            onboard = date(rng.randint(2022, 2025), rng.randint(1, 12), rng.randint(1, 28))
            if onboard >= date(2025, 10, 1):
                onboard = date(2025, 6, rng.randint(1, 28))
            onboard = onboard.isoformat()
        (vol_lo, vol_hi), (err_lo, err_hi) = FACILITY_TYPES[ftype]
        facilities.append({
            "facility_id": fid,
            "facility_name": f"{stems[i]} {NAME_SUFFIX[ftype]}",
            "facility_type": ftype,
            "county": rng.choice(COUNTIES),
            "onboarding_date": onboard,
            "_base_volume": rng.randint(vol_lo, vol_hi),
            "_base_err": rng.uniform(err_lo, err_hi),
        })

    # A handful of "problem" facilities with persistently high error rates
    problem_idx = rng.sample([i for i in range(40) if i not in late_onboard], 4)
    for i in problem_idx:
        facilities[i]["_base_err"] = rng.uniform(0.045, 0.085)
    # One facility that degrades over the last 4 months
    degrading_idx = rng.choice([i for i in range(36) if i not in problem_idx])

    # ---- silent periods --------------------------------------------------
    eligible = [i for i in range(36) if i not in problem_idx]
    silent_pool = rng.sample(eligible, 5)
    silent_plan = {
        silent_pool[0]: MONTHS[-1:],           # currently silent (1 month)
        silent_pool[1]: MONTHS[-3:],           # currently silent (3 months)
        silent_pool[2]: MONTHS[2:4],           # historical gap (2 months), recovered
        silent_pool[3]: MONTHS[5:6],           # historical gap (1 month), recovered
        silent_pool[4]: MONTHS[7:10],          # historical gap (3 months), recovered
    }

    # ---- monthly submissions + validation errors -------------------------
    submissions = []   # raw rows
    errors = []        # raw rows
    for idx, fac in enumerate(facilities):
        onboard = date.fromisoformat(fac["onboarding_date"])
        for mi, ym in enumerate(MONTHS):
            m_start = month_start(ym)
            m_end_day = 28  # received dates fall between day 22 and 28
            if onboard > date(m_start.year, m_start.month, 28):
                continue  # not yet onboarded

            silent = ym in silent_plan.get(idx, [])
            if silent:
                # Half the silent months have no row at all; half have a zero-count row
                if rng.random() < 0.5:
                    continue
                submissions.append({
                    "facility_id": fmt_id_variant(fac["facility_id"], rng),
                    "submission_month": fmt_month_variant(ym, rng),
                    "record_count": "0",
                    "last_received_date": "",
                })
                continue

            # normal month
            drift = rng.uniform(0.93, 1.07)
            records = int(fac["_base_volume"] * drift)
            recv = date(m_start.year, m_start.month, rng.randint(22, m_end_day))
            submissions.append({
                "facility_id": fmt_id_variant(fac["facility_id"], rng),
                "submission_month": fmt_month_variant(ym, rng),
                "record_count": str(records),
                "last_received_date": fmt_date_variant(recv, rng),
            })

            # validation errors for this facility-month
            err_rate = fac["_base_err"] * rng.uniform(0.8, 1.2)
            if idx == degrading_idx and mi >= len(MONTHS) - 4:
                err_rate *= 2.2 + 0.6 * (mi - (len(MONTHS) - 4))
            total_err = int(records * err_rate)
            weights = ERROR_WEIGHTS[:]
            if fac["facility_type"] == "Laboratory":
                weights = [0.25, 0.50, 0.15, 0.10]  # labs: more invalid codes
            counts = {t: 0 for t in ERROR_TYPES}
            for _ in range(min(total_err, 4000)):
                counts[rng.choices(ERROR_TYPES, weights)[0]] += 1
            if total_err > 4000:  # scale up when sampled
                scale = total_err / 4000
                counts = {t: int(c * scale) for t, c in counts.items()}
            for et, c in counts.items():
                if c > 0:
                    errors.append({
                        "facility_id": fmt_id_variant(fac["facility_id"], rng),
                        "report_month": fmt_month_variant(ym, rng),
                        "error_type": et,
                        "error_count": str(c),
                    })

    # ---- inject additional defects --------------------------------------
    # 1) Exact duplicate rows (6)
    for row in rng.sample(submissions, 6):
        submissions.append(dict(row))
    # 2) Conflicting duplicates: same facility-month, different record_count (2)
    for row in rng.sample([r for r in submissions if r["record_count"] not in ("0", "")], 2):
        dup = dict(row)
        dup["record_count"] = str(int(int(row["record_count"]) * rng.uniform(0.6, 0.9)))
        submissions.append(dup)
    # 3) Missing record_count (3)
    for row in rng.sample([r for r in submissions if r["record_count"] not in ("0", "")], 3):
        row["record_count"] = ""
    # 4) Out-of-range record counts: negative (3) and implausibly huge (2)
    candidates = [r for r in submissions if r["record_count"] not in ("0", "")]
    for row in rng.sample(candidates, 3):
        row["record_count"] = str(-abs(int(row["record_count"])))
    candidates = [r for r in submissions if r["record_count"] not in ("0", "") and not r["record_count"].startswith("-")]
    for row in rng.sample(candidates, 2):
        row["record_count"] = str(int(row["record_count"]) * 100)
    # 5) Orphan facility IDs that are not in the facility master
    submissions.append({"facility_id": "FAC-099", "submission_month": MONTHS[-1],
                        "record_count": "4120", "last_received_date": "2026-09-24"})
    errors.append({"facility_id": "FAC-098", "report_month": MONTHS[-2],
                   "error_type": "Invalid Code", "error_count": "37"})
    errors.append({"facility_id": "FAC-099", "report_month": MONTHS[-1],
                   "error_type": "Missing Required Field", "error_count": "52"})

    rng.shuffle(submissions)
    rng.shuffle(errors)

    # ---- write -----------------------------------------------------------
    with open(RAW_DIR / "facilities.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["facility_id", "facility_name", "facility_type",
                                          "county", "onboarding_date"])
        w.writeheader()
        for fac in facilities:
            w.writerow({k: fac[k] for k in w.fieldnames})

    with open(RAW_DIR / "monthly_submissions_raw.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["facility_id", "submission_month",
                                          "record_count", "last_received_date"])
        w.writeheader()
        w.writerows(submissions)

    with open(RAW_DIR / "validation_errors_raw.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["facility_id", "report_month",
                                          "error_type", "error_count"])
        w.writeheader()
        w.writerows(errors)

    print(f"facilities: {len(facilities)}")
    print(f"monthly_submissions_raw: {len(submissions)} rows")
    print(f"validation_errors_raw:   {len(errors)} rows")
    print(f"months: {MONTHS[0]} .. {MONTHS[-1]}")


if __name__ == "__main__":
    main()
