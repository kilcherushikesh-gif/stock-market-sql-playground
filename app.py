"""Live SQL playground for the six-stock NSE dataset (SQLite, in-memory, per session)."""
import re, sqlite3, subprocess, sys, tempfile, os
from pathlib import Path
import pandas as pd
import streamlit as st

BASE = Path(__file__).parent
st.set_page_config(page_title="NSE Stock Explorer", page_icon=":material/monitoring:", layout="wide")

@st.cache_resource
def master_db_path() -> str:
    path = os.path.join(tempfile.gettempdir(), "stocks_master.db")
    subprocess.run([sys.executable, str(BASE / "build_db.py"), path], check=True)
    return path

def fresh_conn() -> sqlite3.Connection:
    src = sqlite3.connect(master_db_path()); dst = sqlite3.connect(":memory:", check_same_thread=False)
    src.backup(dst); src.close(); return dst

if "conn" not in st.session_state:
    st.session_state.conn = fresh_conn()
conn = st.session_state.conn

def load_examples():
    text = (BASE / "stock_market_analysis.sql").read_text()
    parts = re.split(r"(?m)^-- (Task \d+[^\n]*)\n", text)
    ex = {}
    for title, body in zip(parts[1::2], parts[2::2]):
        body = re.split(r"/\* -{10,}", body)[0].strip()
        ex[title.strip()] = body
    return ex
EXAMPLES = load_examples()

def split_statements(sql):
    out, buf = [], ""
    for line in sql.splitlines(keepends=True):
        buf += line
        if sqlite3.complete_statement(buf):
            out.append(buf.strip()); buf = ""
    if buf.strip(): out.append(buf.strip())
    return [s for s in out if re.sub(r"--[^\n]*", "", s).strip(" ;\n\t")]

def run(sql):
    last, ran = None, 0
    for stmt in split_statements(sql):
        cur = conn.execute(stmt); ran += 1
        if cur.description: last = pd.DataFrame(cur.fetchall(), columns=[d[0] for d in cur.description])
    conn.commit(); return last, ran

STOCK_NAMES = {
    "bajaj_auto": "Bajaj Auto",
    "eicher_motors": "Eicher Motors",
    "hero_motocorp": "Hero MotoCorp",
    "infosys": "Infosys",
    "tcs": "TCS",
    "tvs_motors": "TVS Motors",
}
MARKET_METRICS = {
    "Close price": "close_price",
    "Daily return": "daily_return",
    "Trading volume": "no_of_shares",
    "Total turnover": "total_turnover",
}

def load_market_data(stock_tables):
    frames = []
    for table in stock_tables:
        frame = pd.read_sql_query(
            f'SELECT date, close_price, no_of_shares, total_turnover FROM "{table}"', conn
        )
        frame["date"] = pd.to_datetime(frame["date"])
        frame["company"] = STOCK_NAMES[table]
        frame["daily_return"] = frame["close_price"].pct_change() * 100
        frames.append(frame)
    return pd.concat(frames, ignore_index=True)

st.title("Stock market analysis", icon=":material/monitoring:")
st.caption("Explore six NSE stocks across 889 trading days, or investigate the data directly with SQL.")

with st.sidebar:
    st.header("Database")
    tables = pd.read_sql_query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", conn)["name"]
    for t in tables:
        n = conn.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]
        with st.expander(f"{t}  ({n:,} rows)"):
            cols = pd.read_sql_query(f'PRAGMA table_info("{t}")', conn)[["name", "type"]]
            st.dataframe(cols, hide_index=True, width="stretch")
    if st.button("Reset database", width="stretch"):
        st.session_state.conn = fresh_conn(); st.session_state.pop("result", None); st.rerun()
    if st.button("Build all tables (run full .sql)", width="stretch"):
        try:
            run((BASE / "stock_market_analysis.sql").read_text()); st.rerun()
        except Exception as e:
            st.error(str(e))
    st.caption("Dates are ISO text (YYYY-MM-DD). Use `strftime('%Y', date)` for the year. "
               "Created tables (bajaj1, bajaj2, master_table, ...) appear here after you run them.")

explorer_tab, sql_tab = st.tabs(["Market explorer", "SQL playground"])

