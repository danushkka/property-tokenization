/**
 * Deployed contract addresses on Sepolia (chain id 11155111).
 * Decimals: PropertyToken uses 18, the stablecoin (USDC) uses 6. Mixing them
 * up compiles fine and silently gives values off by 10^12.
 */

export const TOKEN_ADDRESS = "0x710559A196549934c67C4f7fa8917FE64C87B55F" as const;
export const ISSUANCE_ADDRESS = "0x9779dDB22f8c621B408556aaAaf5816F31a15Df2" as const;
export const VAULT_ADDRESS = "0x60ff418bD533c447dDD9247d05577797F5F7e5a4" as const;
export const DISTRIBUTOR_ADDRESS = "0xC32dD5de57e0DaE62F2D20BbEEfB4927BD82A476" as const;
export const VALIDATOR_ADDRESS = "0x7d3342950f772388F33D0789660aD0B6Aa731baD" as const;
export const STABLECOIN_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as const;
