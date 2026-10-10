import { parseAbi } from "viem";

// Token Data
export const totalSupplyAbi = parseAbi(["function totalSupply() view returns (uint256)",]);
export const tokenBalanceOfAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
export const maxSupplyAbi = parseAbi(["function i_maxSupply() view returns (uint256)"]);

// Purchase Flow
export const pricePerTokenAbi = parseAbi(["function s_pricePerToken() view returns (uint256)"]);
export const minPurchaseAmountAbi = parseAbi(["function getMinPurchaseAmount() view returns (uint256)"]);
export const maxPurchasePerTxAbi = parseAbi(["function i_maxPurchasePerTx() view returns (uint256)"]);
export const usdcBalanceOfAbi = parseAbi(["function balanceOf(address) view returns (uint256)"]);
export const allowanceAbi = parseAbi(["function allowance(address, address) view returns (uint256)"]);
export const approveAbi = parseAbi(["function approve(address, uint256) returns (bool)"]);
export const purchaseAbi = parseAbi(["function purchase(uint256)"]);

// Compliance
export const isWhitelistedAbi = parseAbi(["function isWhitelisted(address) view returns (bool)"]);

// Dividends
export const roundCountAbi = parseAbi(["function getRoundCount() view returns (uint256)"]);
export const roundAbi = parseAbi(["function rounds(uint256) view returns (uint256 snapshotBlock, uint256 totalAmount, uint256 totalSupplyAtSnapshot)"]);
export const claimedAbi = parseAbi(["function claimed(address account, uint256 roundId) view returns (bool)"]);
export const totalRevenueAbi = parseAbi(["function getTotalRevenue() view returns (uint256)"]);
export const claimAbi = parseAbi(["function claim(uint256 roundId)"]);
