
const { getABI } = require('./util.js')
const BlockSchedulerABI = getABI('BlockScheduler')

/// Schedules a test transaction.
const main = async (chain, web3) => {

    const contracts = require(`../${chain}.json`)

    const me = (await web3.eth.getAccounts())[0]

    const windowStart = await web3.eth.getBlockNumber() + 12
    const gasPrice = web3.utils.toWei('100', 'gwei')

    const blockScheduler = new web3.eth.Contract(
        BlockSchedulerABI, 
        contracts.blockScheduler
    )

    await blockScheduler.methods.schedule(
        '0x009f7EfeD908c05df5101DA1557b7CaaB38EE4Ce',
        web3.utils.utf8ToHex('s0x'.repeat(
            Math.floor(Math.random() * 10)
        )),
        [
            1212121,    //callGas
            123454321,  //callValue
            255,        //windowSize
            windowStart,
            gasPrice,
            12,          //donation
            24           //payment

        ]
    ).send({
        from: me, 
        gas: 3000000, 
        value: web3.utils.toWei('500', 'finney'),
        gasPrice: gasPrice,
    })
    .then((tx) => {
        console.log(`Transaction mined! ${tx.transactionHash}`)
    })
    .catch(err => console.error(err))
}

module.exports = main