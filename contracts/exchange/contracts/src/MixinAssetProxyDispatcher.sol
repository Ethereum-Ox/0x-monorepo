/*

  Copyright 2018 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.5;

import "@0x/contracts-utils/contracts/src/Ownable.sol";
import "./mixins/MAssetProxyDispatcher.sol";
import "./interfaces/IAssetProxy.sol";


contract MixinAssetProxyDispatcher is
    Ownable,
    MAssetProxyDispatcher
{
    // Mapping from Asset Proxy Id's to their respective Asset Proxy
    mapping (bytes4 => address) public assetProxies;

    /// @dev Registers an asset proxy to its asset proxy id.
    ///      Once an asset proxy is registered, it cannot be unregistered.
    /// @param assetProxy Address of new asset proxy to register.
    function registerAssetProxy(address assetProxy)
        external
        onlyOwner
    {
        // Ensure that no asset proxy exists with current id.
        bytes4 assetProxyId = IAssetProxy(assetProxy).getProxyId();
        address currentAssetProxy = assetProxies[assetProxyId];
        if (currentAssetProxy != address(0)) {
            rrevert(AssetProxyExistsError(currentAssetProxy));
        }

        // Add asset proxy and log registration.
        assetProxies[assetProxyId] = assetProxy;
        emit AssetProxyRegistered(
            assetProxyId,
            assetProxy
        );
    }

    /// @dev Gets an asset proxy.
    /// @param assetProxyId Id of the asset proxy.
    /// @return The asset proxy registered to assetProxyId. Returns 0x0 if no proxy is registered.
    function getAssetProxy(bytes4 assetProxyId)
        external
        view
        returns (address)
    {
        return assetProxies[assetProxyId];
    }

    /// @dev Forwards arguments to assetProxy and calls `transferFrom`. Either succeeds or throws.
    /// @param assetData Byte array encoded for the asset.
    /// @param from Address to transfer token from.
    /// @param to Address to transfer token to.
    /// @param amount Amount of token to transfer.
    /// @param orderHash Order hash, used for rich reverts.
    function dispatchTransferFrom(
        bytes memory assetData,
        address from,
        address to,
        uint256 amount,
        bytes32 orderHash
    )
        internal
    {
        // Do nothing if no amount should be transferred.
        if (amount > 0 && from != to) {
            // Ensure assetData length is valid
            if (assetData.length <= 3) {
                rrevert(AssetProxyDispatchError(AssetProxyDispatchErrorCodes.INVALID_ASSET_DATA_LENGTH));
            }

            require(
                assetData.length > 3,
                "LENGTH_GREATER_THAN_3_REQUIRED"
            );

            // Lookup assetProxy. We do not use `LibBytes.readBytes4` for gas efficiency reasons.
            bytes4 assetProxyId;
            assembly {
                assetProxyId := and(mload(
                    add(assetData, 32)),
                    0xFFFFFFFF00000000000000000000000000000000000000000000000000000000
                )
            }
            address assetProxy = assetProxies[assetProxyId];

            // Ensure that assetProxy exists
            if (assetProxy == address(0)) {
                rrevert(AssetProxyDispatchError(AssetProxyDispatchErrorCodes.UNKNOWN_ASSET_PROXY));
            }

            // Whether the AssetProxy transfer succeeded.
            bool didSucceed;
            // On failure, the revert message returned by the asset proxy.
            bytes revertMessage = new bytes(0);

            // We construct calldata for the `assetProxy.transferFrom` ABI.
            // The layout of this calldata is in the table below.
            //
            // | Area     | Offset | Length  | Contents                                    |
            // | -------- |--------|---------|-------------------------------------------- |
            // | Header   | 0      | 4       | function selector                           |
            // | Params   |        | 4 * 32  | function parameters:                        |
            // |          | 4      |         |   1. offset to assetData (*)                |
            // |          | 36     |         |   2. from                                   |
            // |          | 68     |         |   3. to                                     |
            // |          | 100    |         |   4. amount                                 |
            // | Data     |        |         | assetData:                                  |
            // |          | 132    | 32      | assetData Length                            |
            // |          | 164    | **      | assetData Contents                          |

            assembly {
                /////// Setup State ///////
                // `cdStart` is the start of the calldata for `assetProxy.transferFrom` (equal to free memory ptr).
                let cdStart := mload(64)
                // We reserve 256 bytes from `cdStart` because we'll reuse it later for return data.
                mstore(64, add(cdStart, 256))
                // `dataAreaLength` is the total number of words needed to store `assetData`
                //  As-per the ABI spec, this value is padded up to the nearest multiple of 32,
                //  and includes 32-bytes for length.
                let dataAreaLength := and(add(mload(assetData), 63), 0xFFFFFFFFFFFE0)
                // `cdEnd` is the end of the calldata for `assetProxy.transferFrom`.
                let cdEnd := add(cdStart, add(132, dataAreaLength))


                /////// Setup Header Area ///////
                // This area holds the 4-byte `transferFromSelector`.
                // bytes4(keccak256("transferFrom(bytes,address,address,uint256)")) = 0xa85e59e4
                mstore(cdStart, 0xa85e59e400000000000000000000000000000000000000000000000000000000)

                /////// Setup Params Area ///////
                // Each parameter is padded to 32-bytes. The entire Params Area is 128 bytes.
                // Notes:
                //   1. The offset to `assetData` is the length of the Params Area (128 bytes).
                //   2. A 20-byte mask is applied to addresses to zero-out the unused bytes.
                mstore(add(cdStart, 4), 128)
                mstore(add(cdStart, 36), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(cdStart, 68), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
                mstore(add(cdStart, 100), amount)

                /////// Setup Data Area ///////
                // This area holds `assetData`.
                let dataArea := add(cdStart, 132)
                // solhint-disable-next-line no-empty-blocks
                for {} lt(dataArea, cdEnd) {} {
                    mstore(dataArea, mload(assetData))
                    dataArea := add(dataArea, 32)
                    assetData := add(assetData, 32)
                }

                /////// Call `assetProxy.transferFrom` using the constructed calldata ///////
                didSucceed := call(
                    gas,                    // forward all gas
                    assetProxy,             // call address of asset proxy
                    0,                      // don't send any ETH
                    cdStart,                // pointer to start of input
                    sub(cdEnd, cdStart),    // length of input
                    cdStart,                // write output over input
                    256                     // reserve 256 bytes for output
                )

                if iszero(didSucceed) { // Call reverted.
                    // Attempt to to decode standard error messages with the
                    // signature `Error(string)` so we can upgrade them to
                    // a rich revert.

                    // Standard revert errors have the following memory layout:
                    // | Area            | Offset  | Length   | Contents                              |
                    // --------------------------------------------------------------------------------
                    // | Selector        | 0       | 4        | bytes4 function selector (0x08c379a0) |
                    // | Params          |         |          |                                       |
                    // |                 | 4       | 32       | uint256 offset to data (o)            |
                    // | Data            |         |          |                                       |
                    // |                 | 4 + o   | 32       | uint256 length of data (n             |
                    // |                 | 32 + o  | n        | Left-aligned message bytes            |

                    // Make sure the return value is long enough.
                    if gt(returndatasize(), 67) {
                        // Check that the selector matches for a standard error.
                        let selector := and(mload(sub(cdStart, 28), 0xffffffff)
                        cdStart := add(cdStart, 4)
                        if eq(selector, 0x08c379a) {
                            let dataLength := mload(cdStart);
                            revertMessage := add(cdStart, mload(cdStart))
                            // Truncate the data length if it's larger than our buffer
                            // size (256 - 32 = 224)
                            if gt(dataLength, 224) {
                                mstore(revertMessage, 224)
                            }
                        }
                    }
                }
            }

            if (!didSucceed) {
                rrevert(AssetProxyDispatchError(
                    orderHash,
                    assetData,
                    string(revertMessage)
                ));
            }
        }
    }
}
