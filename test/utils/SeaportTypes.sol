// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// the smallest slice of the Seaport 1.6 abi the tests need, declared locally so there is no seaport dependency.
/// field order and names follow the deployed contract, which fixes every selector and every eip 712 type hash.

enum ItemType {
    NATIVE,
    ERC20,
    ERC721,
    ERC1155,
    ERC721_WITH_CRITERIA,
    ERC1155_WITH_CRITERIA
}

enum OrderType {
    FULL_OPEN,
    PARTIAL_OPEN,
    FULL_RESTRICTED,
    PARTIAL_RESTRICTED,
    CONTRACT
}

/// basic order routes. only the native to erc721 route is used.
enum BasicOrderType {
    ETH_TO_ERC721_FULL_OPEN,
    ETH_TO_ERC721_PARTIAL_OPEN,
    ETH_TO_ERC721_FULL_RESTRICTED,
    ETH_TO_ERC721_PARTIAL_RESTRICTED
}

struct OfferItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
}

struct ConsiderationItem {
    ItemType itemType;
    address token;
    uint256 identifierOrCriteria;
    uint256 startAmount;
    uint256 endAmount;
    address payable recipient;
}

struct OrderParameters {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 totalOriginalConsiderationItems;
}

/// what the offerer signs. the same as the parameters with the counter in place of the item count.
struct OrderComponents {
    address offerer;
    address zone;
    OfferItem[] offer;
    ConsiderationItem[] consideration;
    OrderType orderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 conduitKey;
    uint256 counter;
}

struct Order {
    OrderParameters parameters;
    bytes signature;
}

struct AdvancedOrder {
    OrderParameters parameters;
    uint120 numerator;
    uint120 denominator;
    bytes signature;
    bytes extraData;
}

struct CriteriaResolver {
    uint256 orderIndex;
    uint8 side;
    uint256 index;
    uint256 identifier;
    bytes32[] criteriaProof;
}

struct AdditionalRecipient {
    uint256 amount;
    address payable recipient;
}

struct BasicOrderParameters {
    address considerationToken;
    uint256 considerationIdentifier;
    uint256 considerationAmount;
    address payable offerer;
    address zone;
    address offerToken;
    uint256 offerIdentifier;
    uint256 offerAmount;
    BasicOrderType basicOrderType;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
    uint256 salt;
    bytes32 offererConduitKey;
    bytes32 fulfillerConduitKey;
    uint256 totalOriginalAdditionalRecipients;
    AdditionalRecipient[] additionalRecipients;
    bytes signature;
}

interface ISeaport {
    function fulfillBasicOrder_efficient_6GL6yc(BasicOrderParameters calldata parameters)
        external
        payable
        returns (bool fulfilled);

    function fulfillOrder(Order calldata order, bytes32 fulfillerConduitKey) external payable returns (bool fulfilled);

    function fulfillAdvancedOrder(
        AdvancedOrder calldata advancedOrder,
        CriteriaResolver[] calldata criteriaResolvers,
        bytes32 fulfillerConduitKey,
        address recipient
    ) external payable returns (bool fulfilled);

    function cancel(OrderComponents[] calldata orders) external returns (bool cancelled);

    function getOrderHash(OrderComponents calldata order) external view returns (bytes32 orderHash);

    function getCounter(address offerer) external view returns (uint256 counter);

    function information()
        external
        view
        returns (string memory version, bytes32 domainSeparator, address conduitController);
}

/// zone callback types, used only by the local zone double in the restricted order tests.
struct SpentItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
}

struct ReceivedItem {
    ItemType itemType;
    address token;
    uint256 identifier;
    uint256 amount;
    address payable recipient;
}

struct ZoneParameters {
    bytes32 orderHash;
    address fulfiller;
    address offerer;
    SpentItem[] offer;
    ReceivedItem[] consideration;
    bytes extraData;
    bytes32[] orderHashes;
    uint256 startTime;
    uint256 endTime;
    bytes32 zoneHash;
}
