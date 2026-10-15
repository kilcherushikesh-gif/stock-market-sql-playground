/* =====================================================================
   STOCK MARKET ANALYSIS IN SQL
   Six NSE stocks, 2015-01-01 to 2018-07-31 (889 trading days each)
   Tables : bajaj_auto, eicher_motors, hero_motocorp, infosys, tcs, tvs_motors
   Dialect: SQLite 3.25+ (window functions). MySQL 8 differences are noted
            in comments where they matter (YEAR(), `signal`, CREATE FUNCTION).
   Re-runnable: every table we create starts with DROP TABLE IF EXISTS.
   ===================================================================== */


/* ---------------------------------------------------------------------
   PART 1 - GET TO KNOW THE DATA
   --------------------------------------------------------------------- */

-- Task 1: How much history do we have? (Bajaj Auto)
SELECT COUNT(*)  AS trading_days,
       MIN(date) AS first_day,
       MAX(date) AS last_day
FROM bajaj_auto;
-- Expect: 889 | 2015-01-01 | 2018-07-31


-- Task 2: Eicher's five best closes
SELECT date, close_price
FROM eicher_motors
ORDER BY close_price DESC
LIMIT 5;
-- Result: top close 32,786.40; all five dates fall in September 2017


-- Task 3: TCS average close, year by year
-- (MySQL: replace strftime('%Y', date) with YEAR(date))
SELECT strftime('%Y', date)       AS year,
       ROUND(AVG(close_price), 2) AS avg_close
FROM tcs
GROUP BY strftime('%Y', date)
ORDER BY year;
-- Expect: 4 rows, 2016 = 2419.00.  2018 has only 7 months. See task 12 for why TCS is distorted.


-- Task 4: Find the holes - rows where deliverable_qty is NULL, all six stocks
SELECT 'bajaj_auto'    AS stock, date FROM bajaj_auto    WHERE deliverable_qty IS NULL
UNION ALL
SELECT 'eicher_motors' AS stock, date FROM eicher_motors WHERE deliverable_qty IS NULL
UNION ALL
SELECT 'hero_motocorp' AS stock, date FROM hero_motocorp WHERE deliverable_qty IS NULL
UNION ALL
SELECT 'infosys'       AS stock, date FROM infosys       WHERE deliverable_qty IS NULL
UNION ALL
SELECT 'tcs'           AS stock, date FROM tcs           WHERE deliverable_qty IS NULL
UNION ALL
SELECT 'tvs_motors'    AS stock, date FROM tvs_motors    WHERE deliverable_qty IS NULL;
-- Expect: 6 rows, one per stock, on only 2 distinct dates -> an exchange-side reporting gap


/* ---------------------------------------------------------------------
   PART 2 - THE ASSIGNMENT: 20/50-DAY MOVING AVERAGES AND GOLDEN CROSS
   --------------------------------------------------------------------- */

-- Task 5: bajaj1 = date, close_price, ma20, ma50
-- A window of n days = ROWS BETWEEN (n-1) PRECEDING AND CURRENT ROW.
-- The CASE blanks out the first n-1 rows, which only have partial windows.
DROP TABLE IF EXISTS bajaj1;
CREATE TABLE bajaj1 AS
SELECT
  date,
  close_price,
  CASE WHEN ROW_NUMBER() OVER (ORDER BY date) >= 20
       THEN ROUND(AVG(close_price) OVER (ORDER BY date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW), 2)
  END AS ma20,
  CASE WHEN ROW_NUMBER() OVER (ORDER BY date) >= 50
       THEN ROUND(AVG(close_price) OVER (ORDER BY date ROWS BETWEEN 49 PRECEDING AND CURRENT ROW), 2)
  END AS ma50
FROM bajaj_auto;

SELECT * FROM bajaj1 ORDER BY date LIMIT 5;
-- Checkpoints: 889 rows; first ma20 = 2015-01-29 (2415.53); first ma50 = 2015-03-13 (2283.80);
--              2018-07-31 ma20 = 2918.51


