"""FAC (First Attempt Completion) delivery performance dashboard."""

from datetime import datetime
from pathlib import Path

import pandas as pd

import streamlit as st

st.set_page_config(
    page_title="FAC delivery dashboard",
    page_icon=":material/local_shipping:",
    layout="wide",
)

DATA_PATH = Path(__file__).parent / "6f43030b2b8721b5df58308dc1d05eb8.csv"

REASON_COLS = [
    "orc",
    "ica",
    "osm",
    "untraceable",
    "damage",
    "nss",
    "ssm",
    "heavy_load",
    "cnr",
    "rfr",
    "no_status_captured",
]

REASON_LABELS = {
    "orc": "ORC",
    "ica": "ICA",
    "osm": "OSM",
    "untraceable": "Untraceable",
    "damage": "Damage",
    "nss": "NSS",
    "ssm": "SSM",
    "heavy_load": "Heavy load",
    "cnr": "CNR",
    "rfr": "RFR",
    "no_status_captured": "No status captured",
}

CHART_HEIGHT = 320


@st.cache_data(ttl="1h", show_spinner="Loading FAC data...")
def load_data() -> pd.DataFrame:
    df = pd.read_csv(DATA_PATH)
    df["reporting_date"] = pd.to_datetime(df["reporting_date"], format="%Y%m%d")
    df = df.dropna(subset=["seller_type", "destination_state"])
    df = df.rename(columns={"first_attempt_delivered": "fac_delivered"})
    df["fac_delivered"] = df["fac_delivered"].fillna(0)
    df["fac_deno"] = df["fac_deno"].fillna(0)
    return df


def filter_data(
    df: pd.DataFrame,
    date_range: tuple[datetime, datetime],
    sellers: list[str],
    states: list[str],
) -> pd.DataFrame:
    start, end = date_range
    mask = (df["reporting_date"] >= pd.Timestamp(start)) & (
        df["reporting_date"] <= pd.Timestamp(end)
    )
    if sellers:
        mask &= df["seller_type"].isin(sellers)
    if states:
        mask &= df["destination_state"].isin(states)
    return df[mask]


def render_kpi_row(df: pd.DataFrame) -> None:
    fac_delivered = int(df["fac_delivered"].sum())
    fac_deno = int(df["fac_deno"].sum())
    fac_pct = (fac_delivered / fac_deno * 100) if fac_deno else 0.0
    failed = fac_deno - fac_delivered

    with st.container(horizontal=True):
        st.metric("FAC denominator", f"{fac_deno:,}", border=True)
        st.metric("FAC delivered", f"{fac_delivered:,}", border=True)
        st.metric("FAC %", f"{fac_pct:.1f}%", border=True)
        st.metric("Failed / undelivered", f"{failed:,}", border=True)


def render_trend_table(df: pd.DataFrame) -> None:
    daily = (
        df.groupby("reporting_date")[["fac_deno", "fac_delivered"]]
        .sum()
        .reset_index()
    )
    daily["fac_pct"] = (daily["fac_delivered"] / daily["fac_deno"] * 100).round(1)
    daily["failed"] = daily["fac_deno"] - daily["fac_delivered"]
    daily["note"] = daily["failed"].apply(
        lambda f: "Reporting lag: FAC delivered exceeds denominator" if f < 0 else ""
    )
    daily = daily.sort_values("reporting_date", ascending=False)
    daily.columns = [
        "Date",
        "FAC denominator",
        "FAC delivered",
        "FAC %",
        "Failed",
        "Note",
    ]

    st.dataframe(
        daily,
        hide_index=True,
        height=CHART_HEIGHT,
        column_config={
            "Date": st.column_config.DateColumn("Date", format="YYYY-MM-DD"),
        },
    )
    if (daily["Failed"] < 0).any():
        st.caption(
            ":material/info: Rows flagged above have FAC delivered > FAC denominator — "
            "these are reported on different lags near the most recent dates, "
            "so same-day totals aren't directly comparable yet."
        )


def render_reason_breakdown(df: pd.DataFrame) -> None:
    reason_totals = df[REASON_COLS].sum()
    reason_totals = reason_totals[reason_totals > 0].sort_values(ascending=False)
    total = reason_totals.sum()
    reason_df = pd.DataFrame(
        {
            "Reason": [REASON_LABELS[r] for r in reason_totals.index],
            "Count": reason_totals.to_numpy(),
        }
    )
    reason_df["% of undelivered"] = (reason_df["Count"] / total * 100).round(1)

    st.dataframe(
        reason_df,
        hide_index=True,
        height=CHART_HEIGHT,
    )


def render_state_breakdown(df: pd.DataFrame) -> None:
    state_df = (
        df.groupby("destination_state")[["fac_deno", "fac_delivered"]]
        .sum()
        .reset_index()
    )
    state_df["fac_pct"] = (state_df["fac_delivered"] / state_df["fac_deno"] * 100).round(1)
    state_df = state_df.sort_values("fac_deno", ascending=False)
    state_df.columns = ["State", "FAC denominator", "FAC delivered", "FAC %"]

    st.dataframe(
        state_df,
        hide_index=True,
        height=CHART_HEIGHT,
        column_config={
            "FAC %": st.column_config.ProgressColumn(
                "FAC %", min_value=0, max_value=100, format="%.1f%%"
            ),
        },
    )


