"use client";

import { useEffect, useState, type ReactNode } from "react";
import { CreditTile } from "./Tiles";
import { Sk } from "./Skeleton";

export type ExchangeRow = {
  id: number;
  rating: string;
  gross: string;
  selected: boolean;
  disabled?: boolean;
  note?: string;
};

// received: the $BALANCE the receipt's fills paid; undefined only if the receipt could not be read (then "≥ minimum")
export type ExchangeReceipt = { count: number; received?: string; minimum: string; hash: string; href?: string };

export type ExchangeViewProps = {
  rows: ExchangeRow[];
  walletReady: boolean;
  walletLoading: boolean; // a connected wallet whose Credits have not been read yet: skeleton rows in the table
  marketLoading: boolean; // the live exchange not read yet: skeletons for the payout and the treasury balance
  connected: boolean;
  selectionCount: number;
  quoteAvailable: boolean;
  selectedRating: string;
  total: string;
  fee?: string; // the protocol fee in $BALANCE for the selection; the row is left out until a Credit is selected
  grossTotal?: string; // the selection's rating value in $BALANCE (1 point = 1 unit at par), before the discount
  discount?: string; // the posted discount, e.g. "20%"
  sortDesc: boolean; // rows by rating, highest first
  onSortToggle: () => void;
  available?: string; // the treasury's $BALANCE free for the exchange, shown once the exchange is open
  adjustment?: string;
  minimum: string;
  rate: string;
  slippageBps: number;
  onSlippageChange: (bps: number) => void;
  onToggle: (id: number) => void;
  onSelectAll: () => void;
  allSelected: boolean;
  busy: boolean;
  status?: string;
  error?: string;
  receipt?: ExchangeReceipt;
  onReset: () => void;
  action: ReactNode;
};

