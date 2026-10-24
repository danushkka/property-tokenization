import { type Address, isAddress, formatUnits } from "viem";
import { client, TOKEN_ADDRESS, USER_ADDRESS } from "../abis_and_constants/constants.js";
import { totalSupplyAbi, maxSupplyAbi, tokenBalanceOfAbi } from "../abis_and_constants/abis.js";

async function readTokenData(userAddress: Address) {
    const [tokenBalanceOf, totalSupply, maxSupply] = await client.multicall({
        contracts: [
            {
                address: TOKEN_ADDRESS,
                abi: tokenBalanceOfAbi,
                functionName: "balanceOf",
                args: [userAddress]
            },
            {
                address: TOKEN_ADDRESS,
                abi: totalSupplyAbi,
                functionName: "totalSupply",
            },
            {
                address: TOKEN_ADDRESS,
                abi: maxSupplyAbi,
                functionName: "i_maxSupply"
            },
        ],
        allowFailure: false,
    });

    console.log(`Balance of ${userAddress}:`, formatUnits(tokenBalanceOf, 18), "tokens");
    console.log("Total supply:", formatUnits(totalSupply, 18), "tokens");
    console.log("Max supply:", formatUnits(maxSupply, 18), "tokens");
}

const [, , rawAddress] = process.argv;

if (!rawAddress || !isAddress(rawAddress)) {
    console.error("Usage: npx tsx src/readers/tokenData.ts <address>");
    process.exit(1); // exits with a failure code
}

const userAddress = rawAddress as Address;


readTokenData(userAddress);
