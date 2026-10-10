import { createPublicClient, http } from "viem";
import { sepolia } from "viem/chains";

export const publicClient = createPublicClient({
    chain: sepolia,
    transport: http(import.meta.env.VITE_SEPOLIA_RPC_URL),
});
