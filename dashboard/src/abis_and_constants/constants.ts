/**
 * Deployed contract addresses on Sepolia (chain id 11155111).
 * Decimals: PropertyToken uses 18, the stablecoin (USDC) uses 6. Mixing them
 * up compiles fine and silently gives values off by 10^12.
 */

export const TOKEN_ADDRESS = "0x4601DCB38c0480A530bdCa0B1D6012195b1DCb4d" as const;
export const ISSUANCE_ADDRESS = "0xFeCBDaaF623F685C5e4CC3337261Ea863bD7454C" as const;
export const VAULT_ADDRESS = "0x131fe84284456942EAC9dDBF838f68Ea722cCDB6" as const;
export const DISTRIBUTOR_ADDRESS = "0xe70fa8CF053d1dA9c94f374fe532A05e4cb72620" as const;
export const VALIDATOR_ADDRESS = "0xcAB07a5F798Fe39d91B3Dca8fcf93B5575880943" as const;
export const STABLECOIN_ADDRESS = "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238" as const;
