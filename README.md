
(05/19/2024) 
This page is outdated, please refer to `BankTeller.md` for more up to date details:

Refer to these additional files for context:
- `AboutUs.md`
- `HowTpWorks.md`


============================================================================================================================================================================
The General Idea:
  Tipping Point wants to facilitate coordinating money collection for groups of people(for any event or reason they can think of). 
  We want to utilize the Ethereum blockchain and the tokens/currencies currently available, right now the focus is on the USDC ERC20 token.

  When an event tips(a.k.a all requirements for number of attendees and amount raised has been met) we would like to transfer the funds from 
  the invitees to the creator. We would like to do so in a trustless way so that attendees can be confident their funds are going directly to 
  the event creator, and not to the creators of Tipping Point or any other 3rd parties seeking to rug them.

  Our initial idea was to use an escrow-type smart contract that would hold all of the attendees funds and transfer to the creator when an event
  tips, but we wanted to avoid attendees having to move their funds unless the event's tip requirements were met. 

  So, we settled on this idea of a BankTeller smart contract. We will have attendees give an erc20 allowance to this BankTeller smart
  contract to move their funds for them. Basically, this smart contract will act as a Bank Teller intermediary and only move funds from Attendee->Creator
  if the Attendee has authorized the funds for a specific event to be moved. That authorization will come in the form of a struct called DestinationApproval
  that has the following fields: 
   - DestinationApproval(
        address from;
        address to;
        uint256 amount;
        string eventId;
        uint256 approvalFee)
The Attendee will sign the DestinationApproval via a EIP-712-Typed structured data message. Only if that message is submitted by Tipping Point
to the BankTeller smart contract, and it has been signed by the Attendee (the from address), and a previous DestinationApproval has not been previously
submitted containing the same from-adddress and eventId will the BankTeller then transfer the funds from the From-address to the To-address. This occurs in
the verifyAndTransfer() function. The signatureExecuted mapping will keep track of pre-executed transfers by mapping a hash of(from + eventId) to a boolean value,
this is to help prevent replay accidents/attacks.

In order to make the UX easier, we as Tipping Point want to execute the allowance function on the users behalf as well, using the USDC permit() function that
will allow users to offchain sign a spending allowance for the BankTeller smart contract without needing eth, which tipping point will execute and cover the gas fees of. However,
we will seek reimbursement in the form of USDC from the DestinationApproval.approvalFee field, which currently is set to $1. We execute and collect this fee
in the same manner as the previous transfer and use a mapping called approvalFeeTransferred to prevent replays of the fee-transer.


The contract is still a Work in Progress and will have a method to withdraw the collected USDC fees to the owner address. Tipping Point will also collect a 1% fee from each
attendee transfer, but that has not yet been implemented as well. 
