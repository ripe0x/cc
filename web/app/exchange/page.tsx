"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, useConfig, usePublicClient } from "wagmi";
import { getAccount } from "wagmi/actions";
import { useConnectModal } from "@rainbow-me/rainbowkit";
import type { Address } from "viem";
import { ExchangeView, type ExchangeReceipt } from "@/components/ExchangeView";
import { chain, core, credits, engineDeployed } from "@/lib/config";
import { exchangeAmount, exchangeQuote, exchangeReceived, sellExchange } from "@/lib/exchange";
import { rating, type BalanceTokenInfo } from "@/lib/format";
import { useBalanceToken, useSnapshot, useWalletCredits, type Snapshot } from "@/lib/live";
import { useTx } from "@/lib/tx";
import "./exchange.css";

export default function ExchangePage() {
  const { address, isConnected, chainId } = useAccount();
  const account = isConnected ? address : undefined;
  // A wallet or network change discards the old selection and its accepted quote. The CC burn lives on /claim.
  return <Exchange key={`${address}:${chainId}`} account={account} chainId={chainId} />;
}

function Exchange({ account, chainId }: { account?: Address; chainId?: number }) {
  const client = usePublicClient();
  const config = useConfig();
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const { openConnectModal } = useConnectModal();
  const snapshot = useSnapshot();
  const liveToken = useBalanceToken();
  const wallet = useWalletCredits(account);
  const [selected, setSelected] = useState(new Set<number>());
  const [slippage, setSlippage] = useState(50);
  // display order of the wallet's Credits by rating; selection and the sale follow the ids, not this order
  const [sortDesc, setSortDesc] = useState(true);
  const [receipt, setReceipt] = useState<ExchangeReceipt>();
  const [review, setReview] = useState<{
    market: Snapshot; token: BalanceTokenInfo; wallet: typeof wallet.data; selected: Set<number>; slippage: number;
  }>();
  const market = review?.market ?? snapshot.data;
  const token = review?.token ?? liveToken;
  const rows = review?.wallet ?? wallet.data;
  const selection = review?.selected ?? selected;
  const tolerance = review?.slippage ?? slippage;
  const { run, pending, err } = useTx();
  const order = rows.filter((credit) => selection.has(credit.id));
  const quote = exchangeQuote(market, order.map((credit) => credit.score), tolerance);
  const decimals = token?.address === market?.balanceToken ? token?.decimals : undefined;
  const amount = (value: bigint | undefined) => value === undefined || decimals === undefined
    ? "—" : exchangeAmount(value, decimals);
  const wrongChain = Boolean(account && chainId !== chain.id);
  const available = Boolean(engineDeployed && market?.balanceOn && market.settings.balanceBidOn && decimals !== undefined);
  const quoteAvailable = Boolean(available && quote && !quote.reason && !snapshot.error);
  const selectedRating = rating(order.reduce((total, credit) => total + credit.score, 0n));
  const status = pending ? "Your selection and minimum payout are held while you confirm in your wallet."
    : !engineDeployed ? "The exchange is not configured."
    : !account ? "Connect your wallet to view your Credits."
    : wrongChain ? `Switch your wallet to ${chain.name} to exchange Credits.`
    : wallet.error ? "Unable to load your Credits. Please try again."
    : !wallet.ready ? "Loading your Credits…"
    : rows.length === 0 ? "No Credits in this wallet."
    : snapshot.error ? "Unable to read the live exchange. Please try again."
    : !market ? "Reading the exchange…"
    : !available ? "BALANCE exchange is not open yet. Your Credits stay in your wallet."
    : quote?.reason;
  const blocked = !account || wrongChain || !wallet.ready || Boolean(wallet.error || snapshot.error) || !available || !quote || Boolean(quote.reason) || order.length === 0 || quote.minOut <= 0n;
  const allSelected = rows.length > 0 && order.length === rows.length;
  const label = pending ? "confirming exchange…"
    : !available ? "exchange not open yet"
    : order.length === 0 ? "select Credits to exchange"
    : `sell ${order.length} credit${order.length === 1 ? "" : "s"}`;

  async function sell() {
    if (blocked || pending || !account || !client || !core || !market || !token || !quote) return;
    const accepted = {
      account, core, credits, chainId: chain.id,
      ids: order.map((credit) => BigInt(credit.id)),
      minOut: quote.minOut, token: market.balanceToken,
    };
    setReceipt(undefined);
    setReview({ market, token, wallet: [...rows], selected: new Set(selection), slippage: tolerance });
    const consentIsCurrent = () => {
      const current = getAccount(config);
      return mounted.current && current.address === account && current.chainId === chain.id;
    };
    await run(async (write) => {
      const hash = await sellExchange(client, write, accepted, consentIsCurrent);
      // run already waited for a successful receipt; the fills in it are what the seller actually received
      // a failed read must not turn a confirmed sale into an error
      const received = await client.getTransactionReceipt({ hash })
        .then(({ logs }) => exchangeReceived(logs, accepted.core)).catch(() => undefined);
      const explorer = chain.blockExplorers?.default.url;
      setReceipt({
        count: accepted.ids.length,
        received: received === undefined ? undefined : amount(received),
        minimum: amount(accepted.minOut),
        hash,
        href: explorer ? `${explorer}/tx/${hash}` : undefined,
      });
      setSelected(new Set());
    }, [], consentIsCurrent);
    setReview(undefined);
  }

  return <ExchangeView
    rows={[...rows].sort((a, b) => (a.score === b.score ? 0 : (a.score > b.score) === sortDesc ? -1 : 1)).map((credit) => ({
      id: credit.id, rating: rating(credit.score),
      gross: amount(market?.balanceUnit ? credit.score * market.balanceUnit : undefined),
      selected: selection.has(credit.id),
    }))}
    walletReady={wallet.ready}
    walletLoading={Boolean(account && !wrongChain && !wallet.ready && !wallet.error)}
    marketLoading={engineDeployed && !market && !snapshot.error}
    connected={Boolean(account)}
    selectionCount={order.length}
    quoteAvailable={quoteAvailable}
    selectedRating={selectedRating}
    total={order.length === 0 ? "0" : amount(quoteAvailable ? quote?.total : undefined)}
    fee={quote && order.length > 0 ? `−${amount(quote.fee)}` : undefined}
    grossTotal={quote && order.length > 0 ? amount(quote.gross) : undefined}
    discount={market ? `${(10_000 - Number(market.balanceRate)) / 100}%` : undefined}
    sortDesc={sortDesc}
    onSortToggle={() => setSortDesc((d) => !d)}
    available={available && market?.balanceAvailable !== undefined ? amount(market.balanceAvailable) : undefined}
    adjustment={quoteAvailable && quote && order.length > 0 && quote.adjustment > 0n ? `−${amount(quote.adjustment)}` : undefined}
    minimum={amount(quoteAvailable && order.length > 0 ? quote?.minOut : undefined)}
    rate={market ? `${Number(market.balanceRate) / 100}%` : "the posted rate"}
    slippageBps={tolerance}
    onSlippageChange={setSlippage}
    onToggle={(id) => setSelected((previous) => {
      const next = new Set(previous);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    })}
    onSelectAll={() => setSelected(new Set(allSelected ? [] : wallet.data.map((credit) => credit.id)))}
    allSelected={allSelected}
    busy={pending}
    status={status}
    error={err ?? undefined}
    receipt={receipt}
    onReset={() => setReceipt(undefined)}
    action={!account
      ? <button type="button" onClick={openConnectModal}>connect wallet</button>
      : <button type="button" disabled={blocked || pending} onClick={sell}>{label}</button>}
  />;
}
