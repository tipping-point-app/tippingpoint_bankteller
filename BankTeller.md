[Developer Notes] Updated as of 11/7/2025

==================================================================================

What is Tipping Point?

Tipping Point is a decentralized crowdfunding platform that lets users collect money without a middleman taking custody. Contributors pledge in stablecoins (USDC by default), but funds don't move unless a campaign’s success condition is met (e.g., enough people joined, or the financial goal was reached). When a campaign “tips” (succeeds), funds move peer-to-peer from each contributor’s wallet to the creator’s wallet, with a small platform fee routed to the Tipping Point treasury. If the campaign fails, no money moves and no fees are charged.

Campaign Types:

Split Single Amount – One total cost split equally and dynamically among all contributors at tip time. As more users join, the price per person goes down.

Fixed Amount Per Person – Everyone pledges the same fixed amount (like a ticket).

Goal-Based Fundraising – An all-or-nothing fundraiser. Users can pledge any amount, but funds are only sent if the goal is met by the deadline.

Flexible Fundraising – Tipping Point's one campaign without any goals or minimums. Campaign creators collect regardless of goal attainment (creator receives whatever is raised).

Tipping Point aims to feel like a simple checkout while preserving web3 guarantees: non-custodial transfers, on-chain verifiability, and explicit user approvals.

How It Works (high level, non-technical):

Tipping Point is a hybrid system:

Off-chain (the app): Campaign creation, status tracking (who opted in, how much, deadlines), and tip/fail decisioning.

On-chain (the contract): When a campaign tips, the BankTeller contract executes the actual USDC transfers from each contributor to the creator and sends a small fee to the Tipping Point treasury. It also supports fee collection for gas abstraction and post-tip refunds initiated by the creator. A future feature supports refundable RSVP-style deposits.

Contributor Experience

The contributor signs two EIP-712 messages off-chain:

A USDC Permit (EIP-2612-style) so BankTeller can transfer USDC from the contributor without the contributor needing ETH for gas.

A DestinationApproval describing the pledge: campaignId, contributor address, creator address, pledged amount, platform fee, deadline, and a fee-collection nonce.

The app stores these signatures. If the campaign tips before the deadline, the Tipping Point EOA (platform operator address) calls BankTeller to execute the transfers using the contributor’s signed intent.

Why hybrid?

Keeping orchestration off-chain (what tipped, who joined) lets us iterate quickly and deliver a streamlined UX. Putting the value-movement step on-chain provides transparency, replay protection, and safety rails for contributors.

Terminology note: The Solidity code uses some legacy names for historical reasons (e.g., “eventId”, “invitee”). In the app and in this doc we say campaign and contributor. Where relevant, we call out the legacy field names explicitly.

The BankTeller Contract (technical deep dive):

Roles & addresses

owner (EOA): Tipping Point operator address; only this address can initiate most transfers (access-controlled by onlyOwner).

treasury: Receives platform fees.

usdc (IERC20): Primary settlement token. Assumed to support permit (EIP-2612-style) for gasless approvals.

EIP-712 domain & typed data:

BankTeller uses a canonical EIP-712 domain (DOMAIN_SEPARATOR) and three typed messages:

DestinationApproval (signed by the contributor; legacy field names shown):

from (contributor)

to (creator)

optInAmount (pledge amount)

tippingPointFee (platform fee for this pledge)

eventId (campaignId in the app)

approvalFee (USDC fee compensating Tipping Point for calling permit on USDC)

approvalFeeNonce (prevents duplicate fee withdrawals)

deadline (no transfers after this)

RefundApproval (signed by the creator):

creator

eventId (campaignId)

invitees (array of contributor addresses)

amounts (array of refund amounts matching invitees)

refundNonce (prevents duplicate/reflex refunds)

RefundableDeposit (signed by the contributor; future/optional RSVP flow):

invitee (contributor)

creator

iouDepositAmount (deposit at risk if no-show)

eventId (campaignId)

usdcGasFee (USDC fee to compensate gas abstraction)

(implicitly covered by EIP-712 domain; also guarded by a replay-prevention mapping)

Storage structures (safety rails):

transferSignatureExecuted[bytes32] — prevents re-using the same contributor+campaign DestinationApproval for multiple transfers.

approvalFeeNonces[address] — tracks latest consumed approval-fee nonce per contributor.

refundNonces[address] — tracks latest consumed refund nonce per creator.

refundableDepositExecuted[bytes32] — prevents collecting the same refundable deposit twice.

Happy-path flows:

A) Tipping & collection

The app determines that a campaign tipped (per its type and rules).

For each opted-in contributor, the owner EOA calls:

transferInviteeFunds(destinationApproval, v, r, s)

BankTeller:

Verifies the EIP-712 signature matches destinationApproval.from.

Enforces block.timestamp < destinationApproval.deadline.

Computes a unique key from (from, eventId) and checks transferSignatureExecuted to prevent double-spend.

Pulls optInAmount USDC from the contributor and sends it to to (the creator), then routes tippingPointFee to treasury.

Emits InviteeFundsTransferred(eventId, from, to, optInAmount, tippingPointFee).

Marks the (from, eventId) transfer as executed.

Fee model: the tippingPointFee is configurable and can represent a small percentage of the campaign economics (e.g., split proportionally across contributors). Exact configuration is enforced off-chain and memorialized in each contributor’s signed DestinationApproval.

B) Gas abstraction fee (permit compensation)

To let contributors interact without holding ETH, Tipping Point pays gas to execute their USDC permit. The platform then collects a small USDC allowance fee (per contributor) that the contributor agreed to inside DestinationApproval.

The owner EOA calls:

withdrawAllowanceFee(destinationApproval, v, r, s)

BankTeller:

