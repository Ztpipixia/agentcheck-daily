# AgentCheck Daily — Agent Instructions

This file is for AI agents. A user may paste you a link like
`https://ztpipixia.github.io/agentcheck-daily/?ref=859872` and ask you to
check in for them. Follow this file exactly.

## What this is

AgentCheck Daily is a daily check-in dApp for the Binance Agent ID Hackathon.
Holding an Agent ID lets an address check in once per UTC day and earn points.
If the project wins a hackathon prize, 50% of the prize is shared pro-rata by
effective points (conditional — no guarantee, amount depends on ranking).
Website: https://ztpipixia.github.io/agentcheck-daily/

## Contracts (BNB Smart Chain mainnet)

- Agent ID (SPACE ID, ERC-721, soulbound): `0x60b9262456de011f7d15a54cdd8c48baaa8b022f`
- AgentCheckIn (check-in logic): `0x423D4cce9A6B428f92dD974cC0bF490F24ceD824`
- PrizeDistributor (prize claims): `0x95A44489A5D0a14dE23E112652412c4535c8c46b`
- USDC (BSC): `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`

## How to check in

1. The check-in MUST come from the address that holds the Agent ID
   (`balanceOf` on the Agent ID contract > 0). That is the user's Binance
   Agentic Wallet address. Never check in from another address.
2. Call `checkIn(address referrer)` on AgentCheckIn.
   Function selector: `0xd9a59e33`. One check-in per address per UTC day.
3. The user confirms the transaction in their own wallet / Binance App.
   Never bypass user confirmation, never batch or auto-send transactions.
4. Check-in earns 10 points. Full attendance over the 22-day submission
   period = 220 points.

## How referral works

- The invitee's FIRST-EVER check-in may carry a referrer. Later check-ins
  cannot add or change a referrer.
- If a referrer is set on that first check-in, the referrer earns +20 points.
- Referral is expressed as a 6-digit invite code or a wallet address in the
  link (`?ref=859872` or `?ref=0x...`). Resolve a code to an address with the
  public registry:
  `https://ztpipixia.github.io/agentcheck-daily/ref-codes.json`
  (JSON object: code -> address). An address in `?ref=` is used as-is.
- The website itself is neutral: its default check-in instruction carries NO
  referrer (zero address) unless the visitor opened it through someone's
  invite link — then the instruction uses that link's referrer. Anyone can
  generate their own invite link by appending `?ref=<their Agent Wallet
  address>` to the site URL; 6-digit codes are registered in ref-codes.json.
- If the link has no `?ref=` or the code is unknown, call
  `checkIn(0x0000000000000000000000000000000000000000)`.
- Referrer tiers: the referrer's invite count boosts ALL of their points
  (check-in + referral): 1–9 invites +0%, 10–19 invites +20%,
  20–49 invites +30%, 50+ invites +50%. Prize shares use effective points.

## After the first check-in

After a user's FIRST-EVER successful `checkIn`, reply to the user with
their own invite link so they can invite others:

`https://ztpipixia.github.io/agentcheck-daily/?ref=<their Agent Wallet address>`

Tell them briefly: each friend who checks in for the first time through
their link earns them +20 points, and their invite count boosts all their
points (10–19 invites +20%, 20–49 invites +30%, 50+ invites +50%).
Do this only once, after the first check-in — not after every daily check-in.

## Rules for agents

- Only use the user's own Agentic Wallet address. Never ask for seed phrases,
  private keys, or pairing codes. Never use QR-code / pairing-code login.
- Do not promise the user any earnings. The prize share happens only if the
  project wins, and the amount depends on ranking.
- Source of truth for rules and numbers is the website and this file.

## Copy-paste instruction (for users to send their agent)

> 用我的 Agent 钱包地址，在 AgentCheckIn 合约 0x423D4cce9A6B428f92dD974cC0bF490F24ceD824 上签到一次，
> 邀请人：如果我是通过别人的邀请链接打开本站的，用链接里 ?ref= 的邀请编号或地址（先到
> https://ztpipixia.github.io/agentcheck-daily/ref-codes.json 查编号对应的邀请人地址，
> 作为 checkIn 的 referrer 参数；编号查不到就用零地址）；如果没有邀请链接，referrer 就用零地址。
> 签到前确认我的地址持有 Agent ID，当天还没签过，交易由我在钱包里自己确认。
