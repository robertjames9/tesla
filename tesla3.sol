// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

    contract Tesla is Ownable {
    using SafeERC20 for IERC20;
    using Counters for Counters.Counter;

    IERC20 public token;
    uint public price;
    uint public dailyLimit = 1000;
    uint public totalDeposit;
    uint public totalBonus;
    uint public totalAllocated;
    uint public totalWithdrawn;
    uint public totalCommission;
    uint public nextPayIndex;
    uint public payMultiplier = 2;
    uint public totalUsers;

    Counters.Counter private _dailyLimit;

    uint[] private groupRate = [3, 3, 3, 3, 3]; //group commission rate
    uint private directCommRate = 10; //direct sponsor commission
    uint private groupFeeRate = 15; //total group commission should be payout
    uint private companyFee = 22; //company earning
    uint private poolRate = 3; //for sharing prize pool
    uint private levelStep = 10; //total max number to achieve next rank
    uint private available;

    address private companyWallet = 0x7132aDC062d1a02bB13Aa650a5475252955fe373;
    address private poolWallet = 0x7132aDC062d1a02bB13Aa650a5475252955fe373;

    bool private started = false;

    struct Deposit {
        address account;
        uint amount;
        uint payout;
        uint allocated;
        uint bonus;
        bool paid;
        uint checkpoint;
    }

    struct User {
        address referer;
        address account;
        uint[] deposits;
        uint[] partners;
        uint totalDeposit;
        uint totalAllocated;
        uint totalWithdrawn;
        uint level;
        bool disableDeposit;
        bool activate;
        bool autoReinvest;
        uint totalBonus;
        uint directBonus;
    }

    struct Level {
        uint level;
        uint lvl0;
        uint lvl1;
        uint lvl2;
        uint lvl3;
        uint lvl4;
        uint lvl5;
    }

    Deposit[] private deposits;
    mapping(address => uint) private userids;
    mapping(uint => User) private users;
    mapping(uint => Level) private levels;
    mapping(uint => uint) private checkpoints;

    event Commission(uint value);
    event UserMsg(uint userid, string msg, uint value);

    constructor(IERC20 _token, uint _price) {
        token = _token;
        price = _price;
    }

    receive() external payable {}

    function withdraw() external onlyOwner {
        if (address(this).balance > 0) {
            payable(companyWallet).transfer(address(this).balance);
        }
        if (token.balanceOf(address(this)) > 0) {
            token.safeTransfer(companyWallet, token.balanceOf(address(this)));
        }
    }

    function invest(address referer) external {
        require(started, "Investment program haven't start!");
        require(_dailyLimit.current() <= dailyLimit, "Over Daily Limit");
        
        _dailyLimit.increment();
        processDeposit(referer);
        payDirect(referer);
        payGroup(referer);
        payQueue();
    }

    function processDeposit(address referer) private {
        uint userid = userids[msg.sender];
        if (userid == 0) {
            totalUsers += 1;
            userid = totalUsers;
            userids[msg.sender] = userid;
            checkpoints[userid] = block.timestamp;
            emit UserMsg(userid, "Joined", 0);
        }
        User storage user = users[userid];
        if (user.account == address(0)) {
            user.account = msg.sender;
        }
        require(user.disableDeposit != true, "Pending Withdraws");
        user.disableDeposit = true;
        user.activate = true;
        user.autoReinvest = true;

        if (user.referer == address(0)) {
            if (users[userids[referer]].deposits.length > 0 && referer != msg.sender) {
                user.referer = referer;
                users[userids[referer]].partners.push(userid);
                processLevelUpdate(referer, msg.sender);
            }
        }

        token.safeTransferFrom(msg.sender, address(this), price);
        totalDeposit += price;

        Deposit memory deposit;
        deposit.amount = price;
        deposit.account = msg.sender;
        deposit.checkpoint = block.timestamp;

        emit UserMsg(userids[msg.sender], "Deposit", price);

        user.deposits.push(deposits.length);
        deposits.push(deposit);
        user.totalDeposit += price;
        available += price;
    }

    function payDirect(address referer) private {
        uint directCommission = price * directCommRate / 100;
        uint uplineId = userids[referer];
        performTransfer(referer, uplineId, directCommission);
        users[uplineId].directBonus += directCommission;
        available -= directCommission;
    }

    function payGroup(address referer) private {
        uint groupCommission = price * groupFeeRate / 100;
        uint totalRefOut;
        uint numSameRank = 0;
        uint prevUplineLevel = 0;
        bool sameRank = false;
        address upline = referer;

        for(uint i = 0; i < 10000; i++) {
            User storage user = users[userids[referer]];   
            uint uplineId = userids[upline];
            uint currUplineLevel = levels[uplineId].level;
            User storage currUplineUser = users[uplineId];
            
            if (uplineId == 0 || upline == address(0) || currUplineLevel < prevUplineLevel) break;

            if (currUplineLevel >= 1 && user.activate == true) {
                uint commission = 0;
                numSameRank = getNumSameRankUsers(currUplineLevel, referer);
                uint accruedRate = getAccruedReferralRate(prevUplineLevel, currUplineLevel);

            if (currUplineLevel == prevUplineLevel && !sameRank && currUplineLevel > 0) {
                if (accruedRate > 0) {
                    commission = price * accruedRate / 100;
                    if (numSameRank > 1){
                        commission /= numSameRank;
                    }
                    performTransfer(upline, uplineId, commission);
                    totalRefOut += commission;
                    groupCommission -= commission;
                    continue;
                } 
                sameRank = true; 
                break;

            } else if (currUplineLevel > prevUplineLevel) {
                    if (accruedRate > 0) {
                    commission = price * accruedRate / 100;
                    performTransfer(upline, uplineId, commission);
                    totalRefOut += commission;
                    groupCommission -= commission;
                } 
                sameRank = false;
        }   
            prevUplineLevel = currUplineLevel;
            upline = currUplineUser.referer;
        }

        if (groupCommission > 0) {
            token.safeTransfer(companyWallet, groupCommission);
            totalCommission += groupCommission;
            available -= groupCommission;
        }
    }

        totalBonus += totalRefOut;
        uint companyOut = price * companyFee / 100;
        token.safeTransfer(companyWallet, companyOut);
        uint poolOut = price * poolRate / 100;
        token.safeTransfer(poolWallet, poolOut);
        uint cost = companyOut + poolOut;
        emit Commission(cost);
        available -= cost;
    }

    function getNumSameRankUsers(uint rank, address upline) private view returns (uint) {
        uint numSameRank = 0;
        address currUpline = upline;
        while (currUpline != address(0)) {
            uint currUplineId = userids[currUpline];
            uint currUplineLevel = levels[currUplineId].level;
            if (currUplineLevel != rank || currUplineLevel < levels[currUplineId].level) {
                break;
            }
            numSameRank++;
            currUpline = users[currUplineId].referer;
        }
        return numSameRank;
    }

    function performTransfer(address referer, uint uplineId, uint amount) private {
        token.safeTransfer(referer, amount);
        emit UserMsg(uplineId, "RefBonus", amount);
    }

    function getAccruedReferralRate(uint prevLevel, uint currLevel) private view returns (uint) {
        uint rateSum = 0; 
        if(prevLevel > currLevel)
            return 0;
        for(uint i = prevLevel; i < currLevel; i++) {
            rateSum += groupRate[i];
        }
        return rateSum;
    }

    function processLevelUpdate(address referer, address from) private {
        uint refererid = userids[referer];
        uint fromid = userids[from];
        if (referer == address(0) && refererid == 0) return;
        User storage user = users[refererid];
        Level storage level = levels[refererid];

        if (levels[fromid].level == 0) {
            level.lvl0++;
            if (level.lvl0 >= levelStep - 5 && level.level < 1) {
                level.level = 1;
                emit UserMsg(refererid, "LevelUp", 1);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 1) {
            level.lvl1++;
            if (level.lvl1 >= levelStep - 5 && level.level < 2) {
                level.level = 2;
                emit UserMsg(userids[referer], "LevelUp", 2);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 2) {
            level.lvl2++;
            if (level.lvl2 >= levelStep - 5 && level.level < 3) {
                level.level = 3;
                emit UserMsg(userids[referer], "LevelUp", 3);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 3) {
            level.lvl3++;
            if (level.lvl3 >= levelStep && level.level < 4) {
                level.level = 4;
                emit UserMsg(userids[referer], "LevelUp", 4);
                processLevelUpdate(user.referer, referer);
            }
        } else if (levels[fromid].level == 4) {
            level.lvl4++;
            if (level.lvl4 >= levelStep && level.level < 5) {
                level.level = 5;
                emit UserMsg(userids[referer], "LevelUp", 5);
                processLevelUpdate(user.referer, referer);
            }
        } 
    }

    function payQueue() private {
        for (uint index = nextPayIndex; index < deposits.length - 1; index++) {
            Deposit storage deposit = deposits[index];
            uint balance = token.balanceOf(address(this));
            User storage user = users[userids[deposit.account]];
            uint half = available * 8 / 10;
            uint needPay = deposit.amount * payMultiplier - deposit.allocated;
            if (needPay == 0) continue;
            if (half >= needPay) {
                if (balance < needPay) return;
                available -= needPay;
                deposit.allocated += needPay;
                deposit.paid = true;
                user.totalAllocated += needPay;
                totalAllocated += needPay;
                emit UserMsg(userids[deposit.account], "Dividend", needPay);
                nextPayIndex = index + 1;
            } else {
                if (balance < half) return;
                available -= half;
                deposit.allocated = deposit.allocated + half;
                user.totalAllocated += half;
                totalAllocated += half;
                emit UserMsg(userids[deposit.account], "Dividend", half);
            }
            break;
        }
        uint shareUsers = totalUsers - 1;
        uint share = available;
        if (share == 0) return;
        for (uint index = nextPayIndex; index < deposits.length - 1; index++) {
            Deposit storage deposit = deposits[index];
            uint needPay = deposit.amount * payMultiplier - deposit.allocated;
            uint balance = token.balanceOf(address(this));
            if (needPay == 0) continue;
            User storage user = users[userids[deposit.account]];
            uint topay = share / shareUsers;
            if (topay >= needPay) {
                if (balance < needPay) return;
                if (available < needPay) return;
                token.safeTransfer(deposit.account, needPay);
                available -= needPay;
                deposit.allocated = deposit.allocated + needPay;
                deposit.paid = true;
                user.totalAllocated += needPay;
                totalAllocated += needPay;
                emit UserMsg(userids[deposit.account], "Dividend", needPay);
                nextPayIndex = index + 1;
            } else {
                if (balance < topay) return;
                if (available < topay) return;
                deposit.allocated = deposit.allocated + topay;
                available -= topay;
                user.totalAllocated += topay;
                totalAllocated += topay;
                emit UserMsg(userids[deposit.account], "Dividend", topay);
            }
        }
    }

    function reInvest() private {
        User storage user = users[userids[msg.sender]];
        require(user.deposits.length > 0, "User has no deposits");
        require(user.autoReinvest == true, "Auto invest is not available!");
        address referer = user.referer;

        for (uint i = 0; i < user.deposits.length; i++) {
            Deposit storage deposit = deposits[user.deposits[i]];
            if (deposit.allocated == deposit.amount * 2) {
                user.disableDeposit = false;
                _dailyLimit.increment();
                processDeposit(referer);
                payDirect(referer);
                payGroup(referer);
                payQueue();
                emit UserMsg(userids[msg.sender], "Deposit", price);
            }
        }
    }

    function claim() external {
        User storage user = users[userids[msg.sender]];
        require(user.deposits.length > 0, "User has no deposits");

        uint totalPayout;
        for (uint i = 0; i < user.deposits.length; i++) {
            Deposit storage deposit = deposits[user.deposits[i]];
            if (deposit.allocated > deposit.payout) {
                uint payoutAmount = deposit.allocated - deposit.payout;
                deposit.payout += payoutAmount;
                user.totalWithdrawn += payoutAmount;
                totalWithdrawn += payoutAmount;
                totalPayout += payoutAmount;
            }

            if (deposit.allocated == deposit.payout) {
                user.activate = false;
                user.disableDeposit = false;
            }
        }

        require(totalPayout > 0, "No payout available");
        token.safeTransfer(msg.sender, totalPayout);
        emit UserMsg(userids[msg.sender], "Claim", totalPayout);
        user.autoReinvest = false;
    }

    function resetCount() external onlyOwner {
        _dailyLimit.reset();
    }

    function setDailyLimit(uint _dayLimit) external onlyOwner {
        dailyLimit = _dayLimit;
    }

    function setLevel(uint userid, uint level) external onlyOwner {   
        levels[userid].level = level;
    }

    function setStarted() external onlyOwner {
        started = true;
    }

    function setPause() external onlyOwner {
        started = false;
    }

    function setPrice(uint _price) external onlyOwner {
        price = _price;
    }

    function setToken(IERC20 _token) external onlyOwner {
        token = _token;
    }

    function setCompanyWallet(address wallet) external onlyOwner {
        companyWallet = wallet;
    }

    function setGroupRate(uint256[] memory rates) external onlyOwner {
        groupRate = rates;
    }

    function setPayMultiplier(uint multiplier) external onlyOwner {
        payMultiplier = multiplier;
    }

    function getDeposits(uint[] calldata indexs) external view returns (Deposit[] memory) {
        Deposit[] memory deps = new Deposit[](indexs.length);
        for (uint i = 0; i < indexs.length; i++) {
            deps[i] = deposits[indexs[i]];
        }
        return deps;
    }

    function userDeposits(address account) public view returns (Deposit[] memory) {
        uint[] memory depositIndexs = users[userids[account]].deposits;
        Deposit[] memory deps = new Deposit[](depositIndexs.length);
        for (uint i = 0; i < depositIndexs.length; i++) {
            deps[i] = deposits[depositIndexs[i]];
        }
        return deps;
    }

    function userInfoById(uint id) public view returns(uint, uint, User memory, Level memory) {
        User storage user = users[id];
        Level storage level = levels[id];
        return (
            id, 
            userids[user.referer], 
            user, 
            level
        );
    }

    function userInfoByAddress(address account) public view returns(uint, uint, User memory, Level memory) {
        uint userid = userids[account];
        return userInfoById(userid);
    }

    function partnerIdsById(uint id) public view returns (uint[] memory){
        User storage user = users[id];
        return user.partners;
    }

    function contractInfo() public view returns (uint, uint, uint, uint, uint, uint, uint) {
        return (
            totalDeposit, 
            totalBonus,
            totalWithdrawn, 
            deposits.length, 
            totalUsers, 
            price, 
            nextPayIndex
        );
    }

    function userInfo(uint userId) public view returns (address, uint, address, Level memory, uint, uint, uint, uint, uint, uint, bool) {
        require(userId > 0 && userId <= totalUsers, "Invalid user ID");
        User storage user = users[userId];
        Level storage level = levels[userId];

        return (
            user.referer,
            userids[user.referer],
            user.account,
            level,
            user.partners.length,
            user.totalDeposit,
            user.totalAllocated,
            user.totalWithdrawn,
            user.totalBonus,
            user.directBonus,
            user.activate
        );
    }
}
