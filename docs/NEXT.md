# next changes (decided or pending, not started)

kept by the director. nothing here is built yet. apply in one pass when the owner says go.

| # | change | state | notes |
|---|---|---|---|
| 1 | the engine pulls its own fees: the Core calls the router's `flush` at the start of its own entry points (the two credit doors, compose), so fees arrive without a keeper | decided by the owner | the Core has 75 bytes of headroom: the call goes into `CoreLib`. a failing or reverting flush must never block the entry point (try, ignore). the flush tip then goes to whoever called the Core. mind the measuring rule: flush before any measurement starts, never inside one |
| 2 | protocol leg 0.25 points of volume: `bountyBps` 9_638 (the protocol keeps 362 of the 6_900 skim) | decided by the owner | needs the factory owner to lower the factory minimum protocol skim share to 362 before launch (a global factory setting): an owner command in DEPLOY and a preflight check. the router then receives 6.65 points |
| 3 | the payee share: 1.0 or 0.5 points of volume | waiting for the owner | `payeePpm` is the share over 6.65 points: 150_371 for 1.0, 75_186 for 0.5. tests with exact amounts, the simulator and the docs follow |
| 4 | nft rescue in the Core | waiting for the owner | options: none, stuck only (credits not in a pile, statements not on the books, any other nft), or full |
| 5 | a function that moves everything to a new engine | waiting for the owner | the alternative is to let an old engine wind down. if built, it needs a one way lock |
| 6 | trace the loosened invariant smoke | open, director | `test_everyActionSucceeds` under the hostile controller needed its compose tries raised from 80 to 300 after the review fixes. cause not proven |
| 7 | refresh docs/SIMULATION.md detail sections and rerun deep invariants and the foundry 1.8.1 check on the final code | open, director | after items 1 to 3 land |
| 8 | the prompt for the artcoins v2 session from docs/V2-REQUESTS.md | waiting for the owner | after everything above is settled |
| 9 | composability, kept small: (a) a read only lens contract outside the Core (one call for the live bid per credit, room left this hour, piles, listed statements with asking prices, pots, router balance); (b) docs/INTEGRATION.md with the call sequences, the event list and the generated interfaces; (c) optional `adopt(ids)`: credits someone transferred straight to the Core are put in the pile, with an event | waiting for the owner | (a) and (b) touch no production contract. (c) is a Core change that goes into `CoreLib` and needs a rule for the cost basis of an unpaid credit (the bid at that moment, not zero, so statement prices stay sane) |
