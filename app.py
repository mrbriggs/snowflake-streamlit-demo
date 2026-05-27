"""
Federal Cyber Incident Intelligence
Streamlit demo — Snowflake Dynamic Tables + Cortex LLM
"""

import streamlit as st
import plotly.express as px
import plotly.graph_objects as go
import pandas as pd
from datetime import date, timedelta

# ---------------------------------------------------------------------------
# Page config — must be the first Streamlit call
# ---------------------------------------------------------------------------
st.set_page_config(
    page_title="Federal Cyber Incident Intelligence",
    page_icon="🛡️",
    layout="wide",
)

# ---------------------------------------------------------------------------
# Snowflake connection via st.connection (credentials in .streamlit/secrets.toml)
# ---------------------------------------------------------------------------
conn = st.connection("snowflake")

# ---------------------------------------------------------------------------
# Constants — kept here so they're easy to find during a live demo
# ---------------------------------------------------------------------------
ALL_AGENCIES   = ["CISA", "DOD", "DHS", "Treasury", "State", "HHS", "VA", "DOE", "NASA", "FBI"]
ALL_SEVERITIES = ["Critical", "High", "Medium", "Low"]
SEVERITY_COLOR = {
    "Critical": "#d62728",
    "High":     "#ff7f0e",
    "Medium":   "#1f77b4",
    "Low":      "#2ca02c",
}
PRIMARY_MODEL  = "claude-3-5-sonnet"
FALLBACK_MODEL = "llama3.1-70b"


# ---------------------------------------------------------------------------
# Data loading helpers
# All queries go through the Snowflake connection; conn.query handles caching.
# ---------------------------------------------------------------------------

def load_filtered_incidents(start: date, end: date, agencies: list, severities: list) -> pd.DataFrame:
    """
    Pull raw incidents matching the sidebar filters.
    Uses conn.query with ttl=600 so repeated calls with identical parameters
    are served from cache rather than re-querying Snowflake.
    """
    agency_list   = ", ".join(f"'{a}'" for a in agencies)
    severity_list = ", ".join(f"'{s}'" for s in severities)

    sql = f"""
        SELECT
            incident_id,
            agency,
            severity,
            incident_type,
            detected_at::DATE  AS incident_date,
            affected_systems,
            status,
            narrative
        FROM CYBER_INCIDENTS_RAW
        WHERE detected_at >= '{start}'
          AND detected_at <  DATEADD('day', 1, '{end}')
          AND agency    IN ({agency_list})
          AND severity  IN ({severity_list})
        ORDER BY detected_at DESC
    """
    return conn.query(sql, ttl=600)


def load_dynamic_summary(start: date, end: date, agencies: list, severities: list) -> pd.DataFrame:
    """
    Pull from the Dynamic Table for chart data — this is the key demo artifact.
    The dynamic table refreshes within 60 seconds of any raw-table insert,
    so these charts stay live without touching the large base table directly.
    """
    agency_list   = ", ".join(f"'{a}'" for a in agencies)
    severity_list = ", ".join(f"'{s}'" for s in severities)

    sql = f"""
        SELECT
            incident_date,
            agency,
            severity,
            incident_type,
            status,
            incident_count,
            avg_affected_systems
        FROM CYBER_INCIDENTS_SUMMARY
        WHERE incident_date >= '{start}'
          AND incident_date <= '{end}'
          AND agency    IN ({agency_list})
          AND severity  IN ({severity_list})
    """
    return conn.query(sql, ttl=600)


def run_cortex_complete(prompt: str, model: str = PRIMARY_MODEL) -> str:
    """
    Call SNOWFLAKE.CORTEX.COMPLETE with the given model.
    Falls back to FALLBACK_MODEL if the primary model raises an error
    (typically means the model is not available in this Snowflake region).
    """
    safe_prompt = prompt.replace("'", "''")  # escape any single quotes in the prompt
    sql = f"SELECT SNOWFLAKE.CORTEX.COMPLETE('{model}', '{safe_prompt}') AS result"
    try:
        df = conn.query(sql, ttl=600)
        return df["RESULT"].iloc[0]
    except Exception as exc:
        if model != FALLBACK_MODEL:
            st.warning(
                f"{PRIMARY_MODEL} is not available in this region — retrying with {FALLBACK_MODEL}.",
                icon="⚠️",
            )
            return run_cortex_complete(prompt, model=FALLBACK_MODEL)
        raise exc