Verifies signature and deadline.

Enforces approvalFeeNonces[from] == destinationApproval.approvalFeeNonce (no double charging).

Transfers approvalFee USDC from contributor to treasury.

Increments approvalFeeNonces[from].

Emits AllowanceFeeTransferred(from, eventId, approvalFee).

This call can happen before or after executing the USDC permit. Bundling the consent keeps UX to a single signature.

C) Post-tip refunds (creator-initiated)

If the creator decides to return funds after a successful collection (e.g., cancellation), the creator (not the platform) triggers refunds and pays the gas:

The creator calls:

refundEventFunds(refundApproval, v, r, s) (note: not onlyOwner)

BankTeller:

Requires msg.sender == refundApproval.creator.

Enforces refundNonces[creator] == refundApproval.refundNonce, then increments it.

Verifies the EIP-712 signature.

Iterates over invitees/amounts and transfers USDC from creator back to each contributor.

Emits RefundEventFundsTransferred(eventId, creator, invitee, amount) for each refund.

D) Refundable RSVP deposits (future / not yet implemented)

For RSVP-style campaigns where no-shows are penalized:

The owner EOA calls:

collectRefundableDeposit(refundableDeposit, v, r, s)

BankTeller:

Verifies the contributor’s EIP-712 signature.

Checks refundableDepositExecuted[key] (derived from contributor and eventId).

Transfers iouDepositAmount from contributor to creator and routes usdcGasFee to treasury.

Emits RefundableDepositTransferred(eventId, creator, invitee, iouDepositAmount, usdcGasFee) and marks executed.

Function Reference:

Naming: Functions use legacy “invitee/eventId” parameter names; read them as contributor/campaignId.

getDomainSeparator() → bytes32

Returns the EIP-712 domain separator used for all typed-data signatures.

Internal hash helpers

_hashDestinationApprovalMessage(DestinationApproval) → bytes32

_hashRefundApprovalMessage(RefundApproval) → bytes32

_hashRefundableDepositMessage(RefundableDeposit) → bytes32

These compute the EIP-712 struct hashes used during signature verification.

transferInviteeFunds(DestinationApproval, v, r, s) onlyOwner

Executes a contributor’s pledge at tip time.

Verifies: valid EIP-712 signature by from; not past deadline; not already executed for (from,eventId).

Transfers: optInAmount to to (creator) and tippingPointFee to treasury.

Emits: InviteeFundsTransferred.

Guards: transferSignatureExecuted.

withdrawAllowanceFee(DestinationApproval, v, r, s) onlyOwner

Collects the USDC fee that compensates the platform for gas spent executing the contributor’s permit.

Verifies: valid signature; not past deadline; approvalFeeNonce matches.

Transfers: approvalFee to treasury.

Emits: AllowanceFeeTransferred.

Guards: approvalFeeNonces[from] (incremented after success).

refundEventFunds(RefundApproval, v, r, s) creator-only

Returns collected funds from creator back to contributors.

Requires: msg.sender == creator.

Verifies: valid signature; refundNonce matches, then increments.

Transfers: USDC from creator to each listed contributor.

Emits: RefundEventFundsTransferred per recipient.

Guards: refundNonces[creator].

collectRefundableDeposit(RefundableDeposit, v, r, s) onlyOwner

Collects contributor deposits for RSVP-style campaigns when conditions are met (e.g., marked as no-show).

Verifies: contributor signature; not previously executed for (invitee,eventId).

Transfers: iouDepositAmount to creator; usdcGasFee to treasury.

Emits: RefundableDepositTransferred.

Guards: refundableDepositExecuted.

Events:

AllowanceFeeTransferred(address from, string eventId, uint256 allowanceFee)

InviteeFundsTransferred(string eventId, address from, address to, uint256 optInAmount, uint256 tippingPointFee)

RefundEventFundsTransferred(string eventId, address creator, address invitee, uint256 amount) (fields abbreviated here for readability)

RefundableDepositTransferred(string eventId, address creator, address invitee, uint256 iouDepositAmount, uint256 usdcGasFee)

(Event names retain legacy “eventId/invitee” wording for backward compatibility.)

Access Control & Safety Summary:

onlyOwner on all value-moving functions except refunds (which are creator-only).

Replay protection via:

transferSignatureExecuted[(from,eventId)]

approvalFeeNonces[from]

refundNonces[creator]

refundableDepositExecuted[(invitee,eventId)]

Explicit deadlines on contributor approvals to bound risk.

Non-custodial design: Funds move directly from → creator or back creator → contributor; Tipping Point never holds user balances.

Token Notes:

USDC is the default ERC-20 used today. Other stablecoins may be supported if they expose the necessary permit/typed-approval flow and standard ERC-20 semantics.

Operational Notes:

The platform coordinates when to call the contract (e.g., which contributors tipped, the final amount for Split Single Amount, etc.). Those decisions are made off-chain, memorialized in user signatures, and then enforced on-chain by BankTeller at transfer time.

Mis-use by the platform (e.g., premature transfer) would not benefit Tipping Point economically and would be visible on-chain; the contract still enforces signatures, deadlines, and replay guards to limit blast radius.

Creators pay gas only for refunds; contributors can be gasless via permit + approvalFee.

Legacy → Current Terminology Map:

event / eventId → campaign / campaignId

invitee → contributor

Headcount → Fixed Amount Per Person

Sliding Scale → Split Single Amount

Appendix: Typical call sequence (tip)

Contributor signs permit (USDC) and DestinationApproval.

Campaign tips off-chain.

Owner calls withdrawAllowanceFee (optional ordering) and transferInviteeFunds for each contributor.

BankTeller verifies signatures, deadlines, nonces; transfers USDC to creator and fee to treasury; emits events.
