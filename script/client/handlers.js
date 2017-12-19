const { ABORTEDLOG, EXECUTEDLOG } = require('../constants.js')

/// Sends the exeuction request from web3 default account.
const fromDefault = (conf, txRequest, gasLimit, gasPrice) => {
    const web3 = conf.web3 
    const log = conf.logger 

    log.info('executing from default')

    const executeTx = txRequest.instance.methods.execute().send({
        from: web3.eth.defaultAccount,
        gas: gasLimit - 12000,
        gasPrice: gasPrice
    })

    executeTx.then((res) => {
        if (res.events[0].raw.topics[0] == ABORTEDLOG) {
            // console.log('aborted')
            conf.cache.del(txRequest.address)
        }

        if (res.events[0].raw.topics[0] == EXECUTEDLOG) {
            // console.log('executed')
            conf.cache.set(txRequest.address, 100)
        }
        log.info(`success. tx hash: ${res.transactionHash}`)
    })
}

const executeTxRequest = async (conf, txRequest) => {
    const web3 = conf.web3 
    // const requestLib = conf.requestLib 
    const log = conf.logger

    await txRequest.fillData()
    if (txRequest.wasCalled()) {
        log.debug('already called')
        conf.cache.set(txRequest.address, -1)
        return
    }
    if (txRequest.isCancelled()) {
        log.debug('cancelled')
        return 
    }
    if (!await txRequest.inExecutionWindow()) {
        log.debug('outside execution window')
        return 
    }
    // if (await txRequest.inReservedWindow() && (txRequest.isClaimedBy(web3.eth.defaultAccount)) {
    //     log.debug(`In reserved window and claimed by ${txRequest.claimedBy()}`)
    //     log.debug(txRequest.isClaimedBy(web3.eth.defaultAccount))
    //     return 
    // }

    const executeGas = txRequest.callGas() + 180000//+ await requestLib.EXECUTION_GAS_OVERHEAD().call()
    const gasLimit = (await web3.eth.getBlock('latest')).gasLimit

    /// TODO pull out the gasPrice... rn it's hard coded
    const gasPrice = web3.utils.toWei('100', 'gwei')

    if (executeGas > gasLimit) {
        log.error(`Execution gas above network gas limit.`)
        return 
    }

    /// Start execution attempt

    log.info(`Attempting execution...`)
    conf.cache.set(txRequest.address, -1)

    if (txRequest.isClaimedBy(web3.eth.defaultAccount)) {
        /// If it's claimed by default, send from default.
        fromDefault(conf, txRequest, gasLimit, gasPrice)

    } else if (conf.wallet) {
        /// If not claimed by default and wallet is enabled send from a child account.
        log.info('sending from next nonce in wallet')
        const executeTxData = txRequest.instance.methods.execute().encodeABI()
        conf.wallet.sendFromNext(
            txRequest.address,
            0,
            gasLimit - 12000,
            gasPrice,
            executeTxData
        )
        .then(res => console.log(res.transactionHash))

    } else {
        /// Otherwise send from default.
        fromDefault(conf, txRequest, gasLimit, gasPrice)
    }
}

const executeTxRequestFrom = async (conf, txRequest, index) => {
    /// Perform checks
    /// ...
    ///
    log.info(`Attempting execution...`)
    conf.cache.set(txRequest.address, -1)

    const gasLimit = (await web3.eth.getBlock('latest')).gasLimit

    const executeTxData = txRequest.instance.methods.execute().encodeABI()
    conf.wallet.sendFromIndex(
        index,
        txRequest.address, 
        0,
        gasLimit - 12000,
        gasPrice,
        executeTxData
    )
    .then(res => {
        if (res.events[0].raw.topics[0] == ABORTEDLOG) {
            // console.log('aborted')
            conf.cache.del(txRequest.address)
        }

        if (res.events[0].raw.topics[0] == EXECUTEDLOG) {
            // console.log('executed')
            conf.cache.set(txRequest.address, 100)
        }
        log.info(`success. tx hash: ${res.transactionHash}`)
    })
}

/// WIP
const claimTxRequest = async (conf, txRequest) => {
    const log = conf.logger 
    const web3 = conf.web3

    await txRequest.fillData()
    if (txRequest.isCancelled()) {
        log.debug(`failed to claim cancelled request at address ${txRequest.address}`)
        return
    }
    if (!txRequest.inClaimWindow()) {
        log.debug(`failed to claim request at address ${txRequest.address} due to out of claim window`)
        return
    }
    if (txRequest.isClaimed()) {
        log.debug(`failed to claim already claimed request at address ${txRequest.address}`)
        return 
    }

    const claimDeposit = 2 * txRequest.data.paymentData.payment
    const gasToClaim = txRequest.instance.methods.claim().estimateGas({from: web3.eth.defaultAccount})
    const gasCostToClaim = parseInt(await web3.eth.getGasPrice) * gasToClaim 

    if (gasCostToClaim > paymentIfClaimed) {
        log.debug(`Not claiming. Claim gas cost is higher than the calculated payment. Claim Gas Cost: ${gasCostToClaim} | Current Payment: ${paymentIfClaimed}`)
        return 
    }
}

module.exports.executeTxRequest = executeTxRequest
module.exports.executeTxRequestFrom = executeTxRequestFrom

// const reason = [
//     'WasCancelled',         //0
//     'AlreadyCalled',        //1
//     'BeforeCallWindow',     //2
//     'AfterCallWindow',      //3
//     'ReservedForClaimer',   //4
//     'InsufficientGas'       //5
// ]