def render_reason_by_dimension(
    df: pd.DataFrame, dimension_col: str, dimension_label: str, as_pct: bool = False
) -> None:
    grouped = df.groupby(dimension_col)[
        ["fac_deno", "fac_delivered", *REASON_COLS]
    ].sum()
    grouped = grouped[grouped["fac_deno"] > 0]
    grouped["fac_pct"] = (grouped["fac_delivered"] / grouped["fac_deno"] * 100).round(1)
    grouped = grouped.sort_values("fac_deno", ascending=False).reset_index()

    non_zero_reasons = [c for c in REASON_COLS if grouped[c].sum() > 0]

    if as_pct:
        for c in non_zero_reasons:
            grouped[c] = (grouped[c] / grouped["fac_deno"] * 100).round(1)

    ordered_cols = [
        dimension_col,
        "fac_deno",
        "fac_delivered",
        "fac_pct",
        *non_zero_reasons,
    ]
    grouped = grouped[ordered_cols]
    grouped.columns = [
        dimension_label,
        "FAC denominator",
        "FAC delivered",
        "FAC %",
        *[REASON_LABELS[c] for c in non_zero_reasons],
    ]

    reason_column_config = {
        REASON_LABELS[c]: st.column_config.NumberColumn(REASON_LABELS[c], format="%.1f%%")
        for c in non_zero_reasons
    } if as_pct else {}

    st.dataframe(
        grouped,
        hide_index=True,
        height=CHART_HEIGHT + 100,
        column_config={
            "FAC %": st.column_config.ProgressColumn(
                "FAC %", min_value=0, max_value=100, format="%.1f%%"
            ),
            **reason_column_config,
        },
    )


def render_seller_table(df: pd.DataFrame) -> None:
    seller_df = (
        df.groupby("seller_type")[["fac_deno", "fac_delivered"]]
        .sum()
        .reset_index()
    )
    seller_df["fac_pct"] = (
        seller_df["fac_delivered"] / seller_df["fac_deno"] * 100
    ).round(1)
    seller_df = seller_df.sort_values("fac_deno", ascending=False)
    seller_df.columns = ["Seller", "FAC denominator", "FAC delivered", "FAC %"]

    st.dataframe(
        seller_df,
        hide_index=True,
        height=CHART_HEIGHT,
        column_config={
            "FAC %": st.column_config.ProgressColumn(
                "FAC %", min_value=0, max_value=100, format="%.1f%%"
            ),
        },
    )


# =============================================================================
# Page layout
# =============================================================================

df = load_data()
min_date = df["reporting_date"].min().date()
max_date = df["reporting_date"].max().date()

st.markdown("# :material/local_shipping: FAC delivery dashboard")

date_range = st.date_input(
    "Reporting date range",
    value=(min_date, max_date),
    min_value=min_date,
    max_value=max_date,
)
if len(date_range) != 2:
    date_range = (min_date, max_date)

with st.sidebar:
    st.markdown("### Filters")
    all_sellers = sorted(df["seller_type"].unique())
    sellers = st.multiselect("Seller type", all_sellers)

    all_states = sorted(df["destination_state"].unique())
    states = st.multiselect("Destination state", all_states)

filtered = filter_data(df, date_range, sellers, states)

if filtered.empty:
    st.info("No data for the selected filters.")
else:
    render_kpi_row(filtered)

    with st.container(border=True):
        st.markdown("**Daily volume & FAC % trend**")
        render_trend_table(filtered)

    col1, col2 = st.columns(2)
    with col1:
        with st.container(border=True):
            st.markdown("**Undelivered reason breakdown**")
            render_reason_breakdown(filtered)
    with col2:
        with st.container(border=True):
            st.markdown("**State-wise volume & FAC %**")
            render_state_breakdown(filtered)

    with st.container(border=True):
        st.markdown("**Seller performance**")
        render_seller_table(filtered)

    with st.container(border=True):
        header_col1, header_col2 = st.columns([3, 1])
        with header_col1:
            st.markdown("**Reason breakdown by dimension**")
            dimension = st.segmented_control(
                "Group by",
                options=["Seller", "State"],
                default="Seller",
                key="reason_dimension",
            )
        with header_col2:
            units1 = st.segmented_control(
                "Units",
                options=["Number", "%"],
                default="Number",
                key="reason_dimension_units",
            )
        if dimension == "State":
            render_reason_by_dimension(
                filtered, "destination_state", "State", as_pct=(units1 == "%")
            )
        else:
            render_reason_by_dimension(
                filtered, "seller_type", "Seller", as_pct=(units1 == "%")
            )

    with st.container(border=True):
        header_col1, header_col2 = st.columns([3, 1])
        with header_col1:
            st.markdown("**Seller x state reason breakdown**")
            seller_choice = st.selectbox(
                "Seller",
                sorted(filtered["seller_type"].unique()),
                key="seller_state_drilldown",
            )
        with header_col2:
            units2 = st.segmented_control(
                "Units",
                options=["Number", "%"],
                default="Number",
                key="seller_state_units",
            )
        seller_filtered = filtered[filtered["seller_type"] == seller_choice]
        render_reason_by_dimension(
            seller_filtered, "destination_state", "State", as_pct=(units2 == "%")
        )
