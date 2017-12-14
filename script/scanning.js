const { GTE_HEX, NULL_ADDRESS} = require('./constants.js')
const { TxRequest } = require('./txRequest.js')

/// Utility function to store txRequest addresses in cache.
const store = (cache, txRequest) => {
    if (cache.has(txRequest.address)) {
        cache.log.cache(`already has ${txRequest.address}`)
        return
    }
    cache.set(txRequest.address, txRequest.getWindowStart())
}

const clear = (cache, nextRequestAddr, left) => {
    /// this line prevents accessing too early
    if (cache.mem.indexOf(nextRequestAddr) == -1) return 
    /// Expired or successfully executed - FIXME - hardcoded at `left - 10`
    if (cache.get(nextRequestAddr) > 0 && cache.get(nextRequestAddr) < left -10) {
        cache.del(nextRequestAddr)
    }
}

/// Scans for new requests and stores them.
const scanToStore = async conf => {
    const log = conf.logger
    const left = await conf.web3.eth.getBlockNumber() - 10
    const right = left + 300

    const tracker = conf.tracker 
    const factory = conf.factory 

    log.debug(`Scanning tracker @ ${tracker.options.address}`)
    log.debug(`Validating tracker results with factory @ ${factory.options.address}`)
    log.debug(`Scanning from ${left} to ${right}`)

    let nextRequestAddr = await tracker.methods.query(
        factory.options.address,
        GTE_HEX,
        left,
    ).call()

    if (nextRequestAddr === NULL_ADDRESS) {
        log.info('No new requests')
        return
    }

    log.debug(`Initial tracker result: ${nextRequestAddr}`)

    while (nextRequestAddr !== NULL_ADDRESS) {
        clear(conf.cache, nextRequestAddr, left)

        log.debug(`Found request @ ${nextRequestAddr}`)
        if (!await factory.methods.isKnownRequest(nextRequestAddr).call()) {
            log.error(`Encountered unknown request: factory: ${factory.options.address} | query: ">=" | value ${left} | address: ${nextRequestAddr}`)
            throw new Error(`Encountered unknown address. ${nextRequestAddr}`)
        }
        let trackerWindowStart = await tracker.methods.getWindowStart(
            factory.options.address,
            nextRequestAddr,
        ).call() 

        const txRequest = new TxRequest(nextRequestAddr, conf.web3)
        await txRequest.fillData()

        if (txRequest.getWindowStart() !== parseInt(trackerWindowStart)) {
            log.error(`window starts do not match: got ${txRequest.getWindowStart()} from txRequest and ${parseInt(trackerWindowStart)} from tracker`)
        }
        if (txRequest.getWindowStart() <= right) {
            log.debug(`Found request @ ${txRequest.address} - window start: ${txRequest.getWindowStart()} `)
            
            /// Stores the txRequest
            store(conf.cache, txRequest)
        } else {
            log.debug(`Scan exit condition: window start ${txRequest.getWindowStart()} > right boundary: ${right}`)
            break
        }

        nextRequestAddr = await tracker.methods.getNextRequest(
            factory.options.address,
            txRequest.address
        ).call()
    }
    return true
}

const { executeTxRequest } = require('./handlers.js')
const filter = require('async').filter

/// Scans the cache and executes any ripe transaction requests.
const scanToExecute = async conf => {

    if (conf.cache.len() === 0) {
        return 
    }

    //Gets all the txRequestAddrs stored in cache
    const one = conf.cache.stored()
    .map((txRequestAddr) => {
        return new TxRequest(txRequestAddr, conf.web3)
    })

    filter(one, async (txRequest) => {
        await txRequest.fillData()
        return await txRequest.inExecutionWindow()
    }, (err, res) => {
        if (err) throw new Error(err)
        res.map((txRequest) => {
            if (conf.cache.get(txRequest.address) > 101) {
                executeTxRequest(conf, txRequest)
                .catch((err) => {
                    conf.logger.error(err)
                })
            }
        })
    })
}

module.exports.scanToExecute = scanToExecute
module.exports.scanToStore = scanToStore