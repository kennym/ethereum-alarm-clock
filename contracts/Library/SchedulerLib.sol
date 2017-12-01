pragma solidity ^0.4.17;

import "contracts/Interface/RequestFactoryInterface.sol";

import "contracts/Library/PaymentLib.sol";
import "contracts/Library/RequestLib.sol";
import "contracts/Library/RequestScheduleLib.sol";

import "contracts/Library/MathLib.sol";
import "contracts/zeppelin/SafeMath.sol";

library SchedulerLib {
    using SafeMath for uint;

    address constant DONATION_BENEFACTOR = 0x0;

    struct FutureTransaction {
        address toAddress;          // Destination of the transaction.
        bytes32 callData;             // Bytecode to be included with the transaction.
        
        uint callGas;               // Amount of gas to be used with the transaction.
        uint callValue;             // Amount of ether to send with the transaction.

        uint windowSize;            // The size of the execution window.
        uint windowStart;           // Block or timestamp for when the window starts.

        uint gasPrice;              // The gasPrice to be sent with the transaction.
        
        uint donation;              // Donation value attached to the transaction.
        uint payment;               // Payment value attached to the transaction.

        uint reservedWindowSize;
        uint freezePeriod;
        uint claimWindowSize;

        RequestScheduleLib.TemporalUnit temporalUnit;
    }

    /*
     * @dev Set common default values.
     */
    function resetCommon(FutureTransaction storage self) 
        public returns (bool)
    {
        uint defaultPayment = tx.gasprice.mul(1000000);
        if (self.payment != defaultPayment) {
            self.payment = defaultPayment;
        }

        uint defaultDonation = self.payment.div(100);
        if (self.donation != defaultDonation ) {
            self.donation = defaultDonation;
        }

        if (self.toAddress != msg.sender) {
            self.toAddress = msg.sender;
        }
        if (self.callGas != 90000) {
            self.callGas = 90000;
        }
        if (self.callData.length != 0) {
            self.callData = "";
        }
        if (self.gasPrice != 10) {
            self.gasPrice = 10;
        }
        return true;
    }

    /*
     * @dev Set default values for block based scheduling.
     */
    function resetAsBlock(FutureTransaction storage self)
        public returns (bool)
    {
        assert(resetCommon(self));

        if (self.windowSize != 255) {
            self.windowSize = 255;
        }
        if (self.windowStart != block.number + 10) {
            self.windowStart = block.number + 10;
        }
        if (self.reservedWindowSize != 16) {
            self.reservedWindowSize = 16;
        }
        if (self.freezePeriod != 10) {
            self.freezePeriod = 10;
        }
        if (self.claimWindowSize != 255) {
            self.claimWindowSize = 255;
        }

        return true;
    }

    /*
     * Set default values for timestamp based scheduling.
     */
    function resetAsTimestamp(FutureTransaction storage self)
        public returns (bool)
    {
        assert(resetCommon(self));

        if (self.windowSize != 60 minutes) {
            self.windowSize = 60 minutes;
        }
        if (self.windowStart != now + 5 minutes) {
            self.windowStart = now + 5 minutes;
        }
        if (self.reservedWindowSize != 5 minutes) {
            self.reservedWindowSize = 5 minutes;
        }
        if (self.freezePeriod != 3 minutes) {
            self.freezePeriod = 3 minutes;
        }
        if (self.claimWindowSize != 60 minutes) {
            self.claimWindowSize = 60 minutes;
        }

        return true;
    }

    /**
     * @dev The lower level interface for creating a transaction request.
     * @param self The FutureTransaction object created in schedule transaction calls.
     * @param _factoryAddress The address of the RequestFactory which creates TransactionRequests.
     * @return The address of a new TransactionRequest.
     */
    function schedule(FutureTransaction storage self,
                      address _factoryAddress) 
        internal returns (address) 
    {
        RequestFactoryInterface factory = RequestFactoryInterface(_factoryAddress);

        uint endowment = MathLib.min(
            PaymentLib.computeEndowment(
                self.payment,
                self.donation,
                self.callGas,
                self.callValue,
                self.gasPrice,
                RequestLib.EXECUTION_GAS_OVERHEAD() //180000, line 459 RequestLib
        ), this.balance);

        address newRequestAddress = factory.createValidatedRequest.value(endowment)(
            [
                msg.sender,              // meta.owner
                DONATION_BENEFACTOR,     // paymentData.donationBenefactor
                self.toAddress           // txnData.toAddress
            ],
            [
                self.donation,            // paymentData.donation
                self.payment,             // paymentData.payment
                self.claimWindowSize,     // scheduler.claimWindowSize
                self.freezePeriod,        // scheduler.freezePeriod
                self.reservedWindowSize,  // scheduler.reservedWindowSize
                uint(self.temporalUnit),  // scheduler.temporalUnit (1: block, 2: timestamp)
                self.windowSize,          // scheduler.windowSize
                self.windowStart,         // scheduler.windowStart
                self.callGas,             // txnData.callGas
                self.callValue,           // txnData.callValue
                self.gasPrice             // txnData.gasPrice
            ],
            self.callData
        );
        
        require( newRequestAddress != 0x0 );
        // if (newRequestAddress == 0x0) {
        //     // Something went wrong during creation (likely a ValidationError).
        //     // Try to return the ether that was sent.  If this fails then
        //     // resort to throwing an exception to force reversion.
        //     ERROR();
        //     msg.sender.transfer(msg.value);
        //     return 0x0;
        // }

        return newRequestAddress;
    }
    
    /// Debugging purposes
    event ERROR();

}