def run_cortex_sentiment(start: date, end: date, agencies: list) -> pd.DataFrame:
    """
    Run SNOWFLAKE.CORTEX.SENTIMENT over narratives of Critical and High incidents
    within the current filter window (severity filter is intentionally fixed to
    Critical/High — these are the incidents worth sentiment-scoring for leadership).
    """
    agency_list = ", ".join(f"'{a}'" for a in agencies)

    sql = f"""
        SELECT
            incident_id,
            agency,
            severity,
            LEFT(narrative, 120) || '...'                 AS narrative_preview,
            ROUND(SNOWFLAKE.CORTEX.SENTIMENT(narrative), 3) AS sentiment_score
        FROM CYBER_INCIDENTS_RAW
        WHERE detected_at >= '{start}'
          AND detected_at <  DATEADD('day', 1, '{end}')
          AND agency   IN ({agency_list})
          AND severity IN ('Critical', 'High')
        ORDER BY sentiment_score ASC
        LIMIT 25
    """
    return conn.query(sql, ttl=600)


# ---------------------------------------------------------------------------
# Session-state helpers — clear AI outputs when filters change
# ---------------------------------------------------------------------------

def _filter_key(start, end, agencies, severities) -> str:
    return f"{start}|{end}|{'_'.join(sorted(agencies))}|{'_'.join(sorted(severities))}"


def _reset_ai_state():
    st.session_state.brief        = None
    st.session_state.sentiment_df = None


def _init_session_state():
    for key in ("brief", "sentiment_df", "last_filter_key"):
        if key not in st.session_state:
            st.session_state[key] = None


_init_session_state()


# ===========================================================================
# SIDEBAR — FILTERS
# ===========================================================================

with st.sidebar:
    st.header("Filters")

    date_range = st.date_input(
        "Date range",
        value=(date.today() - timedelta(days=30), date.today()),
        max_value=date.today(),
    )

    # date_input returns a tuple when a range is selected; handle single-date edge case
    if isinstance(date_range, (list, tuple)) and len(date_range) == 2:
        start_date, end_date = date_range
    else:
        start_date = end_date = date_range

    selected_agencies = st.multiselect(
        "Agency",
        options=ALL_AGENCIES,
        default=ALL_AGENCIES,
    )

    selected_severities = st.multiselect(
        "Severity",
        options=ALL_SEVERITIES,
        default=ALL_SEVERITIES,
    )

    st.divider()
    st.caption("Data pipeline: Dynamic Table `CYBER_INCIDENTS_SUMMARY` refreshes every 60 seconds from `CYBER_INCIDENTS_RAW`.")

# Guard: require at least one agency and one severity
if not selected_agencies or not selected_severities:
    st.warning("Select at least one agency and one severity to continue.")
    st.stop()

# Detect filter changes and clear cached AI output
current_filter_key = _filter_key(start_date, end_date, selected_agencies, selected_severities)
if st.session_state.last_filter_key != current_filter_key:
    _reset_ai_state()
    st.session_state.last_filter_key = current_filter_key


# ===========================================================================
# LOAD DATA
# ===========================================================================

with st.spinner("Querying Snowflake…"):
    df_raw     = load_filtered_incidents(start_date, end_date, selected_agencies, selected_severities)
    df_summary = load_dynamic_summary(start_date, end_date, selected_agencies, selected_severities)


# ===========================================================================
# TITLE
# ===========================================================================

st.title("🛡️ Federal Cyber Incident Intelligence")
st.caption(
    "Real-time threat visibility powered by **Snowflake Dynamic Tables** and **Cortex AI** · "
    f"Showing `{start_date}` → `{end_date}` · "
    f"{len(df_raw):,} incidents matched"
)
st.divider()


# ===========================================================================
# METRIC CARDS
# ===========================================================================

total_incidents   = int(df_raw.shape[0])
critical_count    = int((df_raw["SEVERITY"] == "Critical").sum())
open_count        = int((df_raw["STATUS"] == "Open").sum())
avg_affected      = df_raw["AFFECTED_SYSTEMS"].mean() if not df_raw.empty else 0