-- Task 6: master_table = one row per date, closing price of every stock
-- Step 1: sanity-check that all six tables trade on the same days (expect 889)
SELECT COUNT(*) AS matching_days
FROM bajaj_auto b
JOIN tcs           t ON t.date = b.date
JOIN tvs_motors    v ON v.date = b.date
JOIN infosys       i ON i.date = b.date
JOIN eicher_motors e ON e.date = b.date
JOIN hero_motocorp h ON h.date = b.date;

DROP TABLE IF EXISTS master_table;
CREATE TABLE master_table AS
SELECT b.date,
       b.close_price AS bajaj,
       t.close_price AS tcs,
       v.close_price AS tvs,
       i.close_price AS infosys,
       e.close_price AS eicher,
       h.close_price AS hero
FROM bajaj_auto b
JOIN tcs           t ON t.date = b.date
JOIN tvs_motors    v ON v.date = b.date
JOIN infosys       i ON i.date = b.date
JOIN eicher_motors e ON e.date = b.date
JOIN hero_motocorp h ON h.date = b.date;

SELECT * FROM master_table ORDER BY date DESC LIMIT 3;
-- Checkpoint: 889 rows, 7 columns; 2018-07-31 -> bajaj 2700.70, tvs 517.45


-- Task 7: bajaj2 = date, close_price, signal  (Buy / Sell / Hold)
-- A cross is a CHANGE between yesterday and today, so we need LAG().
-- (MySQL: `signal` is a reserved word - write it with backticks)
DROP TABLE IF EXISTS bajaj2;
CREATE TABLE bajaj2 AS
WITH t AS (
  SELECT date, close_price, ma20, ma50,
         LAG(ma20) OVER (ORDER BY date) AS prev_ma20,
         LAG(ma50) OVER (ORDER BY date) AS prev_ma50
  FROM bajaj1
)
SELECT date, close_price,
  CASE
    WHEN ma20 IS NULL OR ma50 IS NULL OR prev_ma20 IS NULL OR prev_ma50 IS NULL THEN 'Hold'
    WHEN ma20 > ma50 AND prev_ma20 <= prev_ma50 THEN 'Buy'    -- crossed above today
    WHEN ma20 < ma50 AND prev_ma20 >= prev_ma50 THEN 'Sell'   -- crossed below today
    ELSE 'Hold'
  END AS signal
FROM t;

SELECT MIN(CASE WHEN signal = 'Buy'  THEN date END) AS first_buy,
       MIN(CASE WHEN signal = 'Sell' THEN date END) AS first_sell
FROM bajaj2;
-- Checkpoint: first Buy 2015-05-18, first Sell 2015-08-24


-- Task 8: How often did it trigger?
SELECT signal, COUNT(*) AS days
FROM bajaj2
GROUP BY signal
ORDER BY signal;
-- Checkpoint: Buy / Hold / Sell, summing to 889


-- Task 9: Signal on a given day
-- (MySQL: wrap this in CREATE FUNCTION bajaj_signal(d DATE) - see Appendix B of the guide)
SELECT signal
FROM bajaj2
WHERE date = '2018-06-21';
-- Checkpoint sanity: 2015-05-18 -> Buy, 2016-01-04 -> Hold, a Sunday -> no row


