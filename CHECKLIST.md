# Deployment Checklist

Zero to working deployed app, in order. Expected output is noted after each step.

---

## Phase 1 — Snowflake Setup

**1. Open Snowsight as ACCOUNTADMIN**

Navigate to your Snowflake account → Worksheets → New Worksheet. Confirm the role picker in the top-right shows `ACCOUNTADMIN`.

*Expected: Worksheet opens with no errors.*

---

**2. Edit `setup.sql` — replace `<YOUR_USER>`**

On the line that reads `GRANT ROLE STREAMLIT_DEMO_ROLE TO USER <YOUR_USER>;`, replace `<YOUR_USER>` with your exact Snowflake login name (case-sensitive on some accounts).

*Expected: The placeholder is gone; only your actual username remains.*

---

**3. Run `setup.sql` in full**

Paste the entire file and hit ⌘↵ (Mac) or Ctrl+↵ (Windows) to execute all statements.

*Expected: Each statement returns "Statement executed successfully." The INSERT should report "500 rows affected."*

---

**4. Run the verification queries (bottom of `setup.sql`)**

Execute the numbered verification queries one at a time.

*Expected:*
- *Query 7a: `RAW_ROW_COUNT = 500`*
- *Query 7b: Severity breakdown roughly 10% Critical, 20% High, 40% Medium, 30% Low*
- *Query 7c: CISA and DOD have the highest counts*
- *Query 7d: `CYBER_INCIDENTS_SUMMARY` appears with `REFRESH_MODE = INCREMENTAL` or `FULL`, `TARGET_LAG = 1 minute`*
- *Query 7e: Returns summary rows with `INCIDENT_COUNT` values*
- *Query 7f: Returns a one-sentence confirmation from Cortex (may take 5–10 seconds)*

If 7f errors with "model not available," the fallback (`llama3.1-70b`) will be used automatically by the app — no code change needed.

---

## Phase 2 — Local Development

**5. Copy the secrets template**

```bash
cp .streamlit/secrets.toml.example .streamlit/secrets.toml
```

*Expected: `.streamlit/secrets.toml` now exists locally.*

---

**6. Fill in `secrets.toml`**

Open `.streamlit/secrets.toml` and set:
- `account` — **dash-separated** org-account name (e.g. `acme-prod123`), not dot-separated
- `user` — your Snowflake username
- `password` — your password (or configure `private_key_file` for key-pair auth)
- Leave `role`, `warehouse`, `database`, `schema` as-is (they match what `setup.sql` created)

*Expected: File saved. No TOML syntax errors (you can validate with `python -c "import tomllib; tomllib.load(open('.streamlit/secrets.toml','rb'))"` on Python 3.11+).*

---

**7. Create a virtual environment and install dependencies**

```bash
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

*Expected: All four packages install without errors. `snowflake-snowpark-python` is the largest and may take 1–2 minutes.*

---

**8. Run the app locally**

```bash
streamlit run app.py
```

*Expected: Terminal prints "You can now view your Streamlit app in your browser" and opens `http://localhost:8501`. The page loads with 4 metric cards and 2 charts populated. No red error banners.*

---

**9. Test the Cortex features**

Click **Generate Executive Brief**. Wait 5–15 seconds.

*Expected: A 3-paragraph narrative appears below the button, grounded in the incident counts shown in the metrics.*

Click **Analyze Sentiment of Incident Narratives**.

*Expected: A table of up to 25 Critical/High incidents appears with a `SENTIMENT_SCORE` column containing decimal values between –1 and +1.*

---

**10. Test the Dynamic Table live-update (optional but impressive)**

Open a second Snowsight worksheet as `STREAMLIT_DEMO_ROLE` and run:

```sql
USE WAREHOUSE DEMO_WH; USE DATABASE CYBER_DEMO; USE SCHEMA PUBLIC;
INSERT INTO CYBER_INCIDENTS_RAW VALUES (
    'INC-2026-00501', 'CISA', 'Critical', 'Zero-Day Exploit',
    CURRENT_TIMESTAMP(), 412, 'Open',
    'A live-demo insert confirming Dynamic Table lag propagation.'
);
```

Wait ~60 seconds, then refresh the Streamlit tab (⌘R / Ctrl+R).

*Expected: "Total Incidents" increments by 1, and the CISA bar in the agency chart grows.*

---

## Phase 3 — Community Cloud Deployment

**11. Push the repo to GitHub**

```bash
git init
git add app.py setup.sql requirements.txt README.md CHECKLIST.md .gitignore .streamlit/secrets.toml.example
git commit -m "Initial commit — Federal Cyber Incident Intelligence demo"
git remote add origin https://github.com/<your-username>/<your-repo>.git
git push -u origin main
```

*Expected: Repo is visible on GitHub. Confirm `.streamlit/secrets.toml` is NOT in the repo (check `.gitignore` is working).*

---

**12. Create the Community Cloud app**

1. Go to [share.streamlit.io](https://share.streamlit.io) and sign in with GitHub
2. Click **New app**
3. Select your repo, branch (`main`), and set **Main file path** to `app.py`
4. Click **Advanced settings → Secrets**
5. Paste the contents of your local `secrets.toml` (the `[connections.snowflake]` block with real values)
6. Click **Deploy**

*Expected: Build log runs for 2–4 minutes installing dependencies. App loads at `https://<your-app>.streamlit.app`.*

---

**13. Smoke-test the deployed app**

Open the public URL. Verify:
- Metric cards show non-zero values
- Both charts render
- "Generate Executive Brief" returns a response
- "Analyze Sentiment" returns a table

*Expected: Identical behavior to local dev. If charts are empty, check that `STREAMLIT_DEMO_ROLE` has SELECT on the dynamic table (`GRANT SELECT ON FUTURE DYNAMIC TABLES IN SCHEMA CYBER_DEMO.PUBLIC TO ROLE STREAMLIT_DEMO_ROLE`).*

---

## Quick Reference — Most Likely Failures

| Symptom | Likely cause | Fix |
|---|---|---|
| `Connection refused` or `JWT token` error | Wrong account identifier format | Use `orgname-account_name` (dashes, not dots) |
| `Insufficient privileges` on CORTEX | Role missing Cortex grant | Re-run Section 2 of `setup.sql` as ACCOUNTADMIN |
| `Model not available in region` | Claude not enabled in your Snowflake region | App auto-falls back to `llama3.1-70b` — no action needed |
| Charts empty, metrics all zero | Dynamic table not yet refreshed | Wait 60s and reload; or query raw table directly to confirm data exists |
| `ModuleNotFoundError: snowflake` | Wrong package name in requirements | Confirm `snowflake-snowpark-python` (not `snowflake-connector-python`) is in requirements.txt |
