// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @dev Interfaces.
import {IERC1271} from "./interfaces/IERC1271.sol";

/// @dev Contracts.
import {ERC721TokenReceiver} from "./utils/ERC721TokenReceiver.sol";
import {ERC1155TokenReceiver, ERC1155V} from "./ERC1155V.sol";
import {Multicallable} from "@solbase/utils/Multicallable.sol";

/// @title Keep
/// @notice EIP-712 multi-sig with ERC-1155 interface.
/// @author Modified from LilGnosis (https://github.com/m1guelpf/lil-web3/blob/main/src/LilGnosis.sol)

enum Operation {
    call,
    delegatecall,
    create,
    create2
}

struct Call {
    Operation op;
    address to;
    uint256 value;
    bytes data;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

contract Keep is
    ERC721TokenReceiver,
    ERC1155TokenReceiver,
    ERC1155V,
    Multicallable
{
    /// -----------------------------------------------------------------------
    /// EVENTS
    /// -----------------------------------------------------------------------

    /// @notice Emitted when Keep executes call.
    event Executed(Operation op, address indexed to, uint256 value, bytes data);

    /// @notice Emitted when Keep creates contract.
    event ContractCreated(
        Operation op,
        address indexed creation,
        uint256 value
    );

    /// @notice Emitted when quorum threshold is updated.
    event QuorumSet(address indexed caller, uint256 threshold);

    /// -----------------------------------------------------------------------
    /// ERRORS
    /// -----------------------------------------------------------------------

    /// @notice Throws if init() is called more than once.
    error AlreadyInit();

    /// @notice Throws if quorum exceeds totalSupply(EXECUTE_ID).
    error QuorumOverSupply();

    /// @notice Throws if signature doesn't verify execute().
    error InvalidSig();

    /// @notice Throws if execute() doesn't complete operation.
    error ExecuteFailed();

    /// -----------------------------------------------------------------------
    /// KEEP STORAGE/LOGIC
    /// -----------------------------------------------------------------------
    
    /// @notice Default metadata reference for `uri()`.
    Keep internal uriFetcher;

    /// @notice Record of states for verifying `execute()`.
    uint64 public nonce;

    /// @notice EXECUTE_ID threshold to `execute()`.
    uint64 public quorum;

    /// @notice `initialize()` Keep domain value.
    bytes32 internal _INITIAL_DOMAIN_SEPARATOR;

    /// @notice `execute()` ID permission.
    uint256 internal constant EXECUTE_ID =
        uint256(bytes32(this.execute.selector));

    /// @notice ID metadata tracking.
    mapping(uint256 => string) internal _uris;

    /// @notice ID metadata fetcher.
    /// @param id ID to fetch from.
    /// @return tokenURI ID metadata reference.
    function uri(uint256 id)
        public
        view
        virtual
        override
        returns (string memory tokenURI)
    {
        tokenURI = _uris[id];
        
        if (bytes(tokenURI).length == 0) return uriFetcher.uri(id); 
        else return tokenURI;
    }

    /// @notice The name of this Keep.
    /// @return Name string.
    function name() public pure virtual returns (string memory) {
        return string(abi.encodePacked(_getArgUint256(2)));
    }

    /// @notice Access control for ID balance owners.
    function _authorized() internal view virtual returns (bool) {
        if (
            msg.sender == address(this) ||
            balanceOf[msg.sender][uint256(bytes32(msg.sig))] != 0
        ) return true;
        else revert NotAuthorized();
    }

    /// @notice Fetch immutable uint storage.
    function _getArgUint256(uint256 argOffset)
        private
        pure
        returns (uint256 arg)
    {
        uint256 offset;

        assembly {
            offset := sub(
                calldatasize(),
                add(shr(240, calldataload(sub(calldatasize(), 2))), 2)
            )
        }

        assembly {
            arg := calldataload(add(offset, argOffset))
        }
    }

    /// -----------------------------------------------------------------------
    /// ERC-165 LOGIC
    /// -----------------------------------------------------------------------

    /// @notice ERC-165 interface detection.
    /// @param interfaceId ID to check.
    /// @return Fetch detection success.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == this.onERC721Received.selector || // ERC165 Interface ID for ERC721TokenReceiver.
            interfaceId == 0x4e2312e0 || // ERC165 Interface ID for ERC1155TokenReceiver.
            super.supportsInterface(interfaceId); // ERC165 Interface IDs for ERC1155.
    }

