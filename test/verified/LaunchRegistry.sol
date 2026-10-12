// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The public record of everything this network has launched
/// @notice One entry per launch: what was deployed, from which tree, attested by whom, and by which
/// agents. The off-chain `launches` table stays the operational source of truth; this is the
/// tamper-evident public one, and it is what makes the provenance story legible to someone who does
/// not trust our API.
///
/// @dev Deliberately generic. Nothing in it says "hook": artifacts carry a role rather than a
/// column, so a launch kind that deploys something else entirely is a new recipe rather than a new
/// registry. `writer` is the only address that may record, and it is set once at construction to the
/// factory — a registry anyone could write to is a registry that records nothing.
contract LaunchRegistry {
    struct Artifact {
        /// @dev `token`, `hook`, `distributor`, `other` — matched to `launch_artifacts.role`.
        bytes32 role;
        bytes32 name;
        address addr;
    }

    struct Launch {
        bytes32 kind;
        /// @dev Position in the network's launch history, carried over from the job that produced it.
        uint64 launchNumber;
        uint64 recordedAt;
        /// @dev Git commit of the delivered tree, and the hash of the document that attested it.
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        /// @dev Ed25519 public key of the verifier that signed the attestation.
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    error NotWriter();
    error AlreadyRecorded(uint64 launchNumber);
    error NoArtifacts();

    event LaunchRecorded(
        uint64 indexed launchNumber,
        bytes32 indexed kind,
        bytes32 sourceCommit,
        bytes32 attestationHash,
        address[] artifacts,
        uint256[] agentIds
    );

    /// @notice The only address that may record a launch. Immutable, and it is the factory.
    address public immutable writer;

    mapping(uint64 launchNumber => Launch) private _launches;
    mapping(uint64 launchNumber => Artifact[]) private _artifacts;
    mapping(uint64 launchNumber => uint256[]) private _agentIds;

    uint64 public count;

    constructor(address writer_) {
        writer = writer_;
    }

    /// @notice Records one launch, once.
    /// @dev Re-recording is refused rather than overwritten. This is the public record; a version of
    /// it that the writer could quietly revise would be worth exactly as much as our word alone,
    /// which is the thing it exists to not require.
    function record(Launch calldata launch, Artifact[] calldata artifacts, uint256[] calldata agentIds) external {
        if (msg.sender != writer) revert NotWriter();
        if (_launches[launch.launchNumber].recordedAt != 0) revert AlreadyRecorded(launch.launchNumber);
        if (artifacts.length == 0) revert NoArtifacts();

        _launches[launch.launchNumber] = launch;
        _launches[launch.launchNumber].recordedAt = uint64(block.timestamp);

        address[] memory addresses = new address[](artifacts.length);
        for (uint256 i = 0; i < artifacts.length; i++) {
            _artifacts[launch.launchNumber].push(artifacts[i]);
            addresses[i] = artifacts[i].addr;
        }

        for (uint256 i = 0; i < agentIds.length; i++) {
            _agentIds[launch.launchNumber].push(agentIds[i]);
        }

        count++;

        emit LaunchRecorded(
            launch.launchNumber, launch.kind, launch.sourceCommit, launch.attestationHash, addresses, agentIds
        );
    }

    function launchOf(uint64 launchNumber) external view returns (Launch memory) {
        return _launches[launchNumber];
    }

    function artifactsOf(uint64 launchNumber) external view returns (Artifact[] memory) {
        return _artifacts[launchNumber];
    }

    function agentsOf(uint64 launchNumber) external view returns (uint256[] memory) {
        return _agentIds[launchNumber];
    }

    /// @notice Whether a launch number has been recorded. Cheaper than reading the whole struct.
    function isRecorded(uint64 launchNumber) external view returns (bool) {
        return _launches[launchNumber].recordedAt != 0;
    }
}
