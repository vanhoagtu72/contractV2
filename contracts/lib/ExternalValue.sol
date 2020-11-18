/*

    Copyright 2020 DODO ZOO.
    SPDX-License-Identifier: Apache-2.0

*/

pragma solidity 0.6.9;
pragma experimental ABIEncoderV2;

import {Ownable} from "./Ownable.sol";

interface IExternalValue {
    function set(uint256) external;

    function get() external view returns (uint256);
}

contract ExternalValue is IExternalValue, Ownable {
    uint256 public _VALUE_;

    function set(uint256 value) external override {
        _VALUE_ = value;
    }

    function get() external override view returns (uint256) {
        return _VALUE_;
    }
}