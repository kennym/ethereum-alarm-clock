pragma solidity ^0.4.17;

import "contracts/Library/ClaimLib.sol";
import "contracts/Library/ExecutionLib.sol";
import "contracts/Library/PaymentLib.sol";
import "contracts/Library/RequestMetaLib.sol";
import "contracts/Library/RequestScheduleLib.sol";

import "contracts/Library/MathLib.sol";
import "contracts/zeppelin/SafeMath.sol";

library RequestLib {
    using ExecutionLib for ExecutionLib.ExecutionData;
    using RequestScheduleLib for RequestScheduleLib.ExecutionWindow;
    using ClaimLib for ClaimLib.ClaimData;
    using RequestMetaLib for RequestMetaLib.RequestMeta;
    using PaymentLib for PaymentLib.PaymentData;
    using SafeMath for uint;

    /*
     *  This struct exists to circumvent an issue with returning multiple
     *  values from a library function.  I found through experimentation that I
     *  could not return more than 4 things from a library function, even if I
     *  put them in arrays. - Piper
     */
    struct SerializedRequest {
        address[6] addressValues;
        bool[3] boolValues;
        uint[15] uintValues;
        uint8[1] uint8Values;
    }

    struct Request {
        ExecutionLib.ExecutionData txnData;
        RequestMetaLib.RequestMeta meta;
        PaymentLib.PaymentData paymentData;
        ClaimLib.ClaimData claimData;
        RequestScheduleLib.ExecutionWindow schedule;
        SerializedRequest serializedValues;
    }

    enum AbortReason {
        WasCancelled,       //0
        AlreadyCalled,      //1
        BeforeCallWindow,   //2
        AfterCallWindow,    //3
        ReservedForClaimer, //4
        InsufficientGas     //5
    }

    event Cancelled(uint rewardPayment, uint measuredGasConsumption);
    event Claimed();
    event Aborted(uint8 reason);
    event Executed(uint payment, uint donation, uint measuredGasConsumption);

    /**
     * @dev Validate the initialization parameters for a transaction request.
     * Public view function
     */
    function validate(
        address[4] addressArgs,
        uint[11] uintArgs,
        bytes32 callData,
        uint endowment
    ) 
        public view returns (bool[6] isValid)
    {
        Request memory request;

        // callData is special.
        request.txnData.callData = callData;

        // Address values
        request.claimData.claimedBy = 0x0;
        request.meta.createdBy = addressArgs[0];
        request.meta.owner = addressArgs[1];
        request.paymentData.donationBenefactor = addressArgs[2];
        request.paymentData.donationBenefactor = 0x0;
        request.txnData.toAddress = addressArgs[3];

        // Boolean values
        request.meta.isCancelled = false;
        request.meta.wasCalled = false;
        request.meta.wasSuccessful = false;

        // UInt values
        request.claimData.claimDeposit = 0;
        request.paymentData.gasPrice = tx.gasprice;
        request.paymentData.donation = uintArgs[0];
        request.paymentData.payment = uintArgs[1];
        request.paymentData.donationOwed = 0;
        request.paymentData.paymentOwed = 0;
        request.schedule.claimWindowSize = uintArgs[2];
        request.schedule.freezePeriod = uintArgs[3];
        request.schedule.reservedWindowSize = uintArgs[4];
        // This must be capped at 1 or it throws an exception.
        request.schedule.temporalUnit = RequestScheduleLib.TemporalUnit(MathLib.min(uintArgs[5], 2));
        request.schedule.windowSize = uintArgs[6];
        request.schedule.windowStart = uintArgs[7];
        request.txnData.callGas = uintArgs[8];
        request.txnData.callValue = uintArgs[9];

        // Uint8 values
        request.claimData.paymentModifier = 0;

        // The order of these errors matters as it determines which
        // ValidationError event codes are logged when validation fails.
        isValid[0] = PaymentLib.validateEndowment(
            endowment,
            request.paymentData.payment,
            request.paymentData.donation,
            request.txnData.callGas,
            request.txnData.callValue,
            _EXECUTION_GAS_OVERHEAD
        );
        isValid[1] = RequestScheduleLib.validateReservedWindowSize(
            request.schedule.reservedWindowSize,
            request.schedule.windowSize
        );
        isValid[2] = RequestScheduleLib.validateTemporalUnit(uintArgs[5]);
        isValid[3] = RequestScheduleLib.validateWindowStart(
            request.schedule.temporalUnit,
            request.schedule.freezePeriod,
            request.schedule.windowStart
        );
        isValid[4] = ExecutionLib.validateCallGas(
            request.txnData.callGas,
            _EXECUTION_GAS_OVERHEAD
        );
        isValid[5] = ExecutionLib.validateToAddress(request.txnData.toAddress);

        /// Automatically returns isValid
    }

    /*
     *  Initialize a new Request.
     */
    function initialize(
        Request storage self,
        address[4] addressArgs,
        uint[11] uintArgs,
        bytes32 callData
    ) 
        public returns (bool initialized)
    {
        address[6] memory addressValues = [
            0x0,             // self.claimData.claimedBy
            addressArgs[0],  // self.meta.createdBy
            addressArgs[1],  // self.meta.owner
            addressArgs[2],  // self.paymentData.donationBenefactor
            0x0,             // self.paymentData.paymentBenefactor
            addressArgs[3]   // self.txnData.toAddress
        ];

        bool[3] memory boolValues = [false, false, false];

        uint[15] memory uintValues = [
            0,               // self.claimData.claimDeposit
            tx.gasprice,     // self.paymentData.gasPrice
            uintArgs[0],     // self.paymentData.donation
            0,               // self.paymentData.donationOwed
            uintArgs[1],     // self.paymentData.payment
            0,               // self.paymentData.paymentOwed
            uintArgs[2],     // self.schedule.claimWindowSize
            uintArgs[3],     // self.schedule.freezePeriod
            uintArgs[4],     // self.schedule.reservedWindowSize
            uintArgs[5],     // self.schedule.temporalUnit
            uintArgs[6],     // self.schedule.windowSize
            uintArgs[7],     // self.schedule.windowStart
            uintArgs[8],     // self.txnData.callGas
            uintArgs[9],     // self.txnData.callValue
            uintArgs[10]     // self.txnData.gasPrice
        ];

        uint8[1] memory uint8Values = [
            0
        ];

        deserialize(self, addressValues, boolValues, uintValues, uint8Values, callData);

        initialized = true;
    }

    /*
     *  Returns the entire data structure of the Request in a *serialized*
     *  format.  This will be missing the `callData` which must be requested
     *  separately
     *
     *  Parameter order is alphabetical by type, then namespace, then name
     *
     *  NOTE: This exists because of an issue I ran into related to returning
     *  multiple values from a library function.  I found through
     *  experimentation that I was unable to return more than 4 things, even if
     *  I used the trick of returning arrays of items.
     */
    function serialize(Request storage self) 
        internal returns (bool serialized)
    {
        // Address values
        self.serializedValues.addressValues[0] = self.claimData.claimedBy;
        self.serializedValues.addressValues[1] = self.meta.createdBy;
        self.serializedValues.addressValues[2] = self.meta.owner;
        self.serializedValues.addressValues[3] = self.paymentData.donationBenefactor;
        self.serializedValues.addressValues[4] = self.paymentData.paymentBenefactor;
        self.serializedValues.addressValues[5] = self.txnData.toAddress;

        // Boolean values
        self.serializedValues.boolValues[0] = self.meta.isCancelled;
        self.serializedValues.boolValues[1] = self.meta.wasCalled;
        self.serializedValues.boolValues[2] = self.meta.wasSuccessful;

        // UInt256 values
        self.serializedValues.uintValues[0] = self.claimData.claimDeposit;
        self.serializedValues.uintValues[1] = self.paymentData.gasPrice;
        self.serializedValues.uintValues[2] = self.paymentData.donation;
        self.serializedValues.uintValues[3] = self.paymentData.donationOwed;
        self.serializedValues.uintValues[4] = self.paymentData.payment;
        self.serializedValues.uintValues[5] = self.paymentData.paymentOwed;
        self.serializedValues.uintValues[6] = self.schedule.claimWindowSize;
        self.serializedValues.uintValues[7] = self.schedule.freezePeriod;
        self.serializedValues.uintValues[8] = self.schedule.reservedWindowSize;
        self.serializedValues.uintValues[9] = uint(self.schedule.temporalUnit);
        self.serializedValues.uintValues[10] = self.schedule.windowSize;
        self.serializedValues.uintValues[11] = self.schedule.windowStart;
        self.serializedValues.uintValues[12] = self.txnData.callGas;
        self.serializedValues.uintValues[13] = self.txnData.callValue;
        self.serializedValues.uintValues[14] = self.txnData.gasPrice;

        // Uint8 values
        self.serializedValues.uint8Values[0] = self.claimData.paymentModifier;

        serialized = true;
    }

    /*
     *  Populates a Request object from the full output of `serialize`.
     *
     *  Parameter order is alphabetical by type, then namespace, then name.
     */
    function deserialize(
        Request storage self,
        address[6] addressValues,
        bool[3] boolValues,
        uint[15] uintValues,
        uint8[1] uint8Values,
        bytes32 callData
    )
        internal returns (bool deserialized)
    {
        // callData is special.
        self.txnData.callData = callData;

        // Address values
        self.claimData.claimedBy = addressValues[0];
        self.meta.createdBy = addressValues[1];
        self.meta.owner = addressValues[2];
        self.paymentData.donationBenefactor = addressValues[3];
        self.paymentData.paymentBenefactor = addressValues[4];
        self.txnData.toAddress = addressValues[5];

        // Boolean values
        self.meta.isCancelled = boolValues[0];
        self.meta.wasCalled = boolValues[1];
        self.meta.wasSuccessful = boolValues[2];

        // UInt values
        self.claimData.claimDeposit = uintValues[0];
        self.paymentData.gasPrice = uintValues[1];
        self.paymentData.donation = uintValues[2];
        self.paymentData.donationOwed = uintValues[3];
        self.paymentData.payment = uintValues[4];
        self.paymentData.paymentOwed = uintValues[5];
        self.schedule.claimWindowSize = uintValues[6];
        self.schedule.freezePeriod = uintValues[7];
        self.schedule.reservedWindowSize = uintValues[8];
        self.schedule.temporalUnit = RequestScheduleLib.TemporalUnit(uintValues[9]);
        self.schedule.windowSize = uintValues[10];
        self.schedule.windowStart = uintValues[11];
        self.txnData.callGas = uintValues[12];
        self.txnData.callValue = uintValues[13];

        // Uint8 values
        self.claimData.paymentModifier = uint8Values[0];

        deserialized = true;
    }

    function execute(Request storage self) 
        internal returns (bool)
    {
        /*
         *  Execute the TransactionRequest
         *
         *  +---------------------+
         *  | Phase 1: Validation |
         *  +---------------------+
         *
         *  Must pass all of the following checks:
         *
         *  1. Not already called.
         *  2. Not cancelled.
         *  3. Not before the execution window.
         *  4. Not after the execution window.
         *  5. if (claimedBy == 0x0 or msg.sender == claimedBy):
         *         - windowStart <= block.number
         *         - block.number <= windowStart + windowSize
         *     else if (msg.sender != claimedBy):
         *         - windowStart + reservedWindowSize <= block.number
         *         - block.number <= windowStart + windowSize
         *     else:
         *         - throw (should be impossible)
         *  6. if (msg.sender != tx.origin):
         *         - Verify stack can be increased by requiredStackDepth
         *  7. msg.gas >= callGas
         *
         *  +--------------------+
         *  | Phase 2: Execution |
         *  +--------------------+
         *
         *  1. Mark as called (must be before actual execution to prevent
         *     re-entrance.
         *  2. Send Transaction and record success or failure.
         *
         *  +---------------------+
         *  | Phase 3: Accounting |
         *  +---------------------+
         *
         *  1. Calculate and send donation amount.
         *  2. Calculate and send payment amount.
         *  3. Send remaining ether back to owner.
         *
         */
        uint startGas = msg.gas;

        // +----------------------+
        // | Begin: Authorization |
        // +----------------------+

        if (msg.gas < requiredExecutionGas(self).sub(_PRE_EXECUTION_GAS)) {
            Aborted(uint8(AbortReason.InsufficientGas));
            return false;
        } else if (self.meta.wasCalled) {
            Aborted(uint8(AbortReason.AlreadyCalled));
            return false;
        } else if (self.meta.isCancelled) {
            Aborted(uint8(AbortReason.WasCancelled));
            return false;
        } else if (self.schedule.isBeforeWindow()) {
            Aborted(uint8(AbortReason.BeforeCallWindow));
            return false;
        } else if (self.schedule.isAfterWindow()) {
            Aborted(uint8(AbortReason.AfterCallWindow));
            return false;
        } else if (self.claimData.isClaimed() &&
                   msg.sender != self.claimData.claimedBy &&
                   self.schedule.inReservedWindow()) {
            Aborted(uint8(AbortReason.ReservedForClaimer));
            return false;
        }

        // +--------------------+
        // | End: Authorization |
        // +--------------------+
        // +------------------+
        // | Begin: Execution |
        // +------------------+

        // Mark as being called before sending transaction to prevent re-entrance.
        self.meta.wasCalled = true;

        // Send the transaction
        self.meta.wasSuccessful = self.txnData.sendTransaction();
        require( self.meta.wasSuccessful );

        // +----------------+
        // | End: Execution |
        // +----------------+
        // +-------------------+
        // | Begin: Accounting |
        // +-------------------+

        // Compute the donation amount
        if (self.paymentData.hasBenefactor()) {
            self.paymentData.donationOwed = self.paymentData.getDonation()
                                                            .add(self.paymentData.donationOwed);
        }

        // record this so that we can log it later.
        uint totalDonationPayment = self.paymentData.donationOwed;
        // debug(totalDonationPayment);
        // Send the donation.
        /// Bug vvv
        self.paymentData.sendDonation();

        // Compute the payment amount and who it should be sent do.
        self.paymentData.paymentBenefactor = msg.sender;
        if (self.claimData.isClaimed()) {
            self.paymentData.paymentOwed = self.claimData.claimDeposit.add(self.paymentData.paymentOwed);
            // need to zero out the claim deposit since it is now accounted for
            // in the paymentOwed value.
            self.claimData.claimDeposit = 0;
            self.paymentData.paymentOwed = self.paymentData.getPaymentWithModifier(self.claimData.paymentModifier)
                                                           .add(self.paymentData.paymentOwed);
        } else {
            self.paymentData.paymentOwed = self.paymentData.getPayment()
                                                           .add(self.paymentData.paymentOwed);
        }

        // Record the amount of gas used by execution.
        uint measuredGasConsumption = startGas.sub(msg.gas).add(_EXECUTE_EXTRA_GAS);

        // // +----------------------------------------------------------------------+
        // // | NOTE: All code after this must be accounted for by EXECUTE_EXTRA_GAS |
        // // +----------------------------------------------------------------------+

        // Add the gas reimbursment amount to the payment.
        self.paymentData.paymentOwed = measuredGasConsumption.mul(tx.gasprice)
                                                             .add(self.paymentData.paymentOwed);

        // Log the two payment amounts.  Otherwise it is non-trivial to figure
        // out how much was payed.
        Executed(self.paymentData.paymentOwed,
                 totalDonationPayment,
                 measuredGasConsumption);
    
        // Send the payment.
        // FIXME: NO MORE PUSHES FOR PAYMENTS, CLIENTS MUST CALL
        self.paymentData.sendPayment();

        // Send all extra ether back to the owner.
        sendOwnerEther(self);

        // +-----------------+
        // | End: Accounting |
        // +-----------------+
        return true;
    }


    // This is the amount of gas that it takes to enter from the
    // `TransactionRequest.execute()` contract into the `RequestLib.execute()`
    // method at the point where the gas check happens.
    uint private constant _PRE_EXECUTION_GAS = 25000;   // TODO is this number still accurate?

    function PRE_EXECUTION_GAS()
        public pure returns (uint)
    {
        return _PRE_EXECUTION_GAS;
    }

    function requiredExecutionGas(Request storage self) 
        public view returns (uint)
    {
        uint requiredGas = self.txnData.callGas.add(_EXECUTION_GAS_OVERHEAD);

        // if (msg.sender != tx.origin) {
        //     var stackCheckGas = ExecutionLib.GAS_PER_DEPTH()
        //                                     .mul(self.txnData.requiredStackDepth);
        //     requiredGas = requiredGas.add(stackCheckGas);
        // }

        return requiredGas;
    }

    /*
     * The amount of gas needed to complete the execute method after
     * the transaction has been sent.
     */
    uint private constant _EXECUTION_GAS_OVERHEAD = 180000; // TODO check accuracy of this number

    function EXECUTION_GAS_OVERHEAD()
        public pure returns (uint)
    {
        return _EXECUTION_GAS_OVERHEAD;
    }

    
    /*
     *  The amount of gas used by the portion of the `execute` function
     *  that cannot be accounted for via gas tracking.
     */
    uint private constant  _EXECUTE_EXTRA_GAS = 90000; // Same... Doubled this from Piper's original - Logan

    function EXECUTE_EXTRA_GAS() 
        public pure returns (uint)
    {
        return _EXECUTE_EXTRA_GAS;
    }

    /*
     * @dev Performs the checks to see if a request can be cancelled.
     *  Must satisfy the following conditions.
     *
     *  1. Not Cancelled
     *  2. either:
     *    * not wasCalled && afterExecutionWindow
     *    * not claimed && beforeFreezeWindow && msg.sender == owner
     */
    function isCancellable(Request storage self) 
        internal returns (bool)
    {
        if (self.meta.isCancelled) {
            // already cancelled!
            return false;
        } else if (!self.meta.wasCalled && self.schedule.isAfterWindow()) {
            // not called but after the window
            return true;
        } else if (!self.claimData.isClaimed() && self.schedule.isBeforeFreeze() && msg.sender == self.meta.owner) {
            // not claimed and before freezePeriod and owner is cancelling
            return true;
        } else {
            // otherwise cannot cancel
            return false;
        }
    }

    /*
     *  Constant value to account for the gas usage that cannot be accounted
     *  for using gas-tracking within the `cancel` function.
     */
    uint private constant _CANCEL_EXTRA_GAS = 85000; // Check accuracy

    function CANCEL_EXTRA_GAS() 
        public pure returns (uint)
    {
        return _CANCEL_EXTRA_GAS;
    }

    /*
     *  Cancel the transaction request, attempting to send all appropriate
     *  refunds.  To incentivise cancellation by other parties, a small reward
     *  payment is issued to the party that cancels the request if they are not
     *  the owner.
     */
    function cancel(Request storage self) 
        public returns (bool)
    {
        uint startGas = msg.gas;
        uint rewardPayment;
        uint measuredGasConsumption;

        /// Checks if this transactionRequest can be cancelled.
        require( isCancellable(self) );

        /// Set here to prevent re-entrance attacks.
        self.meta.isCancelled = true;

        /// Refund the claim deposit (if there is one)
        require( self.claimData.refundDeposit() );

        /// Send a reward to the canceller if they are not the owner.
        /// This is to incentivize the cancelling of expired transactionRequests.
        // This also guarantees that it is being cancelled after the call window
        // since the `isCancellable()` function checks this.
        if (msg.sender != self.meta.owner) {
            /// Create the rewardBenefactor
            address rewardBenefactor = msg.sender;
            /// Create the rewardOwed variable, it is paymentOwed and one-hundredth
            /// of the payment.
            uint rewardOwed = self.paymentData.paymentOwed.add(
                self.paymentData.payment.div(100)
            );

            /// Calc the amount of gas caller used to call this function.
            measuredGasConsumption = startGas.sub(msg.gas).add(_CANCEL_EXTRA_GAS);
            /// Add their gas fees to the reward.
            rewardOwed = measuredGasConsumption.mul(tx.gasprice).add(rewardOwed);

            /// Take note of the rewardPayment to log it.
            rewardPayment = rewardOwed;

            /// Transfers the rewardPayment.
            if (rewardOwed > 0) { // ? - will it ever not be above zero?
                self.paymentData.paymentOwed = 0;
                rewardBenefactor.transfer(rewardOwed);
            }
        }

        /// Logs are our friends.
        Cancelled(rewardPayment, measuredGasConsumption);

        // send the remaining ether to the owner.
        // return sendOwnerEther(self);
        return true;
    }

    /*
     * @dev Performs the checks to verify that a request is claimable.
     * @param self The Request object.
     */
    function isClaimable(Request storage self) 
        internal view returns (bool)
    {
        /// Require not claimed and not cancelled.
        require( !self.claimData.isClaimed() );
        require( !self.meta.isCancelled );

        // Require that it's in the claim window and the value sent is over the min deposit.
        require( self.schedule.inClaimWindow() );
        require( msg.value > ClaimLib.requiredDeposit(self.paymentData.payment) ); // requiredDeposit is * 2
        return true;
    }

    /*
     * @dev Claims the request.
     * @param self The Request object.
     * Payable because it requires the sender to send enough ether to cover the claimDeposit.
     */
    function claim(Request storage self) 
        internal returns (bool claimed)
    {
        require( isClaimable(self) );

        self.claimData.claim(self.schedule.computePaymentModifier());
        Claimed();
        claimed = true;
    }

    /*
     * @dev Refund claimer deposit.
     */
    function refundClaimDeposit(Request storage self)
        public
    {
        assert( self.meta.isCancelled || self.schedule.isAfterWindow() );
        assert( self.claimData.refundDeposit() );
    }

    /*
     * Send donation
     */
    function sendDonation(Request storage self) 
        public returns (bool)
    {
        if (self.schedule.isAfterWindow()) {
            return self.paymentData.sendDonation();
        }
        return false;
    }

    /*
     * Send payment
     */
    function sendPayment(Request storage self) 
        public returns (bool)
    {
        if (self.schedule.isAfterWindow()) {
            return self.paymentData.sendPayment();
        }
        return false;
    }

    function sendOwnerEther(Request storage self) 
        internal returns (bool)
    {
        if ( self.meta.isCancelled || self.schedule.isAfterWindow() ) {
            uint ownerRefund = this.balance.sub(self.claimData.claimDeposit)
                                            .sub(self.paymentData.paymentOwed)
                                            .sub(self.paymentData.donationOwed);
            self.meta.owner.transfer(ownerRefund);
            return true;
        }
        return false;
    }
}
