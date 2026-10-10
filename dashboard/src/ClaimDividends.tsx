import { useEffect, useState } from "react";
import { createWalletClient, custom, formatUnits, type Address } from "viem";
import { sepolia } from "viem/chains";

import { publicClient } from "./abis_and_constants/publicClient";
import { claimAbi, claimedAbi, roundAbi, roundCountAbi } from "./abis_and_constants/abis";
import { DISTRIBUTOR_ADDRESS } from "./abis_and_constants/constants";

type RoundInfo = {
    id: bigint;
    totalAmount: bigint;
    claimed: boolean;
};

export function ClaimDividends({ userAddress }: { userAddress: Address }) {
    const [rounds, setRounds] = useState<RoundInfo[]>([]);
    const [loading, setLoading] = useState(true);
    const [pendingRound, setPendingRound] = useState<bigint | null>(null);

    async function loadData() {
        const roundCount = await publicClient.readContract({
            address: DISTRIBUTOR_ADDRESS,
            abi: roundCountAbi,
            functionName: "getRoundCount"
        });

        const roundIds = Array.from({ length: Number(roundCount) }, (_, i) => BigInt(i));

        const calls = roundIds.flatMap((id) => [
            { address: DISTRIBUTOR_ADDRESS, abi: roundAbi, functionName: "rounds", args: [id] },
            { address: DISTRIBUTOR_ADDRESS, abi: claimedAbi, functionName: "claimed", args: [userAddress, id] },
        ]);

        const result = await publicClient.multicall({ contracts: calls, allowFailure: false });

        const parsed: RoundInfo[] = roundIds.map((id, i) => {
            // `i * 2` is used due to the "double output" in `result` to properly access values:
            // snapshotBlock, totalAmount, totalSupply
            const [, totalAmount,] = result[i * 2] as [bigint, bigint, bigint];
            const claimed = result[i * 2 + 1] as boolean;
            return { id: id, totalAmount: totalAmount, claimed: claimed };
        });

        setRounds(parsed);
        setLoading(false);
    }

    useEffect(() => {
        loadData();
    }, [userAddress]);

    async function handleClaim(roundId: bigint) {
        setPendingRound(roundId);
        try {
            const walletClient = createWalletClient({ chain: sepolia, transport: custom((window as any).ethereum), });

            const hash = await walletClient.writeContract({
                account: userAddress,
                address: DISTRIBUTOR_ADDRESS,
                abi: claimAbi,
                functionName: "claim",
                args: [roundId],
            });

            await publicClient.waitForTransactionReceipt({ hash });
            await loadData(); // refresh `id`

        } finally {
            setPendingRound(null);
        }
    }

    if (loading) return <p>Loading rounds...</p>

    return (
        <div>
            <h3>Dividend rounds</h3>
            {rounds.map((round) => (
                <div key={round.id.toString()}>
                    <p>
                        Round {round.id.toString()}: {formatUnits(round.totalAmount, 6)} USDC total.
                    </p>
                    <p>
                        Status:{" "}
                        {round.claimed ? "claimed" : "unclaimed"}
                    </p>
                    {!round.claimed && (
                        <button disabled={pendingRound === round.id} onClick={() => handleClaim(round.id)}>
                            {pendingRound === round.id ? "Confirming..." : "Claim"}
                        </button>
                    )}
                </div>
            ))}
        </div>
    );
}