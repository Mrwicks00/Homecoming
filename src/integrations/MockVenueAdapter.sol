// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPrivateVenueAdapter} from "./IPrivateVenueAdapter.sol";

/// ============================================================================================
/// MOCK — NOT A REAL VENUE. Test/demo use only. See FEASIBILITY.md and README.md.
///
/// This contract genuinely holds token reserves and genuinely transfers real (test) tokens when
/// called — its settlement is real, on-chain, and verifiable by balance. What is mocked is only
/// the counterparty itself: no such venue exists in reality that can settle CoW-Protocol-eligible
/// or Flashbots-Protect-eligible flow synchronously inside a v4 swap (FEASIBILITY.md §1/§2). This
/// contract exists to prove HomecomingHook's routing/comparison/recapture logic is mechanically
/// correct end-to-end, deterministically, without depending on real off-chain solver behavior.
///
/// It must never be deployed as "the venue" on a production Homecoming Core deployment, and the
/// live Unichain Sepolia deployment does not configure it as the active adapter for real traffic.
/// ============================================================================================
contract MockVenueAdapter is IPrivateVenueAdapter {
    address public immutable owner;

    /// @dev Improvement bps applied on top of a caller-supplied AMM reference, per configured pair.
    /// e.g. 50 = adapter fills 0.50% better than the AMM reference it's given via venueData.
    mapping(bytes32 => int256) public improvementBpsOverride;
    mapping(bytes32 => bool) public pairEnabled;

    error NotOwner();
    error PairNotConfigured();
    error InsufficientReserves();

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function _pairKey(Currency tokenIn, Currency tokenOut) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenIn, tokenOut));
    }

    /// @notice Test/demo configuration: enable a pair and set how far above/below the AMM reference
    /// (passed in venueData at call time) this mock should fill. Negative = deliberately worse than
    /// AMM, to exercise the fallback/no-payout path.
    function configure(Currency tokenIn, Currency tokenOut, bool enabled, int256 improvementBps) external onlyOwner {
        bytes32 key = _pairKey(tokenIn, tokenOut);
        pairEnabled[key] = enabled;
        improvementBpsOverride[key] = improvementBps;
    }

    function fundReserves(Currency token, uint256 amount) external {
        IERC20Minimal(Currency.unwrap(token)).transferFrom(msg.sender, address(this), amount);
    }

    function isAvailable(Currency tokenIn, Currency tokenOut) external view override returns (bool) {
        return pairEnabled[_pairKey(tokenIn, tokenOut)];
    }

    /// @dev venueData must encode the caller's AMM reference amountOut (uint256), so the mock can
    /// compute a deterministic fill relative to it. The mock never receives or trusts a "claimed
    /// improvement" from outside — it derives its own fill purely from its own configuration.
    function trySettle(
        Currency tokenIn,
        Currency tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient,
        bytes calldata venueData
    ) external override returns (bool success, uint256 amountOutClaimed) {
        bytes32 key = _pairKey(tokenIn, tokenOut);
        if (!pairEnabled[key]) revert PairNotConfigured();

        uint256 ammReference = abi.decode(venueData, (uint256));
        int256 bps = improvementBpsOverride[key];

        int256 signedAmountOut = int256(ammReference) + (int256(ammReference) * bps) / 10_000;
        amountOutClaimed = signedAmountOut > 0 ? uint256(signedAmountOut) : 0;

        if (amountOutClaimed < minAmountOut) {
            return (false, amountOutClaimed);
        }

        address outToken = Currency.unwrap(tokenOut);
        if (IERC20Minimal(outToken).balanceOf(address(this)) < amountOutClaimed) {
            revert InsufficientReserves();
        }

        // amountIn was already transferred to this adapter by the caller before this call.
        require(IERC20Minimal(Currency.unwrap(tokenIn)).balanceOf(address(this)) >= amountIn, "no input received");

        bool ok = IERC20Minimal(outToken).transfer(recipient, amountOutClaimed);
        success = ok;
    }
}
