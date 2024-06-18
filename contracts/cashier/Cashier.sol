// SPDX-License-Identifier: Unlicense
pragma solidity >=0.8.0 <0.9.0;

import "./token/IUploadToken.sol";
import "../dataFlow/Flow.sol";
import "../utils/ZgsSpec.sol";
import "../utils/Exponent.sol";
import "../utils/OnlySender.sol";
import "../utils/TimeInterval.sol";
import "../token/ISafeERC20.sol";
import "../interfaces/IMarket.sol";
import "../interfaces/IReward.sol";
import "../interfaces/AddressBook.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract Cashier is IMarket, OnlySender, TimeInterval {
    int public gauge;
    uint public drippingRate;
    uint public lastUpdate;

    uint public paidUploadAmount;
    uint public paidFee;

    uint private constant BASIC_PRICE = 1000;
    uint private constant UPLOAD_TOKEN_PER_SECTOR = 10 ** 18;

    IReward public immutable reward;
    IUploadToken public immutable uploadToken;
    address public immutable flow;
    address public immutable mine;
    address public immutable stake;

    constructor(address book_, address uploadToken_, address stake_) {
        AddressBook book = AddressBook(book_);
        flow = address(book.flow());
        mine = book.mine();
        reward = book.reward();

        uploadToken = IUploadToken(uploadToken_);
        stake = stake_;

        _tick();
    }

    function refreshGauge() public {
        uint timeElapsedInMilliSeconds = _tick();
        uint gaugeDelta = (timeElapsedInMilliSeconds * drippingRate) / 1000;
        gauge += int(gaugeDelta);
        if (gauge > int(30 * GB)) {
            gauge = int(30 * GB);
        }
    }

    function _updateDrippingRate(uint flowLength) internal {
        refreshGauge();
        drippingRate = Math.min(3 * MB, (flowLength * BYTES_PER_SECTOR) / MB);
    }

    function _topUp(uint sectors, uint fee) internal {
        paidUploadAmount += sectors;
        paidFee += fee;
    }

    function chargeFee(uint beforeLength, uint uploadSectors, uint paddingSectors) public onlySender(flow) {
        require(paidUploadAmount >= uploadSectors, "Data submission is not paid");

        uint totalSectors = uploadSectors + paddingSectors;
        uint afterLength = beforeLength + totalSectors;
        _updateDrippingRate(afterLength);

        uint chargedFee = (uploadSectors * paidFee) / paidUploadAmount;
        paidFee -= chargedFee;
        paidUploadAmount -= uploadSectors;

        reward.fillReward{value: chargedFee}(beforeLength, totalSectors);
    }

    function purchase(uint sectors, uint maxPrice, uint maxTipPrice) external payable {
        refreshGauge();
        uint purchaseBytes = sectors * BYTES_PER_SECTOR;
        uint basicFee = purchaseBytes * BASIC_PRICE;
        uint priorFee = computePriorityFee(purchaseBytes);
        uint maxTipFee = maxTipPrice * purchaseBytes;
        uint maxFee = purchaseBytes * maxPrice;
        require(basicFee + priorFee <= maxFee, "Exceed price limit");

        uint actualFee = Math.min(maxFee, basicFee + priorFee + maxTipFee);

        _receiveFee(actualFee, priorFee);

        gauge -= int(purchaseBytes);

        _topUp(sectors, actualFee - priorFee);
    }

    function _receiveFee(uint actualFee, uint priorFee) internal virtual {
        uint resetBalance = msg.value;

        if (actualFee > priorFee) {
            require(actualFee - priorFee <= resetBalance, "Not enough fee");
            resetBalance -= actualFee - priorFee;
        }

        if (priorFee > 0) {
            require(priorFee <= resetBalance, "Not enough prior fee");
            resetBalance -= priorFee;
            payable(stake).transfer(priorFee);
        }

        if (resetBalance > 0) {
            payable(msg.sender).transfer(resetBalance);
        }
    }

    function consumeUploadToken(uint sectors) external {
        uint consumedTokens = sectors * UPLOAD_TOKEN_PER_SECTOR;

        uploadToken.consume(msg.sender, consumedTokens);

        _topUp(sectors, sectors * BYTES_PER_SECTOR * BASIC_PRICE);
    }

    function computePriorityFee(uint purchaseBytes) public view returns (uint) {
        uint chargeStart;
        uint chargeEnd;
        if (gauge >= 0) {
            uint _gauge = uint(gauge);
            if (_gauge >= purchaseBytes) {
                return 0;
            } else {
                chargeStart = 0;
                chargeEnd = purchaseBytes - _gauge;
            }
        } else {
            uint _gauge = uint(-gauge);
            chargeStart = _gauge;
            chargeEnd = _gauge + purchaseBytes;
        }

        require(chargeEnd <= 100 * GB, "Gauge underflow");

        uint aX64 = (chargeStart << 64) / (900 * MB);
        uint bX64 = (chargeEnd << 64) / (900 * MB);
        uint answerFactor1X96 = Exponential.powTwo64X96(bX64 - aX64) - (1 << 96);
        uint answerFactor2X96 = Exponential.powTwo64X96(aX64);
        uint answerX128;
        if (answerFactor2X96 > 1 << 104) {
            answerX128 = answerFactor1X96 * (answerFactor2X96 >> 64);
        } else if (answerFactor1X96 > 1 << 104) {
            answerX128 = (answerFactor1X96 >> 64) * answerFactor2X96;
        } else {
            answerX128 = (answerFactor1X96 * answerFactor2X96) >> 64;
        }
        uint answerX96 = answerX128 >> 32;
        return ((answerX96 * BASIC_PRICE * (900 * MB)) / 100) >> 96;
    }
}
