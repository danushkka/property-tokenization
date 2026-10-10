import { type Address, isAddress, formatUnits } from "viem";
import { client, DISTRIBUTOR_ADDRESS, VAULT_ADDRESS, USER_ADDRESS } from "../abis_and_constants/constants.js";
import { roundCountAbi, roundAbi, claimedAbi, totalRevenueAbi } from "../abis_and_constants/abis.js";

async function readDividends(userAddress: Address, roundId: bigint) {
    const [roundCount, round, claimed, totalRevenue] = await client.multicall({
        contracts: [
            {
                address: DISTRIBUTOR_ADDRESS,
                abi: roundCountAbi,
                functionName: "getRoundCount"
            },
            {
                address: DISTRIBUTOR_ADDRESS,
                abi: roundAbi,
                functionName: "rounds",
                args: [roundId]
            },
            {
                address: DISTRIBUTOR_ADDRESS,
                abi: claimedAbi,
                functionName: "claimed",
                args: [userAddress, roundId]
            },
            {
                address: VAULT_ADDRESS,
                abi: totalRevenueAbi,
                functionName: "getTotalRevenue"
            }
        ],
        allowFailure: false,
    });

    console.log("Declared rounds:", roundCount.toString());

    console.log(`Round ${roundId}:`);
    console.log("  Snapshot block:", round[0].toString());
    console.log("  Dividend amount:", formatUnits(round[1], 6), "USDC");
    console.log("  Supply at snapshot:", formatUnits(round[2], 18), "tokens");

    console.log(`Claimed by ${userAddress} for round ${roundId}:`, claimed);
    console.log("Vault total revenue:", formatUnits(totalRevenue, 6), "USDC");
}

const [, , rawAddress, rawRoundId] = process.argv;

if (!rawAddress || !isAddress(rawAddress)) {
    console.error("Usage: npx tsx src/readers/dividends.ts <address> <roundId>");
    process.exit(1); // exits with a failure code
}

const userAddress = rawAddress as Address;
const roundId = BigInt(rawRoundId ?? "0"); // default to 0 if not provided


readDividends(userAddress, roundId);
