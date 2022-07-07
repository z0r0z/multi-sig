// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.4;

/// @dev Interfaces
import {IERC20Balances} from "../../interfaces/IERC20Balances.sol";
import {IKaliClub} from "../../interfaces/IKaliClub.sol";

/// @dev Libraries
import {FixedPointMathLib} from "../../libraries/FixedPointMathLib.sol";
import {SafeTransferLib} from "../../libraries/SafeTransferLib.sol";

/// @dev Contracts
import {Multicall} from "../../utils/Multicall.sol";

/// @title Kali Club Redemption
/// @notice Fair share redemptions for burnt Kali Club tokens
contract KaliClubRedemption is Multicall {
    /// -----------------------------------------------------------------------
    /// LIBRARY USAGE
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for uint256;

    using SafeTransferLib for address;

    /// -----------------------------------------------------------------------
    /// EVENTS
    /// -----------------------------------------------------------------------

    event RedemptionStartSet(
        address indexed club, 
        uint256 id, 
        uint256 redemptionStart
    );

    event Redeemed(
        address indexed redeemer, 
        address indexed club, 
        address[] assets, 
        uint256 id, 
        uint256 redemption
    );

    /// -----------------------------------------------------------------------
    /// ERRORS
    /// -----------------------------------------------------------------------

    error NOT_STARTED();

    error INVALID_ASSET_ORDER();

    /// -----------------------------------------------------------------------
    /// STORAGE
    /// -----------------------------------------------------------------------

    mapping(address => mapping(uint256 => uint256)) public redemptionStarts;

    /// -----------------------------------------------------------------------
    /// CONFIGURATIONS
    /// -----------------------------------------------------------------------
    
    /// @notice Redemption configuration for clubs
    /// @param id The token ID to set redemption configuration for
    /// @param redemptionStart The unix timestamp at which redemption starts
    function setRedemptionStart(uint256 id, uint256 redemptionStart) external payable {
        assembly {
            if iszero(redemptionStart) {
                revert(0, 0)
            }
        }
        
        redemptionStarts[msg.sender][id] = redemptionStart;
        
        emit RedemptionStartSet(msg.sender, id, redemptionStart);
    }

    /// -----------------------------------------------------------------------
    /// REDEMPTIONS
    /// -----------------------------------------------------------------------
    
    /// @notice Redemption option for club members
    /// @param club Club contract address
    /// @param assets Array of assets to redeem out
    /// @param id The token ID to burn from
    /// @param redemption Amount of token ID to burn
    function redeem(
        address club, 
        address[] calldata assets, 
        uint256 id,
        uint256 burnAmount
    )
        external
        payable
    {
        uint256 start = redemptionStarts[club][id];
        
        if (start == 0 || block.timestamp < start) revert NOT_STARTED();

        uint256 supply = IKaliClub(club).totalSupply(id);

        IKaliClub(club).burn(
            msg.sender, 
            id,
            redemption
        );
        
        address prevAddr;

        for (uint256 i; i < assets.length; ) {
            // prevent null and duplicate assets
            if (prevAddr >= assets[i]) revert INVALID_ASSET_ORDER();

            prevAddr = assets[i];

            // calculate fair share of given assets for redemption
            uint256 amountToRedeem = FixedPointMathLib._mulDivDown(
                redemption,
                IERC20Balances(assets[i]).balanceOf(club),
                supply
            );

            // transfer from club to redeemer
            if (amountToRedeem != 0) 
                assets[i]._safeTransferFrom(
                    club, 
                    msg.sender, 
                    amountToRedeem
                );

            // an array can't have a total length
            // larger than the max uint256 value
            unchecked {
                ++i;
            }
        }
        
        emit Redeemed(msg.sender, club, assets, id, redemption);
    }
}
