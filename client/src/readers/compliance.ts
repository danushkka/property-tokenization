import { type Address, isAddress } from "viem";
import { isWhitelistedAbi } from "../abis_and_constants/abis.js";
import { client, VALIDATOR_ADDRESS, USER_ADDRESS } from "../abis_and_constants/constants.js";

async function readCompliance(userAddress: Address) {
    const isWhitelisted = await client.readContract({
        address: VALIDATOR_ADDRESS,
        abi: isWhitelistedAbi,
        functionName: "isWhitelisted",
        args: [userAddress]
    });

    console.log(`Whitelisted status of ${userAddress}:`, isWhitelisted);
}

const [, , rawAddress] = process.argv;

if (!rawAddress || !isAddress(rawAddress)) {
    console.error("Usage: npx tsx src/readers/dividends.ts <address>");
    process.exit(1); // exits with a failure code
}

const userAddress = rawAddress as Address;


readCompliance(userAddress);
