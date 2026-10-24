import { type Address, isAddress, formatUnits } from "viem";
import { client, ISSUANCE_ADDRESS, STABLECOIN_ADDRESS, USER_ADDRESS } from "../abis_and_constants/constants.js";
import { pricePerTokenAbi, minPurchaseAmountAbi, maxPurchasePerTxAbi, usdcBalanceOfAbi, allowanceAbi } from "../abis_and_constants/abis.js";

async function readPurchaseFlow(userAddress: Address) {
    const [
        pricePerToken,
        minPurchaseAmount,
        maxPurchasePerTx,
        usdcBalanceOf,
        allowance] = await client.multicall({
            contracts: [
                {
                    address: ISSUANCE_ADDRESS,
                    abi: pricePerTokenAbi,
                    functionName: "s_pricePerToken"
                },
                {
                    address: ISSUANCE_ADDRESS,
                    abi: minPurchaseAmountAbi,
                    functionName: "getMinPurchaseAmount"
                },
                {
                    address: ISSUANCE_ADDRESS,
                    abi: maxPurchasePerTxAbi,
                    functionName: "i_maxPurchasePerTx"
                },
                {
                    address: STABLECOIN_ADDRESS,
                    abi: usdcBalanceOfAbi,
                    functionName: "balanceOf",
                    args: [userAddress]
                },
                {
                    address: STABLECOIN_ADDRESS,
                    abi: allowanceAbi,
                    functionName: "allowance",
                    args: [userAddress, ISSUANCE_ADDRESS]
                },
            ],
            allowFailure: false,
        });

    console.log("Current price per token:", formatUnits(pricePerToken, 6), "USDC");
    console.log("Min purchase amount:", formatUnits(minPurchaseAmount, 18), "tokens");
    console.log("Max purchase per transaction:", formatUnits(maxPurchasePerTx, 18), "tokens");
    console.log(`Balance of ${userAddress}:`, formatUnits(usdcBalanceOf, 6), "USDC");
    console.log(`Allowance of ${userAddress} for ${ISSUANCE_ADDRESS}:`, formatUnits(allowance, 6), "USDC");
}

const [, , rawAddress] = process.argv;

if (!rawAddress || !isAddress(rawAddress)) {
    console.error("Usage: npx tsx src/readers/purchaseFlow.ts <address>");
    process.exit(1); // exits with a failure code
}

const userAddress = rawAddress as Address;


readPurchaseFlow(userAddress);
