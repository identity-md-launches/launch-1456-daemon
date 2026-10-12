// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "solmate/src/tokens/ERC721.sol";

/// @notice Minimal ERC-721 for tests; anyone can mint any id.
contract MockERC721 is ERC721 {
    constructor() ERC721("Mock NFT", "MNFT") {}

    function mint(address to, uint256 id) external {
        _mint(to, id);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
