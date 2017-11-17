pragma solidity ^0.4.17;

import "contracts/Library/ExecutionLib.sol";
import "contracts/Library/MathLib.sol";
import "contracts/zeppelin/SafeMath.sol";

library PaymentLib {
    using SafeMath for uint;

    struct PaymentData {
        // The gas price that was used during creation of this request.
        // FIXME: Going away
        uint anchorGasPrice;

        // The amount in wei that will be payed to the address that executes
        // this request.
        uint payment;

        // The address that the payment should be sent to.
        address paymentBenefactor;

        // The amount that is owed to the payment benefactor.
        uint paymentOwed;

        // The amount in wei that will be payed to the donationBenefactor address.
        // FIXME: call it affiliate
        uint donation;

        // The address that the donation should be sent to.
        // FIXME: Call it affiliate
        address donationBenefactor;

        // The amount that is owed to the donation benefactor.
        uint donationOwed;
    }

    /*
     * @dev Getter function that returns true if a request has a benefactor.
     */
    function hasBenefactor(PaymentData storage self)
        public view returns (bool)
    {
        return self.donationBenefactor != 0x0;
    }

    /*
    *  Return a number between 0 - 200 to scale the donation based on the
    *  gas price set for the calling transaction as compared to the gas
 {   *  price of the scheduling transaction.
    *
    *  - number approaches zero as the transaction gas price goes
    *  above the gas price recorded when the call was scheduled.
    *
    *  - the number approaches 200 as the transaction gas price
    *  drops under the price recorded when the call was scheduled.
    *
    *  This encourages lower gas costs as the lower the gas price
    *  for the executing transaction, the higher the payout to the
    *  caller.
    */
    function getMultiplier(PaymentData storage self) 
        returns (uint)
    {
        if (tx.gasprice > self.anchorGasPrice) {
            return self.anchorGasPrice.mul(100).div(tx.gasprice);
        } else {
            return 200 - MathLib.min(
                (self.anchorGasPrice.mul(100).div(self.anchorGasPrice.mul(2)) ///.sub(tx.gasprice))
                ), 200);
        }
    }

    /*
     * @dev Computes the amount to send to the donationBenefactor. 
     */
    function getDonation(PaymentData storage self) 
        internal returns (uint)
    {
        if (getMultiplier(self) == 0) {
            return 0;
        } else {
            return self.donation.mul(getMultiplier(self)).div(100);
        }
    }

    /*
     * @dev Computes the amount to send to the address that fulfilled the request.
     */
    function getPayment(PaymentData storage self)
        returns (uint)
    {
        return self.payment.mul(getMultiplier(self)).div(100);
    }
 
    /*
     * @dev Computes the amount to send to the address that fulfilled the request
     *       with an additional modifier. This is used when the call was claimed.
     */
    function getPaymentWithModifier(PaymentData storage self,
                                    uint8 paymentModifier)
        returns (uint)
    {
        return getPayment(self).mul(paymentModifier).div(100);
    }

    /*
     * @dev Send the donationOwed amount to the donationBenefactor.
     */
    function sendDonation(PaymentData storage self) 
        returns (bool)
    {
        uint donationAmount = self.donationOwed;
        if (donationAmount > 0) {
            // re-entrance protection.
            self.donationOwed = 0;
            self.donationBenefactor.transfer(donationAmount);
            // self.donationOwed = donationAmount.flooredSub(self.donationBenefactor.transfer(donationAmount));
        }
        return true;
    }

    /*
     * @dev Send the paymentOwed amount to the paymentBenefactor.
     */
    function sendPayment(PaymentData storage self)
        returns (bool)
    {
        uint paymentAmount = self.paymentOwed;
        if (paymentAmount > 0) {
            // re-entrance protection.
            self.paymentOwed = 0;
            // self.paymentBenefactor.transfer(paymentAmount);
            // self.paymentOwed = paymentAmount.flooredSub(self.paymentBenefactor.transfer(paymentAmount));
        }
        return true;
    }


    /*
     * @dev Compute the required endowment value for the given TransactionRequest
     *       parameters.
     */
    function computeEndowment(uint payment,
                              uint donation,
                              uint callGas,
                              uint callValue,
                              uint gasOverhead) 
        internal view returns (uint)
    {
        uint gasPrice = tx.gasprice;
        return payment.add(donation)
                      .mul(2)
                      .add(_computeHelper(callGas, callValue, gasOverhead, gasPrice));
    }

    /// Was getting a stack depth error after replacing old MathLib with Zeppelin's SafeMath.
    ///  Added this function to fix it.
    ///  See for context: https://ethereum.stackexchange.com/questions/7325/stack-too-deep-try-removing-local-variables 
    function _computeHelper(uint _callGas, uint _callValue, uint _gasOverhead, uint _gasPrice)
        internal pure returns (uint)
    {
        return _callGas.mul(_gasPrice).mul(2)
                      .add(_gasOverhead.mul(_gasPrice).mul(2))
                      .add(_callValue);
    }
    /*
     * Validation: ensure that the request endowment is sufficient to cover.
     * - payment * maxMultiplier
     * - donation * maxMultiplier
     * - stack depth checking
     * - gasReimbursment
     * - callValue
     */
    function validateEndowment(uint endowment,
                               uint payment,
                               uint donation,
                               uint callGas,
                               uint callValue,
                               uint gasOverhead)
        view returns (bool)
    {
        // return true;
        Log(endowment);
        return endowment >= computeEndowment(payment,
                                             donation,
                                             callGas,
                                             callValue,
                                             gasOverhead);
    }
    event Log(uint num);
}