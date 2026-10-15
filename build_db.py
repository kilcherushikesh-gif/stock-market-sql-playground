"""Load the six NSE CSVs into SQLite with ISO dates and NULLs for blanks."""
import sqlite3, sys, pandas as pd
from pathlib import Path
base = Path(__file__).parent
out = sys.argv[1] if len(sys.argv) > 1 else str(base / "stocks.db")
files = {"bajaj_auto":"Bajaj_Auto","eicher_motors":"Eicher_Motors","hero_motocorp":"Hero_Motocorp",
         "infosys":"Infosys","tcs":"TCS","tvs_motors":"TVS_Motors"}
cols = ["date","open_price","high_price","low_price","close_price","wap","no_of_shares","no_of_trades",
        "total_turnover","deliverable_qty","pct_deli_qty","spread_high_low","spread_close_open"]
import os
if os.path.exists(out): os.remove(out)
con = sqlite3.connect(out)
for t, f in files.items():
    df = pd.read_csv(base/"data"/f"{f}.csv", skipinitialspace=True)
    df.columns = cols
    df["date"] = pd.to_datetime(df["date"], format="%d-%B-%Y").dt.strftime("%Y-%m-%d")
    df = df.sort_values("date")
    df.to_sql(t, con, index=False)
    con.execute(f"CREATE UNIQUE INDEX idx_{t}_date ON {t}(date)")
con.commit(); con.close()