with explorer_tab:
    available_stocks = {
        table: name for table, name in STOCK_NAMES.items() if table in tables.tolist()
    }
    if not available_stocks:
        st.warning("The stock tables are missing. Reset the database from the sidebar to rebuild them.")
    else:
        date_bounds = conn.execute(
            'SELECT MIN(date), MAX(date) FROM "bajaj_auto"'
        ).fetchone()
        min_date, max_date = (pd.Timestamp(value).date() for value in date_bounds)

        stock_col, date_col, metric_col = st.columns([1.4, 1.4, 1], wrap=True)
        with stock_col:
            selected_names = st.multiselect(
                "Companies",
                list(available_stocks.values()),
                default=list(available_stocks.values()),
                key="explorer_companies",
            )
        with date_col:
            date_range = st.date_input(
                "Date range",
                value=(min_date, max_date),
                min_value=min_date,
                max_value=max_date,
                key="explorer_dates",
            )
        with metric_col:
            metric = st.selectbox("Measure", list(MARKET_METRICS), key="explorer_metric")

        rebase = st.toggle(
            "Index close prices to 100",
            value=True,
            disabled=metric != "Close price",
            help="Makes percentage movement comparable across companies with different share prices.",
        )

        if not selected_names:
            st.info("Choose at least one company to explore its market history.")
        elif len(date_range) != 2:
            st.info("Choose both a start date and an end date.")
        else:
            selected_tables = [
                table for table, name in available_stocks.items() if name in selected_names
            ]
            market = load_market_data(selected_tables)
            start_date, end_date = pd.to_datetime(date_range)
            market = market.loc[market["date"].between(start_date, end_date)].copy()

            if market.empty:
                st.info("No trading data is available for this date range.")
            else:
                price_summary = (
                    market.sort_values("date")
                    .groupby("company")["close_price"]
                    .agg(start_close="first", end_close="last")
                )
                price_summary["period_change_pct"] = (
                    price_summary["end_close"] / price_summary["start_close"] - 1
                ) * 100
                leader = price_summary["period_change_pct"].idxmax()
                leader_return = price_summary.loc[leader, "period_change_pct"]
                average_turnover = market["total_turnover"].mean()

                with st.container(horizontal=True):
                    st.metric("Price leader", leader, f"{leader_return:+.2f}%", border=True)
                    st.metric("Trading sessions", f"{market['date'].nunique():,}", border=True)
                    st.metric("Average daily turnover", f"₹{average_turnover:,.0f}", border=True)

                chart_data = market.pivot_table(
                    index="date",
                    columns="company",
                    values=MARKET_METRICS[metric],
                    aggfunc="last",
                ).sort_index()
                if rebase and metric == "Close price":
                    chart_data = chart_data.apply(
                        lambda series: series / series.dropna().iloc[0] * 100
                        if series.notna().any() else series
                    )

                chart_col, download_col = st.columns([5, 1], wrap=True)
                with chart_col:
                    st.subheader(f"{metric} by company")
                with download_col:
                    st.download_button(
                        "Download chart data",
                        chart_data.to_csv().encode("utf-8"),
                        "stock-comparison.csv",
                        "text/csv",
                        icon=":material/download:",
                    )

                chart_type = st.segmented_control(
                    "Chart type", ["Line", "Area"], default="Line", key="explorer_chart_type"
                )
                y_label = "Indexed to 100" if rebase and metric == "Close price" else metric
                if chart_type == "Area":
                    st.area_chart(chart_data, y_label=y_label)
                else:
                    st.line_chart(chart_data, y_label=y_label)

                comparison = price_summary.join(
                    market.groupby("company")["no_of_shares"].mean().rename("average_volume")
                ).reset_index()
                comparison = comparison.rename(columns={
                    "company": "Company",
                    "start_close": "Start close (Rs.)",
                    "end_close": "End close (Rs.)",
                    "period_change_pct": "Change (%)",
                    "average_volume": "Average volume",
                })
                st.subheader("Period comparison")
                st.dataframe(
                    comparison,
                    hide_index=True,
                    column_config={
                        "Start close (Rs.)": st.column_config.NumberColumn(format="₹%.2f"),
                        "End close (Rs.)": st.column_config.NumberColumn(format="₹%.2f"),
                        "Change (%)": st.column_config.NumberColumn(format="%.2f%%"),
                        "Average volume": st.column_config.NumberColumn(format="%,.0f"),
                    },
                )

                with st.expander("Browse filtered trading rows"):
                    st.dataframe(market.sort_values(["date", "company"], ascending=[False, True]), hide_index=True)
                    st.download_button(
                        "Download filtered rows",
                        market.to_csv(index=False).encode("utf-8"),
                        "filtered-stock-history.csv",
                        "text/csv",
                        icon=":material/download:",
                    )

with sql_tab:
    st.caption("Tasks 7-9 and 14-17 use tables made by earlier tasks. Run the tasks in order, or press **Build all tables** in the sidebar first.")
    choice = st.selectbox("Load an example", ["(blank)"] + list(EXAMPLES), index=1 if EXAMPLES else 0)
    default = EXAMPLES.get(choice, "SELECT * FROM bajaj_auto LIMIT 5;")
    if st.session_state.get("_choice") != choice:
        st.session_state["_choice"] = choice; st.session_state["sql"] = default
    sql = st.text_area("SQL", key="sql", height=300, help="Several statements allowed; the last SELECT is displayed.")

    if st.button("Run query", type="primary", icon=":material/play_arrow:"):
        try:
            st.session_state.result = run(sql); st.session_state.error = None
        except Exception as e:
            st.session_state.error = str(e); st.session_state.result = None
    if st.session_state.get("error"): st.error(st.session_state.error)

    res = st.session_state.get("result")
    if res:
        df, ran = res
        if df is None:
            st.success(f"{ran} statement(s) ran. No rows to show; check the sidebar for new tables.")
        else:
            t_table, t_chart = st.tabs(["Table", "Chart"])
            with t_table:
                st.caption(f"{len(df):,} rows × {len(df.columns)} columns")
                st.dataframe(df, width="stretch", hide_index=True)
                st.download_button("Download CSV", df.to_csv(index=False), "result.csv", "text/csv")
            with t_chart:
                nums = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c])]
                if not nums or len(df) < 2:
                    st.info("Needs at least two rows and one numeric column.")
                else:
                    xcol = st.selectbox("X axis", list(df.columns), index=0)
                    ycols = st.multiselect("Y columns", [c for c in nums if c != xcol], default=[c for c in nums if c != xcol][:4])
                    kind = st.segmented_control("Type", ["Line", "Bar"], default="Line")
                    rebase = st.checkbox("Rebase to 100 (compare series on one scale)")
                    if ycols:
                        d = df.set_index(xcol)[ycols].copy()
                        if "date" in xcol.lower(): d.index = pd.to_datetime(d.index, errors="coerce")
                        d = d.sort_index()
                        if rebase:
                            d = d.apply(lambda s: s / s.dropna().iloc[0] * 100 if s.notna().any() else s)
                        (st.line_chart if kind == "Line" else st.bar_chart)(d)
