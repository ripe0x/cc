// Contract docs use current engine interfaces and a pinned snapshot for the deployed helper.
// Keep signatures and behavior in sync with each referenced source revision.
export type DocEntry = {
  signature: string;
  description: string;
  detail?: string;
  access?: string;
  errors?: string;
};

export type DocSection = {
  id: string;
  title: string;
  intro?: string;
  entries?: DocEntry[];
  points?: string[];
};

export type DocPage = {
  slug: string;
  group: "Start here" | "Guides" | "Contracts";
  title: string;
  eyebrow: string;
  summary: string;
  source?: string;
  sourceSnapshot?: string;
  sourceRevision?: string;
  mainnetAddress?: string;
  mainnetAddresses?: { label: string; address: string }[];
  sections: DocSection[];
};

export const docPages: DocPage[] = [
  {
    slug: "",
    group: "Start here",
    title: "Overview",
    eyebrow: "Documentation",
    summary: "Guides and contract reference for the CC engine.",
    mainnetAddresses: [{ label: "CC", address: "0x28ef14A55DC93CDCB9001FA038A184967146C789" }],
    sections: [
      {
        id: "journeys",
        title: "Common tasks",
        points: [
          "Credits: read bids and scores, buy or sell Credits, swap a pile Credit, and sweep listings.",
          "Statements: read asks and scores, compose, buy, and restyle held Statements.",
          "Track activity through contract events. A Statement sale emits ControllerV2.Bought and Core.StatementSoldTo.",
        ],
      },
      {
        id: "mainnet-record",
        title: "Ethereum mainnet record",
        points: [
          "The Core deployed at block 26,229,330 and CC launched at block 26,231,333. The selected ControllerV2 and treasury have their own contract reference pages.",
        ],
      },
      {
        id: "before-you-call",
        title: "Before a transaction",
        points: [
          "Check current deployment state, contract addresses and active settings before sending a transaction.",
          "Quotes change with time, settings, and state. Simulate the call before sending it.",
          "Use a minimum output where available. Owner settings take effect immediately.",
          "Amounts use raw token units. Credit scores use 10,000 units per point. The ETH bid rate is per 100 points.",
        ],
      },
    ],
  },
  {
    slug: "guides/credits",
    group: "Guides",
    title: "Credits",
    eyebrow: "Guide / Credits",
    summary: "Read prices and scores, buy and sell Credits, swap pile Credits, and sweep listings.",
    mainnetAddress: "0x97630aA70AB14ed9883B41dAfccBc11349723043",
    sections: [
      {
        id: "read-credit",
        title: "Read a Credit",
        entries: [
          { signature: "Core.bidOf(uint256 id) → uint256", description: "Current ETH bid for this Credit, including its score and the live rate." },
          { signature: "Core.spendState() → (bucket, budget, spent)", description: "ETH purchase budget and amount spent in the current bucket. A positive bid does not guarantee this bucket can buy." },
          { signature: "CreditScoreLens.creditScore(uint256 creditId) → uint256", description: "Credit score in ten-thousandths of a point, including for burned Credits." },
        ],
      },
      {
        id: "buy-credit",
        title: "Buy Credits",
        points: [
          "Check creditSaleOn and choose IDs from Core.pilePage. Read ControllerV2.creditPrice for each ID, then simulate the purchase with enough ETH for the total.",
          "The Controller refunds excess ETH. A Credit sale emits Core.CreditSold. The return lock follows that Credit through transfers and blocks its return to any Core intake door until it expires.",
        ],
        entries: [
          { signature: "ControllerV2.buyCredit(uint256 id) payable", description: "Buy one held Credit while the Credit sale is enabled. Its price declines over the sale window." },
          { signature: "ControllerV2.buyCredits(uint256[] ids) payable", description: "Buy multiple pile Credits in one call. Each is priced and sold in order." },
        ],
      },
      {
        id: "sell",
        title: "Sell Credits",
        points: [
          "Approve the Core to transfer each Credit. Read bidOf, then simulate the sell call against the latest block.",
          "Use minOut to bound the ETH payment.",
          "The return lock, reserve, and spend cap may prevent a quoted sale from executing.",
          "The ETH bid's climb pauses when the booked pot cannot fund the last fill rate for 100 points plus the artist royalty.",
        ],
        entries: [
          { signature: "Core.sellForEth(uint256[] ids, uint256 minOut)", description: "Sell one or more Credits for ETH. The caller receives the bid; the artist royalty is paid on top." },
        ],
      },
      {
        id: "swap-credit",
        title: "Swap a Credit",
        points: [
          "Choose an outId from Core.pilePage and an inId you own with an equal or higher score. Approve the Core for the incoming Credit and, if swapFeeCc is nonzero, the CC fee.",
          "Simulate Core.swapCredit(inId, outId). The incoming Credit takes the outgoing Credit's pile position, cost, and sale-window timestamp; the outgoing Credit goes to the caller.",
        ],
        entries: [
          { signature: "Core.swapCredit(uint256 inId, uint256 outId)", description: "Exchange an eligible owned Credit for a pile Credit and burn the configured CC fee." },
        ],
      },
      {
        id: "listing",
        title: "Sweep a listing",
        points: [
          "Core.buyListing can purchase a Credit through an allowlisted adapter when the listing price and caller payment fit the bid and spend budget. Use the adapter's quote and params format for that venue.",
          "Simulate the call against the current listing and bid before submitting it.",
        ],
        entries: [
          { signature: "Core.buyListing(address adapter, uint256 id, bytes params)", description: "Buy an eligible venue listing through an approved adapter." },
        ],
      },
      {
        id: "credit-events",
        title: "Credit events",
        points: [
          "Use CreditBought, CreditSold, CreditSwapped, and ListingBought for Credit activity. Pair each log with its transaction and block.",
        ],
      },
    ],
  },
  {
    slug: "guides/balance",
    group: "Guides",
    title: "Exchange Credits for BALANCE",
    eyebrow: "Guide / BALANCE exchange",
    summary: "Sell eligible Credit NFTs for BALANCE and help build the Core's next Statement.",
    mainnetAddresses: [
      { label: "Core", address: "0xcdb1889ae12074d750CD9B8531B692015465e0dD" },
      { label: "Credits", address: "0x97630aA70AB14ed9883B41dAfccBc11349723043" },
      { label: "Phase2BalanceTreasury", address: "0xB85CF439Ca57b4bfC28fA1Cb8a97Ee85555B0496" },
      { label: "BALANCE", address: "0x3620540c994433D7B4a628C46d2ED5F92572eA07" },
    ],
    sections: [
      {
        id: "cycle",
        title: "The Credit and BALANCE cycle",
        points: [
          "The Core acquires Credits through its ETH bid, approved listings, and BALANCE exchanges. It gathers 80 Credits into a Statement and holds that Statement.",
          "When a held Statement is eligible and conversion is enabled, the Core sends it through the selected treasury. The conversion delivers BALANCE to the treasury. A configured share is reserved; the rest becomes working BALANCE that can fund Credit exchanges.",
          "Exchanging a Credit spends BALANCE now and adds that Credit to the Core's pile. A later Statement conversion can replenish the treasury and increase its BALANCE holdings. Treasury growth depends on what conversions bring in relative to payouts and other uses of its funds.",
        ],
      },
      {
        id: "quote",
        title: "Check your quote",
        points: [
          "If you hold Credits, you can exchange eligible ones when the BALANCE bid is open and the treasury has working funds. Check Core.settings().balanceBidOn, the selected Core.balanceModule(), and Core.balanceToken(). The treasury's available() must cover the full batch payout plus artist royalties.",
          "Read balanceBidOf for each Credit ID. A single-Credit quote does not guarantee the full batch can be paid, and balanceBidOn must be checked separately.",
        ],
        entries: [
          { signature: "Core.balanceBidOf(uint256 id) → uint256", description: "Current payout quote for one Credit in BALANCE base units." },
        ],
      },
      {
        id: "exchange",
        title: "Exchange Credits",
        points: [
          "Approve the Core to transfer the selected Credits. Set minOut in BALANCE base units and pass the current balanceToken as expectedToken. Simulate the full batch before sending.",
          "A return lock, changed quote, or insufficient treasury funds can stop the sale.",
        ],
        entries: [
          { signature: "Core.sellForBalance(uint256[] ids, uint256 minOut, address expectedToken)", description: "Exchange approved Credits for BALANCE, with a minimum total payout and a pinned payment token." },
        ],
      },
      {
        id: "result",
        title: "Read the result",
        points: [
          "The Credits enter the Core pile and the treasury pays the seller in BALANCE. The artist royalty is paid separately.",
          "Core emits CreditBought and BalanceFill for each Credit. Pair the logs with the transaction and block.",
        ],
      },
    ],
  },
  {
    slug: "guides/statements",
    group: "Guides",
    title: "Statements",
    eyebrow: "Guide / Statements",
    summary: "Read Statement prices and scores, compose, buy, and restyle held Statements.",
    mainnetAddress: "0x75Edd94b7e49b3bD5C8047b91F165A5e265a069b",
    sections: [
      {
        id: "read-statement",
        title: "Read a Statement",
        entries: [
          { signature: "Core.statementInfo(uint256 sid) → (held, cost, composedAt)", description: "Check custody and cost before reading a sale quote." },
          { signature: "ControllerV2.priceOf(uint256 sid) → uint256", description: "Current ETH ask. The reference and owner-set multiplier can change; the ask does not decay with age." },
          { signature: "CreditScoreLens.statementScore(uint256 statementId) → uint256", description: "Stored total score across a Statement's pages, including overprints." },
        ],
      },
      {
        id: "buy-statement",
        title: "Buy a Statement",
        points: [
          "Choose an ID from Core.heldStatements. Check ControllerV2.statementSalesEnabled(), read priceOf(sid), then simulate buy(sid) with at least that much ETH.",
          "The Controller sends the current price to the Core, transfers the Statement to the buyer, and refunds excess ETH. The quote can change before inclusion.",
          "Read ControllerV2.Bought and Core.StatementSoldTo for the final price and sale split.",
        ],
        entries: [
          { signature: "ControllerV2.buy(uint256 sid) payable", description: "Buy a held Statement while sales are enabled. Send at least priceOf(sid)." },
        ],
      },
      {
        id: "compose",
        title: "Compose a Statement",
        points: [
          "Read ControllerV2.nextPage(). Once ready, call Core.compose() for its chosen format or Core.compose(format) for a specific format.",
          "Core.composeChosen requires chosenComposeOn, the minimum CC holding, and 80 eligible pile Credit IDs. Check the sale window before submitting.",
          "Composition emits Core.Composed. The resulting Statement stays held by the Core for sale.",
          "A caller holding at least minCcToChoose CC can change the format of a held Statement with Core.setHeldFormat(sid, format).",
        ],
        entries: [
          { signature: "Core.compose() / Core.compose(uint8 format)", description: "Compose the next eligible page of 80 pile Credits." },
          { signature: "Core.composeChosen(uint256[80] ids, uint8 format)", description: "Compose 80 chosen eligible pile Credits when the feature is enabled." },
          { signature: "Core.setHeldFormat(uint256 sid, uint8 format)", description: "Change a held Statement's format when the caller meets the CC holding requirement." },
        ],
      },
      {
        id: "statement-events",
        title: "Statement events",
        points: [
          "Use Composed and StatementSoldTo for Statement activity. Pair each log with its transaction and block.",
        ],
      },
    ],
  },
  {
    slug: "guides/lifecycle",
    group: "Guides",
    title: "Lifecycle",
    eyebrow: "Guide / operating model",
    summary: "Permissionless maintenance and historical quotes.",
    sections: [
      {
        id: "automation",
        title: "Permissionless maintenance",
        points: [
          "Core.book, buyback, and collectEscrow are callable maintenance doors, each with its own readiness checks. Buyback is unavailable while the Core is paused; booking and escrow collection remain live.",
          "Do not assume a keeper reward exceeds transaction gas. Simulate the exact call and inspect the current settings.",
        ],
      },
      {
        id: "history",
        title: "Historical quotes",
        points: [
          "SettingsSet, CreditSaleSet, StatementSalesSet, and StatementSaleMultiplierSet change how later quotes or sale availability should be interpreted.",
          "A current view is not a historical quote. Read at the historical block or replay the relevant settings and events.",
        ],
      },
    ],
  },
  {
    slug: "contracts/core",
    group: "Contracts",
    title: "Core",
    eyebrow: "Contract / custody + execution",
    summary: "The Core holds ETH and Credits, owns the bid and pile, composes Statements, and manages the engine's settings.",
    source: "src/interfaces/ICore.sol",
    mainnetAddress: "0xcdb1889ae12074d750CD9B8531B692015465e0dD",
    sections: [
      {
        id: "quotes",
        title: "Quotes and state",
        entries: [
          { signature: "bidOf(uint256 id) → uint256", description: "Live ETH bid for a Credit ID, limited by available pot room.", access: "view" },
          { signature: "balanceBidOf(uint256 id) → uint256", description: "BALANCE payout quote for one Credit; zero when the module cannot cover the payout and artist royalty. Check balanceBidOn separately.", access: "view" },
          { signature: "balanceModule() → address", description: "Selected treasury for BALANCE payments.", access: "view" },
          { signature: "balanceToken() → address", description: "Token paid by the selected treasury.", access: "view" },
          { signature: "bidForScore(uint256 score) → uint256", description: "Live ETH bid for a raw score.", access: "view" },
          { signature: "ethRate() → uint256", description: "ETH rate for the reference score of 100 points.", access: "view" },
          { signature: "RATE_START() → uint256", description: "Recorded opening ETH rate per 100 points; use ethRate() for the current rate.", access: "view" },
          { signature: "spendState() → (uint64 bucket, uint128 budget, uint128 spent)", description: "Current ETH purchase bucket and spend.", access: "view" },
          { signature: "pilePage(uint256 startAfter, uint256 n) → uint256[]", description: "Page through Credits held in the pile.", access: "view" },
          { signature: "heldStatements() → uint256[]", description: "Statement IDs still held by the Core.", access: "view" },
          { signature: "settings() → Settings", description: "All current owner-controlled economic settings.", access: "view" },
        ],
      },
      {
        id: "credit-doors",
        title: "Credit doors",
        entries: [
          { signature: "sellForEth(uint256[] ids, uint256 minOut)", description: "Transfer approved Credits in and pay the caller in ETH.", errors: "ReturnLocked, SpendCapReached, PotTooSmall, Slippage" },
          { signature: "sellForBalance(uint256[] ids, uint256 minOut, address expectedToken)", description: "Transfer approved Credits in and pay the caller in BALANCE from the selected treasury.", errors: "BalanceBidOff, BalanceTokenChanged, ReturnLocked, PotTooSmall, Slippage" },
          { signature: "buyListing(address adapter, uint256 id, bytes params)", description: "Buy one approved venue listing at or below the bid, subject to the ETH spend budget.", errors: "AdapterNotAllowed, AboveBid, SpendCapReached" },
          { signature: "swapCredit(uint256 inId, uint256 outId)", description: "Swap an eligible pile Credit for a holder's Credit of equal or higher score, burning the CC fee." },
        ],
      },
      {
        id: "statement-doors",
        title: "Statement doors",
        entries: [
          { signature: "compose() / compose(uint8 format)", description: "Compose 80 eligible pile Credits into a Statement when the next page is ready." },
          { signature: "composeChosen(uint256[80] ids, uint8 format)", description: "Choose the 80 Credits when the choice switch and CC holding requirement permit it." },
          { signature: "setHeldFormat(uint256 sid, uint8 format)", description: "Change the format of a held Statement when the caller holds enough CC." },
          { signature: "sellTo(uint256 sid, address buyer) payable", description: "Controller-only settlement of a Statement sale.", access: "Controller only" },
        ],
      },
      {
        id: "operations",
        title: "Maintenance and authority",
        entries: [
          { signature: "book() / collectEscrow() / buyback()", description: "Book fee income, collect escrow, and burn CC with the buyback allocation.", access: "Permissionless, guarded by readiness" },
          { signature: "setSettings(Settings settings)", description: "Replace the complete settings struct, effective immediately.", access: "Owner only" },
          { signature: "setRate(uint256 rate)", description: "Re-anchor the mode-off ETH rate per 100 points within its bounds.", access: "Owner only", errors: "BadRate" },
          { signature: "migrate(uint256 amount)", description: "Move the bid pot and pile to the configured successor and retire the Core.", access: "Owner only" },
        ],
      },
      {
        id: "events",
        title: "Events to index",
        entries: [
          { signature: "CreditBought(id, from, cost, toArtist)", description: "A Credit entered the Core from a seller." },
          { signature: "BalanceFill(paid, toArtist, available)", description: "A Credit exchange paid BALANCE to the seller and accounted for its artist royalty." },
          { signature: "ListingBought(id, adapter, caller, cost, paid, rate, toArtist)", description: "The Core swept an external listing." },
          { signature: "Composed(sid, ids, format, cost, price, caller)", description: "The pile became a Statement." },
          { signature: "StatementSoldTo(sid, buyer, price, toBuyback, toArtist, toOperator)", description: "The Core settled a Statement sale." },
          { signature: "RateSet(rate)", description: "The owner reset the ETH bid rate." },
          { signature: "SettingsSet(settings)", description: "Owner settings change that alters subsequent calls and quotes." },
        ],
      },
    ],
  },
  {
    slug: "contracts/controller",
    group: "Contracts",
    title: "ControllerV2",
    eyebrow: "Contract / sale pricing",
    summary: "The Controller quotes and executes the engine's Statement and Credit sales.",
    source: "src/interfaces/IControllerV2.sol",
    mainnetAddress: "0xCD64e368b3d7033B2E2B22Fa5F67f554aB807d36",
    sections: [
      {
        id: "prices",
        title: "Price reads",
        entries: [
          { signature: "priceOf(uint256 sid) → uint256", description: "Current Statement ask in wei: at least the Core cost floor and the reference times the persistent multiplier.", access: "view" },
          { signature: "referenceOf(uint256 sid) → uint256", description: "Reference used by the Statement ask.", access: "view" },
          { signature: "statementSalesEnabled() → bool", description: "Whether Statement purchases are enabled.", access: "view" },
          { signature: "statementSaleMultiplierBps() → uint32", description: "Persistent multiplier applied to the Statement reference. It does not decay with age.", access: "view" },
          { signature: "creditPrice(uint256 id) → uint256", description: "Current sale price for a held Credit.", access: "view" },
          { signature: "nextPage() → (bool ready, uint256[80] ids, uint8 format)", description: "Whether the Core can compose the next page.", access: "view" },
        ],
      },
      {
        id: "sales",
        title: "Sale calls",
        entries: [
          { signature: "buy(uint256 sid) payable", description: "Buy a held Statement while sales are enabled; the Controller settles through Core.sellTo.", errors: "StatementSalesOff, NotForSale, Underpaid, NoQuote" },
          { signature: "buyCredit(uint256 id) payable", description: "Buy one pile Credit while the sale is enabled.", errors: "CreditSaleOff, NotForSale, Underpaid" },
          { signature: "buyCredits(uint256[] ids) payable", description: "Buy several eligible pile Credits in one payment.", errors: "CreditSaleOff, NotForSale, Underpaid" },
        ],
      },
      {
        id: "events",
        title: "Events to index",
        entries: [
          { signature: "Bought(sid, buyer, price)", description: "Statement purchase; pair with Core.StatementSoldTo in the same transaction." },
          { signature: "StatementSalesSet(enabled)", description: "Statement sale availability changed." },
          { signature: "StatementSaleMultiplierSet(multiplierBps)", description: "The Statement ask multiplier changed." },
          { signature: "CreditSaleSet(credit)", description: "Credit sale policy changed." },
        ],
      },
    ],
  },
  {
    slug: "contracts/balance-module",
    group: "Contracts",
    title: "Balance module",
    eyebrow: "Contract / Phase2BalanceTreasury",
    summary: "The selected treasury converts held Statements and makes working BALANCE available to the Core.",
    source: "src/interfaces/IPhase2BalanceTreasury.sol",
    mainnetAddress: "0xB85CF439Ca57b4bfC28fA1Cb8a97Ee85555B0496",
    sections: [
      {
        id: "state",
        title: "State reads",
        entries: [
          { signature: "balanceToken() → address", description: "BALANCE token held by this module.", access: "view" },
          { signature: "selected() → bool", description: "Whether this module is selected by the active Core and has not migrated.", access: "view" },
          { signature: "conversionReady() → bool", description: "Whether the module can convert a held Statement now.", access: "view" },
          { signature: "transfersReady() → bool", description: "Whether ordinary BALANCE transfers are open.", access: "view" },
          { signature: "available() → uint256", description: "Working BALANCE available for the Core's Credit purchases; zero unless selected, payments enabled, and transfers open.", access: "view" },
          { signature: "working() → uint256", description: "Custody less the separate reserve and recorded unpaid transfers.", access: "view" },
          { signature: "conversionToClaimBps() → uint16", description: "Share of each Statement conversion receipt reserved outside working funds, in basis points.", access: "view" },
        ],
      },
      {
        id: "core-calls",
        title: "Core calls",
        entries: [
          { signature: "redeem(uint256 statementId) → uint256", description: "Convert a Statement transferred by the Core, measure the BALANCE received, and keep it in the module.", access: "Core only", errors: "ConversionOff, NotHeld, RedeemedBelowRating" },
          { signature: "pay(address to, uint256 amount)", description: "Pay from available working funds. Undelivered amounts are recorded as owed; the Core checks a seller's receipt.", access: "Core only", errors: "InsufficientAvailable" },
        ],
      },
      {
        id: "events",
        title: "Events",
        entries: [
          { signature: "StatementConverted(statementId, received, allocated, contributionBps, claimReserve)", description: "A held Statement was converted and its received BALANCE was accounted for." },
          { signature: "PaymentAccrued(to, amount)", description: "A Core payment was recorded as owed after an incomplete transfer." },
          { signature: "SwitchesSet(conversionEnabled, workingPaymentsEnabled, ccRedemptionEnabled)", description: "The module's movement switches changed." },
        ],
      },
    ],
  },
  {
    slug: "contracts/credit-score-lens",
    group: "Contracts",
    title: "CreditScoreLens",
    eyebrow: "Contract / scores + traits",
    summary: "Read Credit scores, rarity, traits, and Statement totals from the deployed mainnet helper.",
    source: "src/interfaces/ICreditScoreLens.sol",
    sourceSnapshot: "web/docs-sources/ICreditScoreLens.sol",
    sourceRevision: "5875fbdbd830e85f4fb884a74c98f92c6a26a822",
    mainnetAddress: "0x7a3f3967cBB63E8d56e3f093069C62A25eebBda6",
    sections: [
      {
        id: "credit-reads",
        title: "Credit reads",
        entries: [
          { signature: "creditScore(uint256 creditId) → uint256 score", description: "Score in ten-thousandths of a point. For example, 1,324,012 means 132.4012 points.", access: "view", errors: "UnknownCredit for a never-minted ID" },
          { signature: "creditScores(uint256[] creditIds) → uint256[] scores", description: "Scores in input order, preserving duplicates. An empty input returns an empty array; an unknown ID reverts the whole call. Chunk large batches to fit the RPC call gas limit.", access: "view", errors: "UnknownCredit for any never-minted ID" },
          { signature: "creditRarity(uint256 creditId) → uint256 rarity", description: "Raw sum of rarity trait points, including the doubled eights contribution. It is not a percentile or the Credit score.", access: "view", errors: "UnknownCredit for a never-minted ID" },
          { signature: "creditTraits(uint256 creditId) → (mask, active, occupied, eights, band)", description: "Numeric CreditScore traits: active plate mask, inked bits, occupied cells, count of ASCII 8s, and registration band (0 to 5).", access: "view", errors: "UnknownCredit for a never-minted ID" },
        ],
      },
      {
        id: "statement-read",
        title: "Statement read",
        entries: [
          { signature: "statementScore(uint256 statementId) → uint256 score", description: "Stored total across all pages, including overprints. A never-composed ID returns zero. This read does not indicate ownership.", access: "view" },
        ],
      },
      {
        id: "sources",
        title: "Data sources",
        points: [
          "The helper reads the fixed Ethereum mainnet Credits, CreditScore, and Statements contracts. It has no write methods or events.",
          "Burned Credits retain their scores and traits. A Statement's total can change after an overprint.",
          "Registration bands: 0 Registered, 1 Nudge, 2 Slip, 3 Skew, 4 Drift, 5 Loose.",
          "All scores use 10,000 units per point. Preserve the raw integer for calculations.",
        ],
      },
    ],
  },
  {
    slug: "contracts/adapters",
    group: "Contracts",
    title: "Listing adapters",
    eyebrow: "Contract / venue boundary",
    summary: "An adapter prices one venue listing and returns the exact call the Core may execute. The Core approves adapters one by one.",
    source: "src/interfaces/IListingAdapter.sol",
    mainnetAddresses: [
      { label: "CreditStrategyAdapter", address: "0x5757788D0A6dF507dba064d66532F0b630Be1dc9" },
      { label: "SeaportBasicAdapter", address: "0x40302D497436bcC03e0Af2138Ec325C68DF3B0c8" },
    ],
    sections: [
      {
        id: "interface",
        title: "Shared interface",
        entries: [
          { signature: "price(uint256 id, bytes params) → (address target, uint256 value, bytes data, address offerer)", description: "Quote a listing for exactly one Credit and return its execution target, ETH value, calldata, and seller.", access: "view" },
          { signature: "Core.buyListing(address adapter, uint256 id, bytes params)", description: "The Core checks its allowlist, bid, budget, and resulting custody before executing the returned call." },
        ],
      },
      {
        id: "strategy",
        title: "CreditStrategyAdapter",
        points: [
          "Reads CreditStrategy.nftForSale(id); zero means NotForSale.",
          "Ignores params and returns the strategy's sellTargetNFT(id) call.",
          "The strategy is the offerer for the returned quote.",
        ],
      },
      {
        id: "seaport",
        title: "SeaportBasicAdapter",
        points: [
          "Decode params as BasicOrderParameters for a Seaport 1.6 basic order.",
          "Accept only an open native-ETH sale of exactly the requested Credit; payout recipients must be the seller or allowlisted.",
          "The Core owner can change allowed recipients. After adapters are locked, recipients can be removed but not added.",
        ],
        entries: [
          { signature: "setAllowedRecipient(address recipient, bool allowed)", description: "Maintain the Seaport payout allowlist.", access: "Core owner" },
          { signature: "RecipientSet(recipient, allowed)", description: "Allowlist change to index." },
        ],
      },
    ],
  },
];

export const docGroups = ["Start here", "Guides", "Contracts"] as const;

export function docHref(page: DocPage) {
  return page.slug ? `/docs/${page.slug}` : "/docs";
}

export function docPage(slug: string) {
  return docPages.find((page) => page.slug === slug);
}

export function entryId(section: DocSection, index: number) {
  return `${section.id}-${index + 1}`;
}