-- Task 10: All six stocks in ONE query (no twelve tables)
-- prices -> ma -> lagged -> sig -> latest, one CTE at a time.
-- Every window uses PARTITION BY stock so one stock never leaks into the next.
WITH prices AS (
  SELECT 'Bajaj Auto'    AS stock, date, close_price FROM bajaj_auto
  UNION ALL SELECT 'Eicher Motors',  date, close_price FROM eicher_motors
  UNION ALL SELECT 'Hero Motocorp',  date, close_price FROM hero_motocorp
  UNION ALL SELECT 'Infosys',        date, close_price FROM infosys
  UNION ALL SELECT 'TCS',            date, close_price FROM tcs
  UNION ALL SELECT 'TVS Motors',     date, close_price FROM tvs_motors
),
ma AS (
  SELECT stock, date, close_price,
    CASE WHEN ROW_NUMBER() OVER (PARTITION BY stock ORDER BY date) >= 20
         THEN AVG(close_price) OVER (PARTITION BY stock ORDER BY date ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) END AS ma20,
    CASE WHEN ROW_NUMBER() OVER (PARTITION BY stock ORDER BY date) >= 50
         THEN AVG(close_price) OVER (PARTITION BY stock ORDER BY date ROWS BETWEEN 49 PRECEDING AND CURRENT ROW) END AS ma50
  FROM prices
),
lagged AS (
  SELECT stock, date, close_price, ma20, ma50,
         LAG(ma20) OVER (PARTITION BY stock ORDER BY date) AS prev_ma20,
         LAG(ma50) OVER (PARTITION BY stock ORDER BY date) AS prev_ma50
  FROM ma
),
sig AS (
  SELECT stock, date, close_price,
    CASE
      WHEN ma20 IS NULL OR ma50 IS NULL OR prev_ma20 IS NULL OR prev_ma50 IS NULL THEN 'Hold'
      WHEN ma20 > ma50 AND prev_ma20 <= prev_ma50 THEN 'Buy'
      WHEN ma20 < ma50 AND prev_ma20 >= prev_ma50 THEN 'Sell'
      ELSE 'Hold'
    END AS signal
  FROM lagged
),
latest AS (
  SELECT stock, date, signal,
         ROW_NUMBER() OVER (PARTITION BY stock ORDER BY date DESC) AS rn
  FROM sig
  WHERE signal <> 'Hold'
)
SELECT s.stock,
       SUM(s.signal = 'Buy')  AS buys,
       SUM(s.signal = 'Sell') AS sells,
       l.date                 AS last_signal_date,
       l.signal               AS last_signal
FROM sig s
JOIN latest l ON l.stock = s.stock AND l.rn = 1
GROUP BY s.stock
ORDER BY s.stock;
-- Checkpoint: 6 rows; 56 Buys and 57 Sells in total; Bajaj row matches tasks 8 and 9


/* ---------------------------------------------------------------------
   PART 3 - QUESTION THE RESULT
   --------------------------------------------------------------------- */

-- Task 11: Who went up? First close vs last close
WITH prices AS (
  SELECT 'Bajaj Auto'    AS stock, date, close_price FROM bajaj_auto
  UNION ALL SELECT 'Eicher Motors',  date, close_price FROM eicher_motors
  UNION ALL SELECT 'Hero Motocorp',  date, close_price FROM hero_motocorp
  UNION ALL SELECT 'Infosys',        date, close_price FROM infosys
  UNION ALL SELECT 'TCS',            date, close_price FROM tcs
  UNION ALL SELECT 'TVS Motors',     date, close_price FROM tvs_motors
),
ends AS (
  SELECT stock, MIN(date) AS first_date, MAX(date) AS last_date
  FROM prices
  GROUP BY stock
)
SELECT e.stock,
       f.close_price AS first_close,
       l.close_price AS last_close,
       ROUND(100.0 * (l.close_price - f.close_price) / f.close_price, 1) AS pct_change
FROM ends e
JOIN prices f ON f.stock = e.stock AND f.date = e.first_date
JOIN prices l ON l.stock = e.stock AND l.date = e.last_date
ORDER BY pct_change DESC;
-- Checkpoint: TVS Motors tops at 86.9%; two stocks negative (TCS and Infosys - both are artefacts, see task 12)


