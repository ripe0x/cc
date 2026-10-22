// promise: public docs track deployed references and publish only the approved BALANCE flow.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { contractCatalog } from "../lib/docs-catalog.ts";
import { docPages, entryId } from "../lib/docs-content.ts";

const slugs = new Set();
for (const page of docPages) {
  assert(!slugs.has(page.slug), `duplicate docs route: ${page.slug}`);
  slugs.add(page.slug);

  const anchors = new Set();
  const contractPage = page.group === "Contracts";
  const source = page.source && readFileSync(new URL(`../../${page.sourceSnapshot ?? page.source}`, import.meta.url), "utf8");
  if (contractPage) assert(source, `${page.title} needs a source interface`);
  if (page.slug === "contracts/credit-score-lens") {
    assert.equal(createHash("sha256").update(source).digest("hex"), "a967eda07be960d3fde5f4e03dea543f28d31bf89d487e19a465fb4f89c480e2", "deployed helper interface snapshot changed");
  }

  for (const section of page.sections) {
    assert(!anchors.has(section.id), `duplicate section: ${page.slug}#${section.id}`);
    anchors.add(section.id);
    section.entries?.forEach((entry, index) => {
      const id = entryId(section, index);
      assert(!anchors.has(id), `duplicate entry: ${page.slug}#${id}`);
      anchors.add(id);
      if (!contractPage) return;

      for (const part of entry.signature.split(" / ")) {
        const name = part.match(/^(?:Core\.)?([A-Za-z][A-Za-z0-9_]*)\(/)?.[1];
        assert(name, `unrecognized signature: ${entry.signature}`);
        const interfaceFile = part.startsWith("Core.")
          ? readFileSync(new URL("../../src/interfaces/ICore.sol", import.meta.url), "utf8")
          : page.slug === "contracts/adapters" && /^(?:setAllowedRecipient|RecipientSet)\(/.test(part)
            ? readFileSync(new URL("../../src/interfaces/ISeaportBasicAdapter.sol", import.meta.url), "utf8")
            : source;
        assert(new RegExp(`\\b(?:function|event)\\s+${name}\\s*\\(`).test(interfaceFile), `${page.title}: ${name} missing from interface`);
      }
    });
  }
}

assert(docPages.some((page) => page.slug === ""), "docs landing page missing");
const deployment = JSON.parse(readFileSync(new URL("../../deployments/1.json", import.meta.url), "utf8"));
const phase2 = JSON.parse(readFileSync(new URL("../../deployments/1-phase2.json", import.meta.url), "utf8"));
assert.equal(docPages.find((page) => page.slug === "contracts/core")?.mainnetAddress, deployment.core, "Core address differs from deployment record");
assert.equal(docPages.find((page) => page.slug === "contracts/controller")?.mainnetAddress, phase2.controllerV2, "ControllerV2 address differs from deployment record");
assert.equal(docPages.find((page) => page.slug === "contracts/controller")?.source, "src/interfaces/IControllerV2.sol", "selected Controller source differs from V2");
assert.equal(docPages.find((page) => page.slug === "contracts/balance-module")?.mainnetAddress, phase2.treasury, "balance module address differs from deployment record");
assert.deepEqual(docPages.find((page) => page.slug === "")?.mainnetAddresses, [{ label: "CC", address: deployment.coin }], "CC address differs from deployment record");
assert.equal(docPages.find((page) => page.slug === "guides/credits")?.mainnetAddress, deployment.credits, "Credits address differs from deployment record");
assert.deepEqual(docPages.find((page) => page.slug === "guides/balance")?.mainnetAddresses, [
  { label: "Core", address: deployment.core },
  { label: "Credits", address: deployment.credits },
  { label: "Phase2BalanceTreasury", address: phase2.treasury },
  { label: "BALANCE", address: phase2.balanceToken },
], "BALANCE exchange guide addresses differ from deployment records");
assert.equal(docPages.find((page) => page.slug === "guides/statements")?.mainnetAddress, deployment.statements, "Statements address differs from deployment record");
assert.deepEqual(docPages.find((page) => page.slug === "contracts/adapters")?.mainnetAddresses, [
  { label: "CreditStrategyAdapter", address: deployment.strategyAdapter },
  { label: "SeaportBasicAdapter", address: deployment.seaportAdapter },
], "adapter addresses differ from deployment record");
assert(!/\bbalance\b/i.test(JSON.stringify(docPages.filter((page) => !["guides/balance", "contracts/core", "contracts/balance-module"].includes(page.slug)))), "BALANCE flow appears outside its guide and contract references");
assert(!/\b(?:redeem\w*|redemp\w*)\b/i.test(JSON.stringify(docPages.filter((page) => page.slug !== "contracts/balance-module"))), "deferred redemption flow appears in public docs");
assert(!/ControllerV1|AnchorMoved|SaleSet\(sale\)|coin was not live/.test(JSON.stringify(docPages)), "outdated pre-launch copy appears in public docs");
assert(!docPages.some((page) => page.slug === "guides/claim" || page.slug === "guides/exchange"), "deferred guide must stay unpublished");
assert(!Object.hasOwn(contractCatalog, "contracts/balance-module"), "module page must stay curated without the claim interface catalog");
console.log(`docs: ${docPages.length} routes and contract reference names verified`);
