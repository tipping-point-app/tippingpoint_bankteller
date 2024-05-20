// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract BankTeller {
    IERC20 public usdc;
    bytes32 public DOMAIN_SEPARATOR;
    address public immutable owner;
    address public immutable treasury;

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    constructor(
        address _owner,
        address _treasury,
        address usdcCoin,
        uint chainId
    ) {
        usdc = IERC20(usdcCoin);
        owner = _owner;
        treasury = _treasury;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("TippingPoint Bank Teller Contract")), // Name of the app. Should this be a constructor param?
                keccak256(bytes("1")), // Version. Should this be a constructor param?
                chainId, // Replace with actual chainId (Base Sepolia: 84532)
                address(this)
            )
        );
    }

    struct DestinationApproval {
        address from; //invitee address
        address to; // creator address
        uint256 optInAmount; // amount donated to event
        uint256 tippingPointFee; // amount sent to tipping point as a collection fee
        string eventId; //event identifiter
        uint256 approvalFee; // fee for Tipping Point cover USDC allowance/permission call that TP will execute before the transfer of funds
        uint256 approvalFeeNonce; //nonce to prevent double spend when pulling their approval fee
        uint256 deadline; //the deadline for executing the transfer of any invitee funds
    }

    function getDomainSeparator() public view returns (bytes32) {
        return DOMAIN_SEPARATOR;
    }

    function _hashDestinationApprovalMessage(
        DestinationApproval calldata message
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "DestinationApproval(address from,address to,uint256 optInAmount,uint256 tippingPointFee,string eventId,uint256 approvalFee,uint256 deadline)"
                    ),
                    message.from,
                    message.to,
                    message.optInAmount,
                    message.tippingPointFee,
                    keccak256(bytes(message.eventId)),
                    message.approvalFee,
                    message.deadline
                )
            );
    }

    function _hashRefundApprovalMessage(
        RefundApproval calldata message
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "RefundApproval(address creator,string eventId,address[] invitees,uint256[] amounts,uint256 refundNonce)"
                    ),
                    message.creator,
                    keccak256(bytes(message.eventId)),
                    keccak256(abi.encodePacked(message.invitees)),
                    keccak256(abi.encodePacked(message.amounts)),
                    message.refundNonce
                )
            );
    }

    function _hashRefundableDepositMessage(
        RefundableDeposit calldata message
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "RefundableDeposit(address invitee,address creator,uint256 iouDepositAmount,string eventId,uint256 usdcGasFee)"
                    ),
                    message.invitee,
                    message.creator,
                    message.iouDepositAmount,
                    keccak256(bytes(message.eventId)),
                    message.usdcGasFee
                )
            );
    }

    mapping(bytes32 => bool) public transferSignatureExecuted;

    /**
     * The purpose of this function is for the TP EOA to be able to initiate the transfer of funds from an invitee to an event creator
     * for an event they have opted-in to and have made a commitment to pay funds to participate in that event, or support it.
     * This function seeks to avoid double spend, ensure the invitee signed the message, and transfer funds to the creator, and a fee to
     * Tipping Points treasury address in the form of USDC.
     */
    function transferInviteeFunds(
        DestinationApproval calldata destinationApproval,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyOwner {
        // Create a unique hash for this transaction using the sender's address and the event ID
        bytes32 inviteeEventIdHash = keccak256(
            abi.encodePacked(
                destinationApproval.from,
                destinationApproval.eventId
            )
        );
        // Check if this transaction has already been executed to prevent double spend/transfer
        require(
            !transferSignatureExecuted[inviteeEventIdHash],
            "Transaction already executed"
        );
        require(
            block.timestamp < destinationApproval.deadline,
            "The DestinationApproval deadline has passed"
        );

        bytes32 hashedDestinationApproval = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashDestinationApprovalMessage(destinationApproval)
            )
        );
        address recoveredAddress = ecrecover(
            hashedDestinationApproval,
            v,
            r,
            s
        );
        require(
            recoveredAddress == destinationApproval.from,
            "The 'from' address(invitee) must sign the DestinationApproval message"
        );

        // Following Check-Effects-Interaction (require calls first, then update state/mapping, then transfer funds)
        transferSignatureExecuted[inviteeEventIdHash] = true;

        //send funds from invitee to creator
        bool optInTransferSuccess = usdc.transferFrom(
            destinationApproval.from,
            destinationApproval.to,
            destinationApproval.optInAmount
        );

        require(optInTransferSuccess, "USDC transfer to creator failed");

        // send the Tipping Point fee to Tipping Point treasury address
        bool tippingPointFeeTransferSuccess = usdc.transferFrom(
            destinationApproval.from,
            treasury,
            destinationApproval.tippingPointFee
        );
        require(
            tippingPointFeeTransferSuccess,
            "USDC fee transfer to Tipping Point failed"
        );
        emit InviteeFundsTransferred(
            destinationApproval.eventId,
            destinationApproval.from,
            destinationApproval.to,
            destinationApproval.optInAmount,
            destinationApproval.tippingPointFee
        );
    }

    /**
     * The purpose of this function is to collect a fee as compensation for executing the permission call to the USDC contract on behalf of the invitee,
     * so that the BankTeller smart contract would have a USDC allowance to transfer on their behalf for tipped events. This may be called before or after
     * executing the permission/"permit" call for the invitee. The permit call is a gasless way of executing contract calls on behalf of an EOA (in this case being the invitee).
     */
    mapping(address => uint256) public approvalFeeNonces;

    function withdrawAllowanceFee(
        DestinationApproval calldata destinationApproval,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyOwner {
        require(
            block.timestamp < destinationApproval.deadline,
            "The DestinationApproval deadline has passed"
        );
        bytes32 hashedDestinationApproval = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashDestinationApprovalMessage(destinationApproval)
            )
        );
        address recoveredAddress = ecrecover(
            hashedDestinationApproval,
            v,
            r,
            s
        );
        require(
            recoveredAddress == destinationApproval.from,
            "From address must sign the transaction"
        );
        require(
            approvalFeeNonces[recoveredAddress] ==
                destinationApproval.approvalFeeNonce,
            "Invalid nonce"
        );

        approvalFeeNonces[recoveredAddress]++; //mark nonce as used
        bool success = usdc.transferFrom(
            destinationApproval.from,
            treasury,
            destinationApproval.approvalFee
        );
        require(success, "approval fee transfer failed");

        emit AllowanceFeeTransferred(
            destinationApproval.from,
            destinationApproval.eventId,
            destinationApproval.approvalFee
        );
    }

    struct RefundApproval {
        address creator;
        string eventId;
        address[] invitees;
        uint256[] amounts;
        uint refundNonce;
    }
    mapping(address => uint256) public refundNonces;

    /**
     * The purpose of this function is for an event-creatot to refunds all the funds collected from invitees for a successfully tipped event,
     * for whatever reason. This requires they seign an eip-712 message in the form of the RefundApproval struct to confirm the invitees and amounts
     * to return. The creator should also execute this call, and thus cover the gas fees.
     */
    function refundEventFunds(
        RefundApproval calldata refundApproval,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        //require the call to be initiated by creator msg.sender
        require(
            msg.sender == refundApproval.creator,
            "Creator address must call the function"
        );
        // prevent double submission/refunding by creator, perhaps by accident.
        require(
            refundNonces[refundApproval.creator] == refundApproval.refundNonce,
            "invalid nonce"
        );

        bytes32 hashedDestinationApproval = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashRefundApprovalMessage(refundApproval)
            )
        );
        address recoveredAddress = ecrecover(
            hashedDestinationApproval,
            v,
            r,
            s
        );
        // Is this require for ecrecover overkill? Maybe good enough to just check msg.sender?
        require(
            recoveredAddress == refundApproval.creator,
            "The 'creator' address must sign the RefundApproval message"
        );
        uint256 totalRefunded = 0;
        for (uint256 i = 0; i < refundApproval.invitees.length; i++) {
            bool success = usdc.transferFrom(
                refundApproval.creator,
                refundApproval.invitees[i],
                refundApproval.amounts[i]
            );
            require(success, "approval fee transfer failed");
            totalRefunded += refundApproval.amounts[i];
        }
        refundNonces[recoveredAddress]++; //mark nonce as used

        emit RefundEventFundsTransferred(
            refundApproval.eventId,
            refundApproval.creator,
            totalRefunded,
            refundApproval.invitees.length
        );
    }

    struct RefundableDeposit {
        address invitee;
        address creator;
        uint iouDepositAmount;
        string eventId;
        uint usdcGasFee;
    }
    /**
     * The purpose of this function is for a creator of a Refundable Deposit event to be able to collect the IOU-deposit promises from
     * invitees. The invitees will approve the IOU-Deposits by signing eip-712 messages in the form of a RefundableDeposit struct
     */
    mapping(bytes32 => bool) public refundableDepositExecuted;

    function collectRefundableDeposit(
        RefundableDeposit calldata refundableDeposit,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyOwner {
        // confirm the invitee signed the RefundableDeposit
        bytes32 hashedRefundableDeposit = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                _hashRefundableDepositMessage(refundableDeposit)
            )
        );
        address recoveredAddress = ecrecover(hashedRefundableDeposit, v, r, s);
        require(
            recoveredAddress == refundableDeposit.invitee,
            "The 'invitee' address must sign the RefundableDeposit message"
        );
        // we want to mark the event+invitee hash as executed: refundableDepositExecutedOrVoided[hash] = true
        bytes32 inviteeEventIdHash = keccak256(
            abi.encodePacked(
                refundableDeposit.invitee,
                refundableDeposit.eventId
            )
        );
        refundableDepositExecuted[inviteeEventIdHash] = true;

        // we want to transfer the refundableDeposit.amount from refundableDeposit.invitee to refundableDeposit.creator
        bool depositTransferred = usdc.transferFrom(
            refundableDeposit.invitee,
            refundableDeposit.creator,
            refundableDeposit.iouDepositAmount
        );
        require(depositTransferred, "Transfer of refundable deposit failed");

        bool gasFeeTransferred = usdc.transferFrom(
            refundableDeposit.invitee,
            treasury,
            refundableDeposit.usdcGasFee
        );
        require(
            gasFeeTransferred,
            "Transfer of refundable deposit gas fee failed"
        );

        // emit events
        emit RefundableDepositTransferred(
            refundableDeposit.eventId,
            refundableDeposit.creator,
            refundableDeposit.invitee,
            refundableDeposit.iouDepositAmount,
            refundableDeposit.usdcGasFee
        );
    }

    fallback() external payable {
        revert("Does not accept Ether");
    }

    receive() external payable {
        revert("Does not accept Ether");
    }

    event AllowanceFeeTransferred(
        address indexed from,
        string indexed eventId,
        uint256 allowanceFee
    );
    event InviteeFundsTransferred(
        string indexed eventId,
        address indexed from,
        address indexed to,
        uint256 optInAmount,
        uint256 tippingPointFee
    );
    event RefundEventFundsTransferred(
        string indexed eventId,
        address indexed creator,
        uint256 totalRefunded,
        uint256 numOfPplRefunded
    );
    event RefundableDepositTransferred(
        string indexed eventId,
        address indexed creator,
        address invitee,
        uint256 iouDepositAmount,
        uint256 usdcGasFee
    );
}

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
}