-- Task 12: The data trap - each stock's single worst day (day-over-day % move)
WITH prices AS (
  SELECT 'Bajaj Auto'    AS stock, date, close_price FROM bajaj_auto
  UNION ALL SELECT 'Eicher Motors',  date, close_price FROM eicher_motors
  UNION ALL SELECT 'Hero Motocorp',  date, close_price FROM hero_motocorp
  UNION ALL SELECT 'Infosys',        date, close_price FROM infosys
  UNION ALL SELECT 'TCS',            date, close_price FROM tcs
  UNION ALL SELECT 'TVS Motors',     date, close_price FROM tvs_motors
),
moves AS (
  SELECT stock, date, close_price,
         100.0 * (close_price / LAG(close_price) OVER (PARTITION BY stock ORDER BY date) - 1) AS pct_move
  FROM prices
),
ranked AS (
  SELECT stock, date, close_price, pct_move,
         ROW_NUMBER() OVER (PARTITION BY stock ORDER BY pct_move ASC) AS rn
  FROM moves
  WHERE pct_move IS NOT NULL            -- drop each stock's first day (NULL sorts first in SQLite)
)
SELECT stock, date, close_price, ROUND(pct_move, 1) AS pct_move
FROM ranked
WHERE rn = 1
ORDER BY pct_move;
-- Finding: Infosys on 2015-06-15 (-49.9%) and TCS on 2018-05-31 (-50.4%).
-- Both are 1:1 BONUS ISSUES (shares double, price halves, nobody loses money), not crashes.


-- Task 13: Fix it - adjust TCS and Infosys for the bonus issues, then re-measure
-- Divide every price BEFORE the event by the factor (2). Event date = first day at the new level.
WITH adjusted AS (
  SELECT 'TCS' AS stock, date,
         CASE WHEN date < '2018-05-31' THEN close_price / 2.0 ELSE close_price END AS adj_close
  FROM tcs
  UNION ALL
  SELECT 'Infosys' AS stock, date,
         CASE WHEN date < '2015-06-15' THEN close_price / 2.0 ELSE close_price END AS adj_close
  FROM infosys
)
SELECT stock,
       ROUND(100.0 * (MAX(CASE WHEN date = '2018-07-31' THEN adj_close END) /
                      MAX(CASE WHEN date = '2015-01-01' THEN adj_close END) - 1), 1) AS adjusted_pct_change
FROM adjusted
GROUP BY stock
ORDER BY stock;
-- Result: Infosys +38.2% (was -30.9%), TCS +52.4% (was -23.8%) -> both "losers" were artefacts.


/* ---------------------------------------------------------------------
   PART 4 - STRETCH AND EXTRA INSIGHTS (feed the insights PDF)
   --------------------------------------------------------------------- */

-- Task 14 (stretch): rebuild the signals on ADJUSTED prices for all six stocks.
-- adj_prices is persisted so tasks 14-17 can reuse it.
DROP TABLE IF EXISTS adj_prices;
CREATE TABLE adj_prices AS
SELECT 'Bajaj Auto' AS stock, date, close_price, close_price AS adj_close FROM bajaj_auto
UNION ALL SELECT 'Eicher Motors', date, close_price, close_price FROM eicher_motors
UNION ALL SELECT 'Hero Motocorp', date, close_price, close_price FROM hero_motocorp
UNION ALL SELECT 'TVS Motors',    date, close_price, close_price FROM tvs_motors
UNION ALL SELECT 'Infosys', date, close_price,
         CASE WHEN date < '2015-06-15' THEN close_price / 2.0 ELSE close_price END FROM infosys
UNION ALL SELECT 'TCS', date, close_price,
         CASE WHEN date < '2018-05-31' THEN close_price / 2.0 ELSE close_price END FROM tcs;

