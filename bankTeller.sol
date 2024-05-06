// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract BankTeller {
    IERC20 public USDCcoin;
    bytes32 public DOMAIN_SEPARATOR;
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }
    address immutable owner;
    mapping(bytes32 => bool) public signatureExecuted;
    mapping(bytes32 => bool) public approvalFeeTransferred;

    constructor(address _owner, address usdcCoin) {
        USDCcoin = IERC20(usdcCoin);
        owner = _owner;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("TippingPoint Transfer Contract")), // Name of the dApp
                keccak256(bytes("1")), // Version
                84532, // Replace with actual chainId
                address(this)
            )
        );
    }

    struct DestinationApproval {
        address from;
        address to;
        uint256 amount;
        string eventId;
        uint256 approvalFee; //TODO: MOOSE: set to $1 if approval fee can be collected
    }

    function getDomainSeparator() public view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    function hashMessage(
        DestinationApproval memory message
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "DestinationApproval(address from,address to,uint256 amount,string eventId,uint256 approvalFee)"
                    ),
                    message.from,
                    message.to,
                    message.amount,
                    keccak256(bytes(message.eventId)),
                    message.approvalFee
                )
            );
    }

    // TODO: We wanna batch multiple of these calls together, but we'll want to check their allowances before
    // calling the batch since it costs gas.
    function verifyAndTransfer(
        DestinationApproval memory message,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyOwner {
        // Create a unique hash for this transaction using the sender's address and the event ID
        bytes32 txHash = keccak256(
            abi.encodePacked(message.from, message.eventId)
        );
        // Check if this transaction has already been executed
        require(!signatureExecuted[txHash], "Transaction already executed");

        bytes32 hash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, hashMessage(message))
        );
        address recoveredAddress = ecrecover(hash, v, r, s);
        require(
            recoveredAddress == message.from,
            "From address must sign the transaction"
        );

        emit SignatureVerified(
            message.from,
            message.to,
            message.amount,
            message.eventId
        );

        // Placeholder for the logic to transfer USDC tokens from `message.from` to `message.to`
        bool success = USDCcoin.transferFrom(
            message.from,
            message.to,
            message.amount
        );
        if (!success) {
            emit ErrorOccurred(
                message.from,
                message.eventId,
                "Error occurred after USDC transferFrom"
            );
        }
        require(success, "USDC transfer failed");

        signatureExecuted[txHash] = true;
        emit TransactionExecuted(
            message.from,
            message.to,
            message.amount,
            message.eventId,
            success
        );
    }

    // more efficient gas wise to just send the token to the owner address.
    function verifyAndWithdrawApprovalFee(
        DestinationApproval memory message,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyOwner {
        uint256 ONE_USDC = 1_000_000;
        require(message.approvalFee == ONE_USDC, "Fee must be 1 USDC token");
        // Create a unique hash for this transaction using the sender's address and the event ID
        bytes32 txHash = keccak256(
            abi.encodePacked(message.from, message.eventId)
        );
        // Check if this transaction has already been executed
        require(
            !approvalFeeTransferred[txHash],
            "Approval Fee already paid out"
        );

        bytes32 hash = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, hashMessage(message))
        );
        address recoveredAddress = ecrecover(hash, v, r, s);
        require(
            recoveredAddress == message.from,
            "From address must sign the transaction"
        );
        emit SignatureVerified(
            message.from,
            message.to,
            message.amount,
            message.eventId
        );

        bool success = USDCcoin.transferFrom(
            message.from,
            owner,
            message.approvalFee
        );
        require(success, "approval fee transfer failed");
        approvalFeeTransferred[txHash] = true; //prevent replays of approvalFee transfer
    }

    fallback() external payable {
        revert("Contract does not accept Ether");
    }

    receive() external payable {
        revert("Contract does not accept Ether");
    }

    event SignatureVerified(
        address indexed from,
        address indexed to,
        uint256 amount,
        string eventId
    );
    event TransactionExecuted(
        address indexed from,
        address indexed to,
        uint256 amount,
        string eventId,
        bool success
    );
    event ErrorOccurred(address from, string eventId, string message);
}

/**
 * The contract should do 2 things:
 * 1. allow invitees to sign/approve transactions for destinations and
 *
 * Do we need to maintain a mapping in storage? Possibly not. My initial thoughts
 * were to keep a mappping of the allowed transfers and transactions but thats storage
 *
 * Maybe we could just verify the signature and then transfer the money but that leaves open
 * the chance for accidental replays if we have a big allowance and replay the same transaction.
 * The contract should guard against our possible folly.
 * So for that reason we can either save the actual transactions {to;from;amount;nonce}.
 * Dang, if we only keep track of a nonce, then that means if an invitee has multiple destination-transactions
 * then we have to execute them in sequential order in order to check the nonce properly
 * We could keep a mapping of hashes of pending transfers and mark them with a boolean
 * addresss => {randDestinationHash: transfered }[]
 * 0x23b3bNickr4rj : { //invitee addresss
 *      0xabcbcb33333: false,  // rand hashes for events (maybe hash the transaction data{to;from;amount;nonce})
 *      0xa278363876328: true,
 *       0xa278363876df328: true,
 *       0xn23423443433: false,
 * }
 * 2. Allow tipping point to actually transfer the usdc from invitee to creator/destination if approved
 *
 *
 *
 *
 * The question remains: do it in 2 steps or 1?
 * If were only going to transfer when the event tips, then why update the contract with a mapping of all the
 * transaction info? Why not just have a check against the transaction info and then transfer if authorized?
 * In order to avoid accidental replays we'll again keep track of authorizations already signed and executed after
 * the fact. The key can be a hash we create, what should it consist of?
 *  rand hash? No we should probably hash info pertaining to the transaction. But if there's two transactions that are
 * the same that will lead to a collision, a transaction is {to;from; amount}.
 * So it needs some sort of nonce. Should the nonce be a counter we keep track of in the contract a global nonce,
 * or a nonce pertaining to each invitee?
 *
 * Update: Better option is Signature Tracking - of (senderAddr + eventName)
 * actually, if we just hash (senderAddr + event) then we can only do transfers once per sender+event, but we need
 * to ensure its the proper amount on the transaction signed else we risk sending an incorrent amount only once.
 * So, nonce is too tricky. If we hash (senderAddr + eventName + amount + receiverAddr) then  the sender could send us
 * multiple signed transactions for 1 event and we could end up executing them all, which i dont think we want - easier
 * to just have 1 transfer per invitee -> Event-creator
 *
 *
 * Potential attack vector: have invitee sign nonsense transfer authorizations for nonsense event-id's
 */

pragma solidity ^0.8.0;

interface IERC20 {
    // Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view returns (uint256);

    // Returns the remaining number of tokens that `spender` will be
    // allowed to spend on behalf of `owner` through {transferFrom}. This is
    // zero by default.
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    // Sets `amount` as the allowance of `spender` over the caller's tokens.
    function approve(address spender, uint256 amount) external returns (bool);

    // Moves `amount` tokens from `sender` to `recipient` using the
    // allowance mechanism. `amount` is then deducted from the caller's
    // allowance.
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) external returns (bool);

    // Emitted when `value` tokens are moved from one account
}
