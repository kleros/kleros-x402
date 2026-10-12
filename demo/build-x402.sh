#!/usr/bin/env bash
# Test build of @x402/core, @x402/extensions, @x402/evm and @x402/express from the pinned x402 submodule,
# with our Arbitrum Sepolia escrow patched into @x402/evm's deployment table and reverted after the build.
# In production the packages come from npm, unpatched.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
patch="$root/demo/x402-arbitrum-sepolia-escrow.patch"
pnpm="npx --yes pnpm@11.1.1"

cd "$root/lib/x402"
git apply "$patch"
trap 'git apply -R "$patch"' EXIT

cd typescript
# x402_monorepo is the workspace root, whose devDependencies (tsup) the package builds need.
$pnpm install --frozen-lockfile --filter x402_monorepo --filter @x402/core --filter @x402/extensions --filter @x402/evm --filter @x402/express
$pnpm --filter @x402/core --filter @x402/extensions --filter @x402/evm --filter @x402/express run build