col1, col2, col3, col4 = st.columns(4)

col1.metric("Total Incidents",      f"{total_incidents:,}")
col2.metric("Critical Incidents",   f"{critical_count:,}",  delta=None,
            help="Severity = Critical")
col3.metric("Open Incidents",       f"{open_count:,}",
            help="Status = Open")
col4.metric("Avg Affected Systems", f"{avg_affected:.1f}",
            help="Mean affected systems per incident in the current filter window")

st.divider()


# ===========================================================================
# CHARTS — stacked bar (by agency) + line (daily trend by severity)
# ===========================================================================

chart_left, chart_right = st.columns(2)

# --- LEFT: Incidents by Agency, stacked by Severity ---
with chart_left:
    st.subheader("Incidents by Agency & Severity")

    if df_summary.empty:
        st.info("No data for the selected filters.")
    else:
        agency_sev = (
            df_summary
            .groupby(["AGENCY", "SEVERITY"], as_index=False)["INCIDENT_COUNT"]
            .sum()
        )
        # Enforce consistent severity order and color mapping
        agency_sev["SEVERITY"] = pd.Categorical(
            agency_sev["SEVERITY"], categories=ALL_SEVERITIES, ordered=True
        )
        agency_sev = agency_sev.sort_values("SEVERITY")

        fig_bar = px.bar(
            agency_sev,
            x="AGENCY",
            y="INCIDENT_COUNT",
            color="SEVERITY",
            color_discrete_map=SEVERITY_COLOR,
            category_orders={"SEVERITY": ALL_SEVERITIES},
            labels={"INCIDENT_COUNT": "Incidents", "AGENCY": "Agency"},
            barmode="stack",
        )
        fig_bar.update_layout(
            legend_title_text="Severity",
            plot_bgcolor="rgba(0,0,0,0)",
            paper_bgcolor="rgba(0,0,0,0)",
            margin=dict(t=10, b=10),
        )
        st.plotly_chart(fig_bar, use_container_width=True)


# --- RIGHT: Daily Incident Count, one line per Severity ---
with chart_right:
    st.subheader("Daily Incident Trend by Severity")

    if df_summary.empty:
        st.info("No data for the selected filters.")
    else:
        daily_sev = (
            df_summary
            .groupby(["INCIDENT_DATE", "SEVERITY"], as_index=False)["INCIDENT_COUNT"]
            .sum()
        )
        daily_sev["SEVERITY"] = pd.Categorical(
            daily_sev["SEVERITY"], categories=ALL_SEVERITIES, ordered=True
        )

        fig_line = px.line(
            daily_sev.sort_values(["INCIDENT_DATE", "SEVERITY"]),
            x="INCIDENT_DATE",
            y="INCIDENT_COUNT",
            color="SEVERITY",
            color_discrete_map=SEVERITY_COLOR,
            category_orders={"SEVERITY": ALL_SEVERITIES},
            labels={"INCIDENT_COUNT": "Incidents", "INCIDENT_DATE": "Date"},
            markers=True,
        )
        fig_line.update_layout(
            legend_title_text="Severity",
            plot_bgcolor="rgba(0,0,0,0)",
            paper_bgcolor="rgba(0,0,0,0)",
            margin=dict(t=10, b=10),
        )
        st.plotly_chart(fig_line, use_container_width=True)


st.divider()


# ===========================================================================
# AI-GENERATED THREAT BRIEF  (Snowflake Cortex — COMPLETE)
# ===========================================================================

st.subheader("AI-Generated Threat Brief")
st.caption(
    f"Powered by `SNOWFLAKE.CORTEX.COMPLETE('{PRIMARY_MODEL}', …)` — "
    "runs server-side inside Snowflake; no LLM client library required."
)

