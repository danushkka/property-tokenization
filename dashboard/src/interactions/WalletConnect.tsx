import { useState, useEffect } from "react";
import { createWalletClient, custom, formatUnits, type Address } from "viem";
import { sepolia } from "viem/chains";

import { publicClient } from "../abis_and_constants/publicClient";
import { TOKEN_ADDRESS, VALIDATOR_ADDRESS } from "../abis_and_constants/constants";
import { tokenBalanceOfAbi, isWhitelistedAbi } from "../abis_and_constants/abis";
import { PurchaseTokens } from "../interactions/PurchaseTokens";
import { ClaimDividends } from "../interactions/ClaimDividends";

/**
 * Fetches an `account`'s token balance and whitelisted status
 * by calling related functions on deployed addresses.
 * 
 * @param account An account to fetch data from.
 * @returns Account's token balance and whitelisted status.
 */
async function fetchWalletData(account: Address) {
    const [balance, whitelisted] = await publicClient.multicall({
        contracts: [
            { address: TOKEN_ADDRESS, abi: tokenBalanceOfAbi, functionName: "balanceOf", args: [account] },
            { address: VALIDATOR_ADDRESS, abi: isWhitelistedAbi, functionName: "isWhitelisted", args: [account] },
        ],
        allowFailure: false,
    });
    return { balance: formatUnits(balance, 18), whitelisted };
}

export function WalletConnect() {
    const [address, setAddress] = useState<Address | null>(null);
    const [chainId, setChainId] = useState<number | null>(null);
    const [balance, setBalance] = useState<string | null>(null);
    const [isWhitelisted, setIsWhitelisted] = useState<boolean | null>(null);
    const [error, setError] = useState<string | null>(null);

    // 1) Restore any existing connection and subscribe to wallet events
    useEffect(() => {
        const ethereum = window.ethereum;
        if (!ethereum) return;

        const walletClient = createWalletClient({ chain: sepolia, transport: custom(ethereum) });

        // getAddresses() reads already-authorized accounts
        walletClient.getAddresses().then((accounts) => setAddress(accounts[0] ?? null));
        walletClient.getChainId().then(setChainId);

        function handleAccountsChanged(accounts: Address[]) {
            setAddress(accounts[0] ?? null); // empty array => wallet locked or disconnected
        }
        function handleChainChanged(chainIdHex: string) {
            setChainId(Number(chainIdHex)); // MetaMask sends hex, e.g. "0xaa36a7"
        }

        ethereum.on("accountsChanged", handleAccountsChanged);
        ethereum.on("chainChanged", handleChainChanged);

        return () => {
            ethereum.removeListener("accountsChanged", handleAccountsChanged);
            ethereum.removeListener("chainChanged", handleChainChanged);
        };
    }, []);

    // 2) Load this wallet's data whenever the account changes
    useEffect(() => {
        if (!address) return;

        let cancelled = false;
        setBalance(null);
        setIsWhitelisted(null);

        fetchWalletData(address).then((data) => {
            if (cancelled) return; // account changed again before this finished
            setBalance(data.balance);
            setIsWhitelisted(data.whitelisted);
        });

        return () => {
            cancelled = true;
        };
    }, [address]);

    async function refresh() {
        if (!address) return;
        const data = await fetchWalletData(address);
        setBalance(data.balance);
        setIsWhitelisted(data.whitelisted);
    }

    async function connect() {
        const ethereum = window.ethereum;
        if (!ethereum) return;
        setError(null);
        try {
            const walletClient = createWalletClient({ chain: sepolia, transport: custom(ethereum) });
            const [account] = await walletClient.requestAddresses();
            setAddress(account ?? null);
        } catch {
            setError("Wallet connection failed or was rejected.");
        }
    }

    async function switchToSepolia() {
        const ethereum = window.ethereum;
        if (!ethereum) return;
        setError(null);
        try {
            const walletClient = createWalletClient({ chain: sepolia, transport: custom(ethereum) });
            await walletClient.switchChain({ id: sepolia.id });
        } catch {
            setError("Could not switch network. Please switch to Sepolia manually in MetaMask.");
        }
    }

    // All hooks are above this line. Hooks can't come after an early return.
    if (!window.ethereum) {
        return <p>MetaMask not detected. Please install it to use this dashboard.</p>;
    }

    if (!address) {
        return (
            <div>
                <button onClick={connect}>Connect Wallet</button>
                {error && <p>{error}</p>}
            </div>
        );
    }

    if (chainId !== null && chainId !== sepolia.id) {
        return (
            <div>
                <p>Wrong network. This dashboard runs on Sepolia.</p>
                <button onClick={switchToSepolia}>Switch to Sepolia</button>
                {error && <p>{error}</p>}
            </div>
        );
    }

    return (
        <div>
            <h3>Wallet info</h3>
            <p>Connected: {address}</p>
            <p>Balance: {balance ?? "loading..."}</p>
            <p>Whitelisted: {isWhitelisted === null ? "loading..." : isWhitelisted ? "Yes" : "No"}</p>
            <PurchaseTokens userAddress={address} onPurchaseComplete={refresh} />
            <ClaimDividends userAddress={address} />
        </div>
    );
}