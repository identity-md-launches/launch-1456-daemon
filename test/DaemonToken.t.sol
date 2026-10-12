// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DaemonToken} from "../src/DaemonToken.sol";

contract DaemonTokenTest is Test {
    DaemonToken token;
    address deployer = makeAddr("factory");

    function setUp() public {
        vm.prank(deployer);
        token = new DaemonToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "DAEMON");
        assertEq(token.symbol(), "DAEMON");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(deployer), 1_000_000_000e18, "whole supply minted to the deployer");
    }

    function test_productionAllocationSumsToSupply() public view {
        uint256 s = token.totalSupply();
        uint256 liquidity = s * 83 / 100;
        uint256 swarm = s * 10 / 100;
        uint256 game = s * 4 / 100;
        uint256 dev = s * 1 / 100;
        uint256 founder = s * 2 / 100;
        assertEq(liquidity + swarm + game + dev + founder, s);
        assertEq(game + dev + founder, s * 7 / 100, "the 7% remainder goes to the distribution receiver");
    }

    function test_noMintOrBurnPath() public {
        address attacker = makeAddr("attacker");
        string[8] memory sigs = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "transferOwnership(address)",
            "setMinter(address)",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < sigs.length; i++) {
            vm.prank(attacker);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], attacker, uint256(1)));
            assertFalse(ok, sigs[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(abi.encodeWithSignature(sigs[i], deployer, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_transferMovesExactAmount() public {
        address to = makeAddr("to");
        vm.prank(deployer);
        assertTrue(token.transfer(to, 5e18));
        assertEq(token.balanceOf(to), 5e18);
        assertEq(token.balanceOf(deployer), 1_000_000_000e18 - 5e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
        }
    }
}
