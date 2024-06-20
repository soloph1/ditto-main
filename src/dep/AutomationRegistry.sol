// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAutomationRegistry} from "./IAutomationRegistry.sol";

contract AutomationRegistry is Ownable, IAutomationRegistry {
    constructor() Ownable() {}

    function addAutomation() external onlyOwner {}
}