-- Signals on raw prices (sig_raw) and on adjusted prices (sig_adj), same logic as task 10.
DROP TABLE IF EXISTS signals;
CREATE TABLE signals AS
WITH ma AS (
  SELECT stock, date, close_price, adj_close,
    CASE WHEN ROW_NUMBER() OVER w >= 20 THEN AVG(close_price) OVER (w ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) END AS r20,
    CASE WHEN ROW_NUMBER() OVER w >= 50 THEN AVG(close_price) OVER (w ROWS BETWEEN 49 PRECEDING AND CURRENT ROW) END AS r50,
    CASE WHEN ROW_NUMBER() OVER w >= 20 THEN AVG(adj_close)   OVER (w ROWS BETWEEN 19 PRECEDING AND CURRENT ROW) END AS a20,
    CASE WHEN ROW_NUMBER() OVER w >= 50 THEN AVG(adj_close)   OVER (w ROWS BETWEEN 49 PRECEDING AND CURRENT ROW) END AS a50
  FROM adj_prices
  WINDOW w AS (PARTITION BY stock ORDER BY date)
),
lagged AS (
  SELECT *, LAG(r20) OVER w AS pr20, LAG(r50) OVER w AS pr50,
            LAG(a20) OVER w AS pa20, LAG(a50) OVER w AS pa50
  FROM ma
  WINDOW w AS (PARTITION BY stock ORDER BY date)
)
SELECT stock, date, close_price, adj_close, r20, r50, a20, a50,
  CASE WHEN r20 IS NULL OR r50 IS NULL OR pr20 IS NULL OR pr50 IS NULL THEN 'Hold'
       WHEN r20 > r50 AND pr20 <= pr50 THEN 'Buy'
       WHEN r20 < r50 AND pr20 >= pr50 THEN 'Sell' ELSE 'Hold' END AS sig_raw,
  CASE WHEN a20 IS NULL OR a50 IS NULL OR pa20 IS NULL OR pa50 IS NULL THEN 'Hold'
       WHEN a20 > a50 AND pa20 <= pa50 THEN 'Buy'
       WHEN a20 < a50 AND pa20 >= pa50 THEN 'Sell' ELSE 'Hold' END AS sig_adj
FROM lagged;

-- Raw vs adjusted signal counts per stock
SELECT stock,
       SUM(sig_raw = 'Buy')  AS raw_buys,  SUM(sig_raw = 'Sell') AS raw_sells,
       SUM(sig_adj = 'Buy')  AS adj_buys,  SUM(sig_adj = 'Sell') AS adj_sells,
       SUM(sig_raw <> sig_adj) AS days_that_differ
FROM signals
GROUP BY stock
ORDER BY stock;

-- Which TCS / Infosys signals were created or removed by the price cliff?
SELECT stock, date, sig_raw, sig_adj
FROM signals
WHERE sig_raw <> sig_adj
ORDER BY stock, date;


-- Task 15: Whipsaws - consecutive signals (adjusted) less than 30 calendar days apart.
-- Following these would mean buying and selling within a month, paying costs both ways.
WITH s AS (
  SELECT stock, date, sig_adj AS signal,
         LAG(date)    OVER (PARTITION BY stock ORDER BY date) AS prev_date,
         LAG(sig_adj) OVER (PARTITION BY stock ORDER BY date) AS prev_signal
  FROM signals
  WHERE sig_adj <> 'Hold'
)
SELECT stock,
       COUNT(*)                                                    AS gaps_between_signals,
       SUM(julianday(date) - julianday(prev_date) < 30)           AS flips_within_30d,
       ROUND(AVG(julianday(date) - julianday(prev_date)), 0)      AS avg_days_between_signals,
       MIN(julianday(date) - julianday(prev_date))                AS shortest_gap_days
FROM s
WHERE prev_date IS NOT NULL
GROUP BY stock
ORDER BY stock;


