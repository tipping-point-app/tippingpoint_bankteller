[Developer Notes]

==================================================================================

# Tipping Point Purpose 

The purpose of Tipping Point is to faciliate money collection amongst communities and groups of people using blockchain technologies
and tokens as an alternative to the existing payment systems. By using these new protocols and functionalities we look to offer
benefits and automation that was previously gatekept by larger companies and institutions. By working with the nature of blockchain
technology we hope to provide more trust, via trustlessness, through our service and visibility.

- Consult HowTpWorksCopy.md for an outline of the service and UX we provide.

# How we achieve that 

Tipping Point is not a pure dApp. The idea of using an escrow smart contract and that would hold all invitee funds for an event and distribute
the funds to the creator of the event when the event tipped was considered but that was not the implemenation we went with.
A pure decentralized app had it merits but we like the idea of extendability of features by keeping certains aspects of the codebase on the
web2 side. What we did decide to keep on the blockchain is what we consider the lynchpin that will give our users trust and visibility into
Tipping Point, and what is the bridge from Tipping Point into the blockchain side of things.

Enter the BankTeller smart contract. The status of Tipping Point events, such as the number of invitees that have opted in, the amounts of $
they have promised to contribute, the details of the event, the deadlines, etc., are all maintained and monitored on the web2 side. However,
when an event actually tips and its time to distribute money, that is where the web3 and Bank Teller step in to facilitate distribution.

In order for an invitee to opt in to an event, they must accomplish 2 things:

- Give the BankTeller smart contract an allowance over their USDC funds by offchain signing an eip712 'permit' message that a Tipping Point EOA will
  execute to the USDC smart contract for them
- Offchain sign a different eip712 message with the details of their contribution promise. Some of those details include the event-id, the ethAddress of the
  creator of the event, the ethAddress of the invitee, and the contribution amount. This is so the invitee can review and sign off on what they are committing
  to contribute in USDC if the event "Tips", i.e. is successful. This offchain signature data is called the DestinationApproval.

Once they have submitted those 2 signatures, the invitee can sit back and wait for the event to tip or not tip by its deadline.

Now based on the event type (HeadCount, Make or Break, etc) it will tip(succeed) or not tip(not succeed) based on whether enough invitees have opted in, or if
its raised enough money by the deadline. If it has not tipped, then no funds are ever transferred. However, if an event tips, a few things happen:

- A Tipping Point EOA (marked as the "owner" address in the BankTeller smart contract) will find each invitee that opted in to the event
  and will call the BankTeller's external `transferInviteeFunds()` function, and pass in the invitees signature of the DestinationApproval message.
  The BankTeller smart contract will, using data from the DestinationApproval message, then confirm it was signed by the `from` address, a.k.a
  the invitee. It will transfer the authorized/signed `optInAmount` from the invitee to the the `to` address, a.k.a the creator, and it will transfer
  a small USDC amount called `tippingPointFee` from the `DestinationApproval` and send that to the Tipping Point `treasury` address - this fee is the
  small fee Tipping Point charges for coordinating this transfer; we currently plan to make it 1.5% of the event's goal amount split among invitees.
  This function also attempts to prevent double-spend of invitees funds to the creator by tracking a hash of the invitee address + the event id in
  a mapping called `transferSignatureExecuted`, that way we do not accidentally transfer funds multiple times. This function will be called for
  every invitee that has opted in, given the bank teller a USDC allowance, and signed their `DestinationApproval` message.

So, you see that the BankTeller smart contract literally acts as a Bank Teller by checking this IOU type message for a signature that authorizes
the transfer of funds from person A to person B. The Bank Teller is ideally programmed in a way to protect the invitee from malicious actors,
from bugs, incompetence, and even Tipping Point when they decide to opt in and sign this IOU to a creator's event. And only the Tipping Point EOA
is capable of initating this call to the Bank Teller, another line of defense, but again the Bank Teller should protect the invitee's funds
from Tipping Point itself. Currently, worst case scenario is Tipping Point sends the invitee funds to the creator prematurely or when an event
has failed, which would benefit the creator who the invitee had planned to pay anyways, and if this occurs likely hurts Tipping Point's reputation
and causes users to no longer trust Tipping Point, and does not benefit Tipping Point - this responsibility/risk is one we take on in the web2
side of logic, and have tried to mitigate how we could benefit from. We plan to make explicit that invitees should opt in and verify the
addresses for creators of events they plan to send money to.