if st.button("Generate Executive Brief", type="primary"):
    # Build a grounded prompt from the actual filtered data
    if df_raw.empty:
        st.warning("No incidents to brief — adjust the filters and try again.")
    else:
        sev_counts   = df_raw.groupby("SEVERITY")["INCIDENT_ID"].count().to_dict()
        type_counts  = df_raw.groupby("INCIDENT_TYPE")["INCIDENT_ID"].count().nlargest(3).to_dict()
        agency_counts = df_raw.groupby("AGENCY")["INCIDENT_ID"].count().nlargest(3).to_dict()
        open_pct     = round(open_count / total_incidents * 100, 1) if total_incidents else 0

        sev_summary   = ", ".join(f"{k}: {v}" for k, v in sev_counts.items())
        type_summary  = ", ".join(f"{k}: {v}" for k, v in type_counts.items())
        agency_summary = ", ".join(f"{k}: {v}" for k, v in agency_counts.items())

        prompt = (
            f"You are a senior cybersecurity analyst briefing federal executive leadership. "
            f"Write a concise 3-paragraph executive threat brief based on the following "
            f"incident data from {start_date} to {end_date}. "
            f"Total incidents: {total_incidents}. "
            f"Severity breakdown: {sev_summary}. "
            f"Top incident types: {type_summary}. "
            f"Most affected agencies: {agency_summary}. "
            f"Open (unresolved) incidents: {open_count} ({open_pct}%). "
            f"Average systems affected per incident: {avg_affected:.1f}. "
            f"Paragraph 1: Summarize the overall threat posture during this period. "
            f"Paragraph 2: Highlight the most significant patterns or risks. "
            f"Paragraph 3: Recommend 2-3 immediate actions for agency leadership. "
            f"Write in plain language suitable for a non-technical senior official. "
            f"Do not invent details not supported by the data above."
        )

        with st.spinner("Calling Snowflake Cortex…"):
            st.session_state.brief = run_cortex_complete(prompt)

# Display brief if it exists
if st.session_state.brief:
    st.markdown(st.session_state.brief)


st.divider()


# ===========================================================================
# SENTIMENT ANALYSIS  (Snowflake Cortex — SENTIMENT)
# ===========================================================================

st.subheader("Incident Narrative Sentiment Analysis")
st.caption(
    "Runs `SNOWFLAKE.CORTEX.SENTIMENT(narrative)` on Critical and High incidents "
    "in the current date window. Scores range from –1 (most negative) to +1 (most positive)."
)

if st.button("Analyze Sentiment of Incident Narratives"):
    if not selected_agencies:
        st.warning("Select at least one agency to run sentiment analysis.")
    else:
        with st.spinner("Running CORTEX.SENTIMENT on narrative text…"):
            st.session_state.sentiment_df = run_cortex_sentiment(
                start_date, end_date, selected_agencies
            )

if st.session_state.sentiment_df is not None:
    sdf = st.session_state.sentiment_df

    if sdf.empty:
        st.info("No Critical or High incidents in the selected date window and agencies.")
    else:
        # Color-code sentiment scores for readability
        def color_sentiment(val):
            if val < -0.3:
                return "background-color: #ffe5e5"
            elif val > 0.3:
                return "background-color: #e5ffe5"
            return ""

        styled = (
            sdf.rename(columns={
                "INCIDENT_ID":        "Incident",
                "AGENCY":             "Agency",
                "SEVERITY":           "Severity",
                "NARRATIVE_PREVIEW":  "Narrative (preview)",
                "SENTIMENT_SCORE":    "Sentiment",
            })
            .style.map(color_sentiment, subset=["Sentiment"])
        )
        st.dataframe(styled, use_container_width=True, hide_index=True)
        st.caption(
            "Red rows indicate strongly negative sentiment (high-stress, severe incident language). "
            "Results capped at 25 rows. Scores sourced from Snowflake Cortex — no external API calls."
        )


# ===========================================================================
# FOOTER
# ===========================================================================

st.divider()
st.caption(
    "**Data pipeline note:** Charts and metrics query `CYBER_INCIDENTS_SUMMARY`, a Snowflake Dynamic Table "
    "with `TARGET_LAG = 1 minute`. Any row inserted into `CYBER_INCIDENTS_RAW` will be reflected in these "
    "charts within the lag window — no ETL job or manual refresh required. "
    "Try it live: `INSERT INTO CYBER_INCIDENTS_RAW VALUES (...)` in a Snowsight worksheet, "
    "then hit ⌘R / Ctrl+R here."
)
