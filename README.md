# Stock market analysis in SQL

[Open the live interactive app](https://nse-stock-market-explorer.streamlit.app/)

- `stock_market_analysis.sql` - all 17 tasks (SQLite; MySQL notes in comments). `sqlite3 stocks.db < stock_market_analysis.sql` after `python build_db.py`.
- `Stock_Market_Insights.pdf` - insights report (built by `gen_report.py` from the SQL results).
- `app.py` - Streamlit live SQL playground: `pip install -r requirements.txt && streamlit run app.py`
- `data/` - the six source CSVs; `build_db.py` loads them into SQLite with ISO dates.