    /// -----------------------------------------------------------------------
    /// EIP-712 LOGIC
    /// -----------------------------------------------------------------------

    /// @notice Fetches domain for EXECUTE_ID signatures.
    /// @return Domain hash.
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return
            block.chainid == _INITIAL_CHAIN_ID()
                ? _INITIAL_DOMAIN_SEPARATOR
                : _computeDomainSeparator();
    }

    function _INITIAL_CHAIN_ID() internal pure virtual returns (uint256) {
        return _getArgUint256(7);
    }

    function _computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                    ),
                    keccak256(bytes("Keep")),
                    keccak256("1"),
                    block.chainid,
                    address(this)
                )
            );
    }

    /// -----------------------------------------------------------------------
    /// INITIALIZATION LOGIC
    /// -----------------------------------------------------------------------
    
    /// @notice Create Keep template.
    /// @param _uriFetcher Metadata default.
    constructor(Keep _uriFetcher) payable {
        uriFetcher = _uriFetcher;
    }
        
    /// @notice Initialize Keep configuration.
    /// @param calls Initial Keep operations.
    /// @param signers Initial signer set.
    /// @param threshold Initial quorum.
    function initialize(
        Call[] calldata calls,
        address[] calldata signers,
        uint256 threshold
    ) public payable virtual {
        if (quorum != 0) revert AlreadyInit();

        assembly {
            if iszero(threshold) {
                revert(0, 0)
            }
        }

        if (threshold > signers.length) revert QuorumOverSupply();

        if (calls.length != 0) {
            for (uint256 i; i < calls.length; ) {
                _execute(
                    calls[i].op,
                    calls[i].to,
                    calls[i].value,
                    calls[i].data
                );

                // An array can't have a total length
                // larger than the max uint256 value.
                unchecked {
                    ++i;
                }
            }
        }

        address signer;

        address previous;

        uint256 supply;

        for (uint256 i; i < signers.length; ) {
            signer = signers[i];

            // Prevent zero and duplicate signers.
            if (previous >= signer) revert InvalidSig();

            previous = signer;

            // Won't realistically overflow.
            unchecked {
                ++balanceOf[signer][EXECUTE_ID];

                ++supply;

                ++i;
            }

            // We don't call `_moveDelegates()` to save deployment gas.
            emit TransferSingle(msg.sender, address(0), signer, EXECUTE_ID, 1);
        }

        quorum = uint64(threshold);

        totalSupply[EXECUTE_ID] = supply;

        _INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /// -----------------------------------------------------------------------
    /// EXECUTION LOGIC
    /// -----------------------------------------------------------------------

    /// @notice Execute operation from Keep with signatures.
    /// @param op Enum operation to execute.
    /// @param to Address to send operation to.
    /// @param value Amount of ETH to send in operation.
    /// @param data Payload to send in operation.
    /// @param sigs Array of signatures from NFT sorted in ascending order by addresses.
    /// @dev Make sure signatures are sorted in ascending order - otherwise verification will fail.
    /// @return success Fetch whether operation succeeded.
    function execute(
        Operation op,
        address to,
        uint256 value,
        bytes calldata data,
        Signature[] calldata sigs
    ) public payable virtual returns (bool success) {
        // Begin signature validation with call data.
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "Execute(Operation op,address to,uint256 value,bytes data,uint256 nonce)"
                        ),
                        op,
                        to,
                        value,
                        data,
                        nonce
                    )
                )
            )
        );

        // Start from zero in loop to ensure ascending addresses.
        address previous;

        // Validation is length of quorum threshold.
        uint256 threshold = quorum;

        for (uint256 i; i < threshold; ) {
            address signer = ecrecover(digest, sigs[i].v, sigs[i].r, sigs[i].s);

            // Check contract signature with EIP-1271.
            if (signer.code.length != 0) {
                if (
                    IERC1271(signer).isValidSignature(
                        digest,
                        abi.encodePacked(sigs[i].r, sigs[i].s, sigs[i].v)
                    ) != IERC1271.isValidSignature.selector
                ) revert InvalidSig();
            }

            // Check EXECUTE_ID balance.
            if (balanceOf[signer][EXECUTE_ID] == 0) revert InvalidSig();

            // Check duplicates.
            if (previous >= signer) revert InvalidSig();

            // Memo signer for next iteration until quorum.
            previous = signer;

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }

        success = _execute(op, to, value, data);
    }

    /// @notice Execute operations from Keep with signed execute() or as Keep key holder.
    /// @param calls Keep operations as arrays of `op, to, value, data`.
    /// @return successes Fetches whether operations succeeded.
    function multiExecute(Call[] calldata calls)
        public
        payable
        virtual
        returns (bool[] memory successes)
    {
        _authorized();

        successes = new bool[](calls.length);

        for (uint256 i; i < calls.length; ) {
            successes[i] = _execute(
                calls[i].op,
                calls[i].to,
                calls[i].value,
                calls[i].data
            );

            // An array can't have a total length
            // larger than the max uint256 value.
            unchecked {
                ++i;
            }
        }
    }

    function _execute(
        Operation op,
        address to,
        uint256 value,
        bytes memory data
    ) internal virtual returns (bool success) {
        // Won't realistically overflow.
        unchecked {
            ++nonce;
        }

        if (op == Operation.call) {
            assembly {
                success := call(
                    gas(),
                    to,
                    value,
                    add(data, 0x20),
                    mload(data),
                    0,
                    0
                )
            }

            if (!success) revert ExecuteFailed();

            emit Executed(op, to, value, data);
        } else if (op == Operation.delegatecall) {
            assembly {
                success := delegatecall(
                    gas(),
                    to,
                    add(data, 0x20),
                    mload(data),
                    0,
                    0
                )
            }

            if (!success) revert ExecuteFailed();

            emit Executed(op, to, value, data);
        } else if (op == Operation.create) {
            address creation;

            assembly {
                creation := create(value, add(data, 0x20), mload(data))
            }

            if (creation == address(0)) revert ExecuteFailed();

            emit ContractCreated(op, creation, value);
        } else {
            address creation;

            bytes32 salt = bytes32(data);

            assembly {
                creation := create2(value, add(0x20, data), mload(data), salt)
            }

            if (creation == address(0)) revert ExecuteFailed();

            emit ContractCreated(op, creation, value);
        }
    }

    /// -----------------------------------------------------------------------
    /// MINT/BURN LOGIC
    /// -----------------------------------------------------------------------

    /// @notice ID minter.
    /// @param to Recipient of mint.
    /// @param id ID to mint.
    /// @param amount ID balance to mint.
    /// @param data Optional data payload.
    function mint(
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public payable virtual {
        _authorized();

        _mint(to, id, amount, data);
    }

    /// @notice ID burner.
    /// @param from Account to burn from.
    /// @param id ID to burn.
    /// @param amount Balance to burn.
    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) public payable virtual {
        if (
            msg.sender != from &&
            !isApprovedForAll[from][msg.sender] &&
            !_authorized()
        ) revert NotAuthorized();

        _burn(from, id, amount);

        if (id == EXECUTE_ID)
            if (quorum > totalSupply[EXECUTE_ID]) revert QuorumOverSupply();
    }

    /// -----------------------------------------------------------------------
    /// THRESHOLD SETTING LOGIC
    /// -----------------------------------------------------------------------

    /// @notice Update Keep quorum threshold.
    /// @param threshold Signature threshold for `execute()`.
    function setQuorum(uint32 threshold) public payable virtual {
        _authorized();

        assembly {
            if iszero(threshold) {
                revert(0, 0)
            }
        }

        // note: Also make sure signers don't concentrate tokens,
        // as this could cause issues in reaching quorum.
        if (threshold > totalSupply[EXECUTE_ID]) revert QuorumOverSupply();

        quorum = threshold;

        emit QuorumSet(msg.sender, threshold);
    }

    /// -----------------------------------------------------------------------
    /// ID SETTING LOGIC
    /// -----------------------------------------------------------------------

    /// @notice ID transferability setter.
    /// @param id ID to set transferability for.
    /// @param transferability Transferability setting.
    function setTransferability(uint256 id, bool transferability)
        public
        payable
        virtual
    {
        _authorized();

        _setTransferability(id, transferability);
    }

    /// @notice ID metadata setter.
    /// @param id ID to set metadata for.
    /// @param tokenURI Metadata setting.
    function setURI(uint256 id, string calldata tokenURI)
        public
        payable
        virtual
    {
        _authorized();

        _uris[id] = tokenURI;

        emit URI(tokenURI, id);
    }
}