Another external function available only to the Tipping Point `owner` EOA is the `withdrawAllowanceFee()` function. This function will be used to collect
compensation from users in the form of USDC transferred to the Tipping Point `treasury` address. This is in exchange for TP executing the `permit()`
function on the USDC contract that gave the BankTeller an allowance to transfer invitee funds(thus spending eth for gas). This function will use the same `DestinationApproval`
message that invitees signed when opting in to an event. This is so that users have less messages to sign and to make their UX easier,
rather than have them read and sign multiple eip712 messages, the `DestinationApproval` message combines opting in to an event and approving
the usdc allowance compensation. The `DestinationApproval` will be signed, verified, and the field of significance is the
`destinationApproval.approvalFee`. Now a new user who opts into an event can sign one message which will be used by TP dually, once to execute the
permit function on USDC, and one to transfer their funds when an event tips. This function also keeps track of a mapping of allowance nonces
called `approvalFeeNonces`. This is to prevent double-spend/collection of a users allowance fee by Tipping Point. Another benefit of the nonce,
is if a user runs out of an allowance or revokes an allowance, they can sign a new `DestinationApproval` message, and we can collect a new
`destinationApproval.approvalFee` thanks to the newly signed message which will have a new nonce.

**Note**: The reason for USDC compensation is Tipping Point looks to onboard new users to crypto so that they do not require eth to opt in and use the app.
We believe by making users only hold and thus use USDC, we can simplify the UX flow and experience without introducing the complication of gas fees,
other volatile currencies, executing transactions, etc. This is our way of abstracting away aspects of web3 from users in hopes of simplicity.

Next, we have the `refundEventFunds()` which unlike the other functions is external, called by the creator, and thus needs the creatot to hold eth
for the gas fees, unfortunately. We decided on this implemenation because it was simpler to have the creator cover the eth gasFees themselves,
rather than try to calculate appropriate eth-gasFee compensation and collect USDC compensation. Now the purpose and function of `refundEventFunds()`:
If for some reason an event tips, the invitee funds are distributed to the creator, and the creator decides to return the funds for possibly a
last minute cancelation, or some other reason, then this function allows TP to aggregate the list of invitee addresses that opted in + their
contributions, and present them to the Creator to sign off on via an eip712 message. Then the signed message, `RefundApproval` is submitted to
`refundEventFunds()` to iterated through the invitees array, and return their contribution. We check that the msg.sender is the creator so they
call this method directly, and we check the messages creator address it matches the signing address. We then iterate and return the USDC funds.
We use a nonce value to ensure the creator can not submit the same signed `RefundApproval` message and incidentally double-refund to the invitees.

The final function is an external function we hope to release in the future for a separate isolated event type situation, separate from events that can tip.
We plan to use this for function has RSVPs for events that will penalize invitees who do not show up to an event.
The idea is an invitee signs an eip712 message in the form of `RefundableDeposit`. The scenario is for event creators who want to plan an event and want to
ensure that people that commit to attend the event will show up and not flake, otherwise if they do then they will be penalized an amount for flaking via the execution
of the `RefundableDeposit` message, so it functions more like an RSVP than a deposit because the intention is for money not to transfer unless the creator tells
TP to execute the `RefundableDeposit` on certain invitees that did not show up to the event. The `RefundableDeposit` message will be verified for a signature,
it will transfer the `refundableDeposit.iouDepositAmount` to the creator from the invitee, and will pay `refundableDeposit.usdcGasFee` to TP as compensation
for paying the eth gas fee to transfer the funds to the creator. There is a `refundableDepositExecuted` mapping to prevent double spend as well.

**Note**: We extensively use eip712 message because we want users to be aware and to confirm what funds they may potentially send, and to whom. So,
we liberally use eip712 messages that they can read and analyze, and ideally understand.

=============================================================================================================================

 ****Functions**** 
- getDomainSeparator()
- \_hashDestinationApprovalMessage()
- \_hashRefundApprovalMessage()
- \_hashRefundableDepositMessage()
- transferInviteeFunds()
- withdrawAllowanceFee()
- refundEventFunds()
- collectRefundableDeposit()

 ****Events**** 
- AllowanceFeeTransferred
- InviteeFundsTransferred
- RefundEventFundsTransferred
- RefundableDepositTransferred

 ****Mappings**** 
- transferSignatureExecuted
- approvalFeeNonces
- refundNonces
- refundableDepositExecuted

 ****Modifiers**** 
- onlyOwner

**Notes**:

- USDC is the erc20 token we intend on primarily using, but may use other stablecoins in the future, permitting the have the functionality we need such as the permit function extension for erc20 tokens.
- A theme of this contract is ensuring most of it is only callable by the owner address, which is owned by Tipping Point, as a main level of security
- We see the BankTeller contract as a safeguard to the users from malicious actors, each other, and from Tipping Point
- For a glimpse, a staging environment of Tipping Point is live on https://staging.tippingpoint.app 