-- Task 16: What would following the signals have returned?
-- Rule: buy at the close on a Buy day, sell at the close on the next Sell day
-- (or at the last close if still holding). Adjusted prices, no costs, one share at a time.
-- Compare with simply buying on day 1 and holding.
DROP TABLE IF EXISTS trades;
CREATE TABLE trades AS
WITH s AS (
  SELECT stock, date, adj_close, sig_adj,
         LEAD(date)      OVER (PARTITION BY stock ORDER BY date) AS next_date,
         LEAD(adj_close) OVER (PARTITION BY stock ORDER BY date) AS next_close
  FROM signals
  WHERE sig_adj <> 'Hold'
),
last_day AS (
  SELECT stock, MAX(date) AS last_date FROM signals GROUP BY stock
)
SELECT s.stock,
       s.date AS buy_date, s.adj_close AS buy_price,
       COALESCE(s.next_date,  l.last_date)                              AS exit_date,
       COALESCE(s.next_close, (SELECT adj_close FROM signals x
                               WHERE x.stock = s.stock AND x.date = l.last_date)) AS exit_price,
       s.next_date IS NULL AS still_open
FROM s
JOIN last_day l ON l.stock = s.stock
WHERE s.sig_adj = 'Buy';

SELECT stock,
       COUNT(*)                                                        AS round_trips,
       ROUND(100.0 * AVG(exit_price > buy_price), 0)                   AS win_rate_pct,
       ROUND(AVG(100.0 * (exit_price / buy_price - 1)), 1)             AS avg_trade_pct,
       ROUND(SUM(100.0 * (exit_price / buy_price - 1)), 1)             AS sum_of_trade_pct
FROM trades
GROUP BY stock
ORDER BY stock;

-- Compounded return of following every signal (portable recursive CTE; no math functions needed)
WITH RECURSIVE numbered AS (
  SELECT stock, buy_date, exit_price / buy_price AS gross,
         ROW_NUMBER() OVER (PARTITION BY stock ORDER BY buy_date) AS n
  FROM trades
),
compound AS (
  SELECT stock, n, gross AS growth FROM numbered WHERE n = 1
  UNION ALL
  SELECT c.stock, nu.n, c.growth * nu.gross
  FROM compound c
  JOIN numbered nu ON nu.stock = c.stock AND nu.n = c.n + 1
)
SELECT stock, ROUND(100.0 * (growth - 1), 1) AS strategy_compounded_pct
FROM compound
WHERE n = (SELECT MAX(n) FROM numbered x WHERE x.stock = compound.stock)
ORDER BY stock;

-- Buy-and-hold on the same adjusted prices, for comparison
SELECT stock,
       ROUND(100.0 * (MAX(CASE WHEN date = '2018-07-31' THEN adj_close END) /
                      MAX(CASE WHEN date = '2015-01-01' THEN adj_close END) - 1), 1) AS buy_and_hold_pct
FROM adj_prices
GROUP BY stock
ORDER BY stock;


-- Task 17: Does the latest signal agree with the long-run trend?
-- Latest non-Hold signal vs. whether the last close is above its own 50-day average
-- and the adjusted 1-year change.
WITH latest AS (
  SELECT stock, date, sig_adj,
         ROW_NUMBER() OVER (PARTITION BY stock ORDER BY date DESC) AS rn
  FROM signals WHERE sig_adj <> 'Hold'
),
final_day AS (
  SELECT stock, adj_close AS last_adj, a20, a50 FROM signals WHERE date = '2018-07-31'
),
year_ago AS (
  SELECT stock, adj_close AS adj_1y_ago FROM signals WHERE date = '2017-07-31'
)
SELECT f.stock,
       l.date    AS last_signal_date,
       l.sig_adj AS last_signal,
       ROUND(f.last_adj, 2) AS last_close_adj,
       ROUND(f.a20, 2) AS ma20, ROUND(f.a50, 2) AS ma50,
       CASE WHEN f.a20 > f.a50 THEN 'ma20 above ma50 (uptrend)' ELSE 'ma20 below ma50 (downtrend)' END AS state_now,
       ROUND(100.0 * (f.last_adj / y.adj_1y_ago - 1), 1) AS pct_change_last_12m
FROM final_day f
JOIN latest   l ON l.stock = f.stock AND l.rn = 1
JOIN year_ago y ON y.stock = f.stock
ORDER BY f.stock;
