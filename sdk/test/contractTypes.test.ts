import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { STATUS, arbitratorAbi, klerosCaptureAuthorizerAbi } from "../src/contractTypes.ts";

const repo = join(import.meta.dirname, "..", "..");

type Param = { name?: string; type: string; indexed?: boolean; components?: readonly Param[] };
type AbiEntry = { type: string; name?: string; stateMutability?: string; inputs?: readonly Param[]; outputs?: readonly Param[] };
const param = (p: Param): unknown => ({ name: p.name ?? "", type: p.type, indexed: p.indexed ?? false, components: p.components?.map(param) ?? null });
const shape = (e: AbiEntry) => ({
  type: e.type,
  name: e.name,
  stateMutability: e.stateMutability ?? null,
  inputs: e.inputs?.map(param) ?? [],
  outputs: e.outputs?.map(param) ?? [],
});

test("every ABI entry matches the forge artifact", (t) => {
  const artifact = (name: string) => join(repo, "out", `${name}.sol`, `${name}.json`);
  if (!existsSync(artifact("KlerosCaptureAuthorizer"))) return t.skip("no forge artifact; run forge build at the repo root");
  const load = (name: string) => (JSON.parse(readFileSync(artifact(name), "utf8")) as { abi: AbiEntry[] }).abi;
  const checks: [AbiEntry[], readonly AbiEntry[]][] = [
    [load("KlerosCaptureAuthorizer"), klerosCaptureAuthorizerAbi],
    [load("IArbitratorV2"), arbitratorAbi],
  ];
  for (const [artifactAbi, ours] of checks) {
    for (const entry of ours) {
      const candidates = artifactAbi.filter((e) => e.type === entry.type && e.name === entry.name).map(shape);
      assert.ok(
        candidates.some((candidate) => isDeepStrictEqual(candidate, shape(entry))),
        `${entry.type} ${entry.name} differs from the artifact:\n${JSON.stringify(shape(entry))}\nartifact:\n${JSON.stringify(candidates)}`,
      );
    }
  }
});

test("the status names are the contract's Status enum, in order", () => {
  const source = readFileSync(join(repo, "src", "KlerosCaptureAuthorizer.sol"), "utf8");
  const body = /enum Status \{([^}]*)\}/.exec(source)?.[1];
  assert.ok(body, "enum Status not found in the contract");
  const names = body.split("\n").map((line) => line.replace(/\/\/.*$/, "").replace(",", "").trim()).filter(Boolean);
  assert.deepEqual([...STATUS], names);
});
