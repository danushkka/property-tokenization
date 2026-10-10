import { useState, useEffect } from "react";
import { createWalletClient, custom, parseUnits, formatUnits, type Address } from "viem";
import { sepolia } from "viem/chains";

import { publicClient } from "./abis_and_constants/publicClient";
import {
    pricePerTokenAbi, allowanceAbi, approveAbi, purchaseAbi,
    maxPurchasePerTxAbi, minPurchaseAmountAbi,
} from "./abis_and_constants/abis";
import { ISSUANCE_ADDRESS, STABLECOIN_ADDRESS } from "./abis_and_constants/constants";

/**
 * Parses a human-entered token amount (e.g. "2.5") into its 18-decimal
 * on-chain representation. Returns null for invalid or non-positive input.
 */
function parseTokenAmount(input: string): bigint | null {
    try {
        const value = parseUnits(input, 18);
        return value > 0n ? value : null;
    } catch {
        return null; // not a valid decimal number
    }
}

export function PurchaseTokens({
    userAddress,
    onPurchaseComplete,
}: {
    userAddress: Address;
    onPurchaseComplete?: () => void; // refreshes the page after purchase completed in `WalletConnect.tsx`
}) {
    const [amountInput, setAmountInput] = useState("5");
    const [price, setPrice] = useState<bigint | null>(null);
    const [allowance, setAllowance] = useState<bigint | null>(null);
    const [maxPerTx, setMaxPerTx] = useState<bigint | null>(null);
    const [minAmount, setMinAmount] = useState<bigint | null>(null);
    const [pending, setPending] = useState(false);

    async function loadData() {
        const [currentPrice, currentAllowance, currentMax, currentMin] = await publicClient.multicall({
            contracts: [
                { address: ISSUANCE_ADDRESS, abi: pricePerTokenAbi, functionName: "s_pricePerToken" },
                { address: STABLECOIN_ADDRESS, abi: allowanceAbi, functionName: "allowance", args: [userAddress, ISSUANCE_ADDRESS] },
                { address: ISSUANCE_ADDRESS, abi: maxPurchasePerTxAbi, functionName: "i_maxPurchasePerTx" },
                { address: ISSUANCE_ADDRESS, abi: minPurchaseAmountAbi, functionName: "getMinPurchaseAmount" },
            ],
            allowFailure: false,
        });
        setPrice(currentPrice);
        setAllowance(currentAllowance);
        setMaxPerTx(currentMax);
        setMinAmount(currentMin);
    }

    useEffect(() => {
        loadData();
    }, [userAddress]);

    // All hooks are above this line. Hooks can't come after an early return.
    if (price === null || allowance === null || maxPerTx === null || minAmount === null) {
        return <p>Loading...</p>;
    }

    const amount = parseTokenAmount(amountInput);
    const cost = amount !== null ? (amount * price) / 10n ** 18n : null;

    let error: string | null = null;
    if (amount === null) error = "Enter a valid amount";
    else if (amount < minAmount) error = `Minimum purchase is ${formatUnits(minAmount, 18)} tokens`;
    else if (amount > maxPerTx) error = `Maximum per transaction is ${formatUnits(maxPerTx, 18)} tokens`;

    const hasAllowance = cost !== null && allowance >= cost;

    function getWalletClient() {
        return createWalletClient({ chain: sepolia, transport: custom((window as any).ethereum) });
    }

    async function handleApprove() {
        if (cost === null || error) return;
        setPending(true);
        try {
            const hash = await getWalletClient().writeContract({
                account: userAddress,
                address: STABLECOIN_ADDRESS,
                abi: approveAbi,
                functionName: "approve",
                args: [ISSUANCE_ADDRESS, cost],
            });
            await publicClient.waitForTransactionReceipt({ hash });
            await loadData();
        } finally {
            setPending(false);
        }
    }

    async function handlePurchase() {
        if (amount === null || error) return;
        setPending(true);
        try {
            const hash = await getWalletClient().writeContract({
                account: userAddress,
                address: ISSUANCE_ADDRESS,
                abi: purchaseAbi,
                functionName: "purchase",
                args: [amount],
            });
            await publicClient.waitForTransactionReceipt({ hash });
            await loadData();
            onPurchaseComplete?.();
            alert(`Purchase complete: ${formatUnits(amount, 18)} tokens`);
        } finally {
            setPending(false);
        }
    }

    return (
        <div>
            <h3>Purchase info</h3>
            <p>Price: {formatUnits(price, 6)} USDC per token</p>
            <label>
                Tokens to buy:{" "}
                <input
                    type="text"
                    inputMode="decimal"
                    value={amountInput}
                    onChange={(e) => setAmountInput(e.target.value)}
                />
            </label>
            {error ? (
                <p>{error}</p>
            ) : (
                <p>Cost: {formatUnits(cost!, 6)} USDC</p>
            )}
            {hasAllowance ? (
                <button disabled={pending || error !== null} onClick={handlePurchase}>
                    {pending ? "Confirming..." : "Buy"}
                </button>
            ) : (
                <button disabled={pending || error !== null} onClick={handleApprove}>
                    {pending ? "Confirming..." : "Approve USDC"}
                </button>
            )}
        </div>
    );
}
