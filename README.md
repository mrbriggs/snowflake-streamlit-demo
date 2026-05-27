# Federal Cyber Incident Intelligence

A Streamlit demo built for a Snowflake interview, showcasing two platform differentiators for a Public Sector audience:

1. **Dynamic Tables** — a live aggregation pipeline that refreshes within 60 seconds of any insert to the raw table, with no ETL job or scheduler required.
2. **Cortex AI** — server-side LLM inference (`COMPLETE`, `SENTIMENT`) executed as SQL inside Snowflake — no external API keys, no data leaving the platform.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Snowflake account | Any edition; Cortex availability varies by region — see Troubleshooting |
| ACCOUNTADMIN access | Needed only to run `setup.sql` once |
| Python 3.9 – 3.11 | 3.12 works but some Snowpark wheels are slower to resolve |
| Git | For cloning / pushing to Community Cloud |

---

## Setup Order

### Step 1 — Clone or copy the repo

```bash
git clone <your-repo-url>
cd <repo-directory>
```

### Step 2 — Run setup.sql in Snowsight

1. Open Snowsight → **Worksheets** → **+ New Worksheet**
2. In the top-right role picker, select **ACCOUNTADMIN**
3. Paste the entire contents of `setup.sql`
4. **Find `<YOUR_USER>`** on line ~45 and replace it with your Snowflake username
5. Run all (⌘↵ / Ctrl↵)
6. Check the verification queries at the bottom — you should see:
   - `raw_row_count = 500`
   - Dynamic table listed in `INFORMATION_SCHEMA.DYNAMIC_TABLES`
   - Cortex smoke test returns a one-sentence response

### Step 3 — Configure credentials (local dev)

```bash
cp .streamlit/secrets.toml.example .streamlit/secrets.toml
```

Edit `.streamlit/secrets.toml`:

```toml
[connections.snowflake]
account   = "orgname-account_name"   # ← DASH-separated (see note below)
user      = "your_username"
password  = "your_password"
role      = "STREAMLIT_DEMO_ROLE"
warehouse = "DEMO_WH"
database  = "CYBER_DEMO"
schema    = "PUBLIC"
```

> **Account identifier format:** use the **dash-separated** `orgname-account_name` form,  
> not the legacy dot form (`orgname.account_name`). `st.connection("snowflake")` requires  
> the dash form. Find your org name in Snowsight under **Admin → Accounts**.

### Step 4 — Install dependencies and run locally

```bash
python -m venv .venv
source .venv/bin/activate      # Windows: .venv\Scripts\activate
pip install -r requirements.txt
streamlit run app.py
```

Open [http://localhost:8501](http://localhost:8501).

---

## Deploy to Streamlit Community Cloud

1. Push the repo to a **public** GitHub repository (or a private one linked to your Community Cloud account).
2. Go to [share.streamlit.io](https://share.streamlit.io) → **New app**
3. Select your repo, branch, and set **Main file path** to `app.py`
4. Click **Advanced settings** → **Secrets** and paste the same `[connections.snowflake]` block from your local `secrets.toml`
5. Deploy — Community Cloud installs `requirements.txt` automatically

> Community Cloud runs on Python 3.11 by default. If you need to pin a version,  
> add a `.python-version` file containing `3.11`.

---

## Demo Moments (for the live walkthrough)

### Moment 1 — Dynamic Table live update

Explain that the charts query `CYBER_INCIDENTS_SUMMARY` — a Dynamic Table, not a view. Open a second browser tab with Snowsight and run:

```sql
USE ROLE STREAMLIT_DEMO_ROLE;
USE WAREHOUSE DEMO_WH;
USE DATABASE CYBER_DEMO;
USE SCHEMA PUBLIC;

INSERT INTO CYBER_INCIDENTS_RAW VALUES (
    'INC-2026-00501',
    'CISA',
    'Critical',
    'Zero-Day Exploit',
    CURRENT_TIMESTAMP(),
    412,
    'Open',
    'A zero-day vulnerability in a perimeter VPN appliance was exploited during this live demonstration, confirming that Snowflake Dynamic Tables propagate new data within the configured lag window without any manual refresh or ETL job.'
);
```

Wait ~60 seconds, then hit **⌘R / Ctrl+R** in the Streamlit tab. The Total Incidents metric and the stacked bar chart will reflect the new row.

### Moment 2 — Cortex AI brief

Set filters to **last 90 days, all agencies, all severities** for maximum data, then click **Generate Executive Brief**. Walk through:
- The prompt is constructed in Python from live aggregate counts — grounded, not hallucinated
- The SQL executes inside Snowflake: `SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet', '...')`
- No LLM API key, no outbound HTTP call from the app, no data leaving the Snowflake boundary

Follow up with **Analyze Sentiment of Incident Narratives** to show `CORTEX.SENTIMENT` scoring analyst text across Critical/High incidents.

---

## Troubleshooting

### 1. "Account identifier must be in the form org-account"

You are using the dot-separated format in `secrets.toml`. Change:

```
# Wrong
account = "myorg.myaccount"

# Correct
account = "myorg-myaccount"
```

Find your exact org and account name in Snowsight: **Admin → Accounts** — hover over your account row to see the full identifier.

### 2. "Role STREAMLIT_DEMO_ROLE does not have the CORTEX_USER privilege"

The `setup.sql` grants `SNOWFLAKE.CORTEX_USER` in Section 2. If you see this error, either:

- The grant was skipped (run Section 2 again as ACCOUNTADMIN), or  
- Your Snowflake account is on a version that uses a different grant name

Check the grant:

```sql
USE ROLE ACCOUNTADMIN;
SHOW GRANTS TO ROLE STREAMLIT_DEMO_ROLE;
-- Look for SNOWFLAKE.CORTEX_USER in the output
```

### 3. "Model 'claude-3-5-sonnet' is not available in your region"

Cortex model availability varies by Snowflake region. The app automatically falls back to `llama3.1-70b`, which is available in all commercial regions. To check what models your account can access:

```sql
SELECT SNOWFLAKE.CORTEX.COMPLETE('claude-3-5-sonnet', 'test') AS test;
-- If this errors, use llama3.1-70b or mistral-large2 instead
```

To permanently switch the primary model, edit line 19 of `app.py`:

```python
PRIMARY_MODEL = "mistral-large2"   # or any model available in your region
```
