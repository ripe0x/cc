// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {SovereignAuctionHouseV2} from "./SovereignAuctionHouseV2.sol";

/// @notice Immutable factory for V2 ERC721 auction-house clones.
contract SovereignAuctionHouseV2Factory {
    address public immutable implementation;
    uint16 public immutable defaultProtocolFeeBps;
    address payable public immutable defaultFeeRecipient;
    mapping(address => address) public houseOf;
    address[] public allHouses;
    mapping(address => bool) public isHouse;

    event AuctionHouseCreated(address indexed owner, address indexed house, address feeRecipient, uint16 protocolFeeBps);

    constructor(address implementation_, address payable defaultFeeRecipient_, uint16 defaultProtocolFeeBps_) {
        require(implementation_ != address(0) && implementation_.code.length != 0, "implementation required");
        require(defaultProtocolFeeBps_ <= 500, "fee above cap");
        require(defaultProtocolFeeBps_ == 0 || defaultFeeRecipient_ != address(0), "fee recipient required when fee > 0");
        implementation = implementation_;
        defaultFeeRecipient = defaultFeeRecipient_;
        defaultProtocolFeeBps = defaultProtocolFeeBps_;
    }

    function createAuctionHouse() external returns (address house) {
        require(houseOf[msg.sender] == address(0), "House already exists");
        house = Clones.cloneDeterministic(implementation, bytes32(uint256(uint160(msg.sender))));
        SovereignAuctionHouseV2(payable(house)).initialize(msg.sender, defaultFeeRecipient, defaultProtocolFeeBps);
        houseOf[msg.sender] = house;
        allHouses.push(house);
        isHouse[house] = true;
        emit AuctionHouseCreated(msg.sender, house, defaultFeeRecipient, defaultProtocolFeeBps);
    }

    function predictHouseAddress(address owner) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, bytes32(uint256(uint160(owner))));
    }

    function totalHouses() external view returns (uint256) {
        return allHouses.length;
    }
}