export function ExchangeView({
  rows, walletReady, walletLoading, marketLoading, connected, selectionCount, quoteAvailable, selectedRating, total, fee, available, adjustment,
  grossTotal, discount, sortDesc, onSortToggle,
  minimum, rate, slippageBps, onSlippageChange, onToggle, onSelectAll,
  allSelected, busy, status, error, receipt, onReset, action,
}: ExchangeViewProps) {
  const selected = rows.filter((row) => row.selected);
  // mobile: the breakdown sheet opened from the bottom bar's total; it opens by itself for a receipt or an error
  const [sheet, setSheet] = useState(false);
  useEffect(() => { if (receipt || error) setSheet(true); }, [receipt, error]);
  useEffect(() => {
    if (!sheet) return;
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setSheet(false);
    window.addEventListener("keydown", esc);
    return () => window.removeEventListener("keydown", esc);
  }, [sheet]);
  const receiptBlock = receipt && (
    <div className="exchange-success" role="status">
      <p className="exchange-success-title">sale complete</p>
      <div className="exchange-total exchange-success-value"><span>{receipt.received ?? `≥ ${receipt.minimum}`}</span><span className="exchange-currency">$BALANCE</span></div>
      <p className="exchange-success-currency">received for {receipt.count} Credit{receipt.count === 1 ? "" : "s"}</p>
      <dl className="exchange-breakdown">
        <div><dt>transaction</dt><dd>{receipt.href
          ? <a href={receipt.href} target="_blank" rel="noreferrer"><code title={receipt.hash}>{shortHash(receipt.hash)}</code> ↗</a>
          : <code title={receipt.hash}>{shortHash(receipt.hash)}</code>}</dd></div>
      </dl>
      <button type="button" onClick={() => { onReset(); setSheet(false); }}>sell more Credits</button>
    </div>
  );
  return (
    <main className="exchange-page">
      <section className="exchange-inventory" aria-labelledby="exchange-title">
        <div className="exchange-inventory-inner">
          <h1 id="exchange-title"><span className="exchange-desk">Exchange Credits for $BALANCE</span><span className="exchange-mob">Exchange any Credit for $BALANCE. Even just one.</span></h1>
          <div className="exchange-list-heading">
            <div>
              <strong className="exchange-desk">your credits</strong>
              {walletReady && connected && <span className="exchange-desk"> · {rows.length} in wallet · {selectionCount} selected</span>}
              {walletReady && connected && <span className="exchange-mob"><strong>{selectionCount}</strong> of {rows.length} selected</span>}
              {walletLoading && <span> · <Sk w="12ch" /></span>}
            </div>
            <div className="exchange-list-controls">
              <button className="exchange-control" onClick={onSortToggle} disabled={rows.length < 2} aria-label={`sort by rating, ${sortDesc ? "highest" : "lowest"} first`}>
                rating {sortDesc ? "↓" : "↑"}
              </button>
              <button
                className="exchange-select-all exchange-control"
                onClick={onSelectAll}
                disabled={busy || !rows.some((row) => !row.disabled)}
              >
                {allSelected ? "clear" : "select all"}
              </button>
            </div>
          </div>
          <div className="exchange-table-frame">
            <table className="exchange-table">
              <thead>
                <tr><th scope="col">credit</th><th scope="col">rating</th><th scope="col"><span className="exchange-sr-only">select</span></th></tr>
              </thead>
              <tbody>
                {walletLoading && rows.length === 0 && SKELETON_ROWS.map((i) => (
                  <tr key={`sk-${i}`} aria-hidden="true">
                    <th scope="row">
                      <span className="exchange-credit">
                        <Sk block className="exchange-art" w="" />
                        <span><Sk w={i % 2 ? "9ch" : "11ch"} /></span>
                      </span>
                    </th>
                    <td className="exchange-rating"><Sk w="3ch" /></td>
                    <td className="exchange-selection"><Sk block w="24px" h="24px" style={{ margin: "0 auto" }} /></td>
                  </tr>
                ))}
                {rows.map((row) => (
                  <tr key={row.id} className={`${row.selected ? "is-selected" : ""}${row.disabled ? " is-unavailable" : ""}`}>
                    <th scope="row">
                      <label className="exchange-credit" htmlFor={`exchange-credit-${row.id}`}>
                        <span className="exchange-art"><CreditTile id={row.id} /></span>
                        <span><strong>Credit #{row.id}</strong>{row.note && <small>{row.note}</small>}</span>
                      </label>
                    </th>
                    <td className="exchange-rating">{row.rating}</td>
                    <td className="exchange-selection">
                      <input
                        id={`exchange-credit-${row.id}`}
                        type="checkbox"
                        aria-label={`Select Credit #${row.id}`}
                        checked={row.selected}
                        disabled={busy || row.disabled}
                        onChange={() => onToggle(row.id)}
                      />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {rows.length === 0 && !walletLoading && <p className="exchange-empty" role="status">{status || (!walletReady ? "Loading wallet…" : connected ? "No Credits in this wallet." : "Connect your wallet to view your Credits.")}</p>}
          </div>
          {rows.length > 0 && status && <p className="exchange-inventory-status" role="status">{status}</p>}
        </div>
      </section>

      <section id="exchange-summary" className="exchange-summary" aria-labelledby="exchange-receive-title" aria-busy={busy}>
        {receipt ? receiptBlock : <>
        <div className="exchange-summary-content">
          {status && <p className="exchange-quote-status" role="status">{status}</p>}
          {/* the treasury's free $BALANCE takes the status box when there is no status to show */}
          {marketLoading && <p className="exchange-available"><Sk w="90%" /></p>}
          {available && <p className={status ? "exchange-available" : "exchange-quote-status"}>{available} $BALANCE available to exchange from the Credit Cycle treasury</p>}
          <p className="exchange-eyebrow" id="exchange-receive-title">you receive</p>
          <div className="exchange-total" aria-live="polite" aria-atomic="true"><span>{marketLoading ? <Sk w="2ch" /> : total}</span><span className="exchange-currency">$BALANCE</span></div>
          <dl className="exchange-breakdown">
            {selected.map((row) => <div key={row.id}><dt>Credit #{row.id}</dt><dd>{quoteAvailable ? row.gross : `${row.rating} pts`}</dd></div>)}
            {selected.length > 0 && !quoteAvailable && <div><dt>selected rating</dt><dd>{selectedRating} pts</dd></div>}
            {fee && <div><dt>protocol fee</dt><dd>{fee} $BALANCE</dd></div>}
            {adjustment && <div><dt>price-protection adjustment</dt><dd>{adjustment}</dd></div>}
            <div className="exchange-breakdown-total"><dt>you receive</dt><dd>{total} $BALANCE</dd></div>
          </dl>
          <p className="exchange-explanation">{quoteAvailable
            ? `Credits are quoted at ${rate} of rating. Price protection can lower the quote. Your transaction receives at least the minimum below or reverts.`
            : "Credit ratings are shown in points. No executable BALANCE payout is available yet. The live payout and minimum will appear when the exchange is ready."}</p>
          <div className="exchange-slippage">
            <span id="exchange-slippage-label">slippage tolerance</span>
            <div role="group" aria-labelledby="exchange-slippage-label">
              {[0, 50, 100].map((bps) => (
                <button key={bps} type="button" aria-pressed={slippageBps === bps} disabled={busy} onClick={() => onSlippageChange(bps)}>{bps / 100}%</button>
              ))}
            </div>
          </div>
          <div className="exchange-minimum"><span>minimum you receive</span><strong>{minimum} $BALANCE</strong></div>
        </div>
        <div className="exchange-submit">
          {error && <p className="exchange-error" role="alert">{error}</p>}
          {action}
          <p>First sale asks once to approve the collection.</p>
        </div>
        </>}
      </section>

      {/* mobile only: a bar with the total (tap for the breakdown) and the sell button, and the breakdown sheet */}
      {!receipt && (
        <div className="exchange-bar">
          <button type="button" className="exchange-bar-total" onClick={() => setSheet(true)} aria-expanded={sheet} aria-controls="exchange-sheet">
            <span>you receive ⌃</span>
            <strong>{marketLoading ? <Sk w="3ch" /> : total}<small> $BALANCE</small></strong>
          </button>
          <div className="exchange-bar-action">{action}</div>
        </div>
      )}
      <div className={`exchange-scrim${sheet ? " is-open" : ""}`} aria-hidden onClick={() => setSheet(false)} />
      <section id="exchange-sheet" className={`exchange-sheet${sheet ? " is-open" : ""}`} role="dialog" aria-label="sale summary" aria-hidden={!sheet}>
        <button type="button" className="exchange-sheet-handle" onClick={() => setSheet(false)} aria-label="close the summary" />
        {receipt ? receiptBlock : <>
          <div className="exchange-sheet-head"><strong>sale summary</strong><span>{selectionCount} credit{selectionCount === 1 ? "" : "s"}</span></div>
          {status && <p className="exchange-quote-status" role="status">{status}</p>}
          <dl className="exchange-sheet-list">
            {selected.map((row) => <div key={row.id}><dt>Credit #{row.id}</dt><dd>{row.rating}</dd></div>)}
          </dl>
          <dl className="exchange-sheet-sums">
            {grossTotal && <div><dt>rating value</dt><dd>{grossTotal}</dd></div>}
            {fee && <div><dt>protocol discount{discount ? ` (${discount})` : ""}</dt><dd>{fee}</dd></div>}
            {adjustment && <div><dt>price-protection adjustment</dt><dd>{adjustment}</dd></div>}
          </dl>
          <div className="exchange-sheet-total"><span>you receive</span><strong>{total}<small> $BALANCE</small></strong></div>
          {error && <p className="exchange-error" role="alert">{error}</p>}
          <div className="exchange-sheet-action">{action}</div>
          <p className="exchange-sheet-note">
            priced at {rate} of rating; price protection can lower it. you receive at least {minimum} $BALANCE ({slippageBps / 100}% slippage) or the sale reverts.
            {available && ` ${available} $BALANCE available in the treasury.`}
          </p>
        </>}
      </section>
    </main>
  );
}

const SKELETON_ROWS = [0, 1, 2, 3];

function shortHash(hash: string): string {
  return hash.length > 20 ? `${hash.slice(0, 10)}…${hash.slice(-8)}` : hash;
}
